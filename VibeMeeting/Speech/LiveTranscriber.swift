import AVFoundation
import Foundation
import Speech
import VibeCore

/// On-device English transcription for one audio stream (Them or You), built on
/// SpeechAnalyzer + SpeechTranscriber (macOS 26). Two instances run at once;
/// same-locale transcribers share the backing engine.
final class LiveTranscriber: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case unsupportedLocale(String)
        case assetsNotReady
        case noAudioFormat
        case endedUnexpectedly

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let id): return "Speech recognition for \(id) isn't available on this Mac."
            case .assetsNotReady: return "The speech model is still downloading. Try again in a minute."
            case .noAudioFormat: return "Speech recognition couldn't pick an audio format."
            case .endedUnexpectedly: return "Speech recognition stopped on its own."
            }
        }
    }

    /// Runs on the main actor; results are delivered one at a time, in order.
    typealias UpdateHandler = @MainActor @Sendable (TranscriptUpdate) -> Void
    typealias ErrorHandler = @MainActor @Sendable (Error) -> Void

    static let preferredLocale = Locale(identifier: "en-US")

    let speaker: Speaker
    let diagnostics: StreamDiagnostics
    private let fold: MonoFold
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var accumulator: ChunkAccumulator?
    private var resultsTask: Task<Void, Never>?
    /// Bumped by every start and stop (under `lock`). A start that finds it changed
    /// after its awaits was stopped meanwhile and must not install its analyzer.
    private var generation = 0
    private let converter = BufferConverter()

    /// RMS of a 100 ms chunk that counts as speech level (about -40 dBFS).
    static let speechLevelRMS: Float = 0.01

    init(speaker: Speaker, diagnostics: StreamDiagnostics) {
        self.speaker = speaker
        self.diagnostics = diagnostics
        // Mic: channel 0 (voice processing exposes discrete channels). System audio: average L/R.
        self.fold = speaker == .you ? .firstChannel : .average
    }

    // MARK: - Setup

    /// The English transcriber and the exact locale the system supports for it.
    static func makeTranscriber() async throws -> (transcriber: SpeechTranscriber, locale: Locale) {
        let requested = preferredLocale
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        else {
            throw Failure.unsupportedLocale(requested.identifier(.bcp47))
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Volatile results drive the live subtitle; finals lock the text in.
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        return (transcriber, locale)
    }

    /// Reserves the locale, downloads the model if needed, and waits until it's usable.
    static func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        try await reserve(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        // downloadAndInstall() can return before the model is usable;
        // bestAvailableAudioFormat stays nil until it is.
        for _ in 0..<40 {
            if await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.assetsNotReady
    }

    /// Reservations are capped (5 measured) and persist across launches.
    private static func reserve(_ locale: Locale) async throws {
        let key = locale.identifier(.bcp47)
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == key }) { return }
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            guard reserved.count >= AssetInventory.maximumReservedLocales,
                  let stale = reserved.first(where: { $0.identifier(.bcp47) != key })
            else { throw error }
            await AssetInventory.release(reservedLocale: stale)
            try await AssetInventory.reserve(locale: locale)
        }
    }

    /// Downloads the model up front (onboarding).
    static func prepareAssets() async throws {
        let (transcriber, locale) = try await makeTranscriber()
        try await ensureAssets(for: transcriber, locale: locale)
    }

    func start(onUpdate: @escaping UpdateHandler, onError: @escaping ErrorHandler) async throws {
        let token: Int? = lock.withLock {
            guard analyzer == nil else { return nil }
            generation += 1
            return generation
        }
        guard let token else { return }
        diagnostics.update { $0.transcriberState = "Checking speech model" }
        do {
            try await startAnalyzer(token: token, onUpdate: onUpdate, onError: onError)
        } catch {
            diagnostics.update {
                $0.transcriberState = "Failed to start"
                $0.lastError = Self.describe(error)
            }
            throw error
        }
    }

    private func startAnalyzer(token: Int, onUpdate: @escaping UpdateHandler, onError: @escaping ErrorHandler) async throws {
        let diagnostics = self.diagnostics
        let (transcriber, locale) = try await Self.makeTranscriber()
        diagnostics.update { $0.transcriberState = "Preparing speech model" }
        try await Self.ensureAssets(for: transcriber, locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAudioFormat
        }
        diagnostics.update {
            $0.transcriberState = "Starting analyzer"
            $0.analyzerFormat = StreamDiagnostics.describe(format)
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        // bufferingNewest drops the oldest chunk on overflow; 600 × 100 ms = 60 s of headroom.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(600))
        let speaker = self.speaker

        // Consume results before starting, as Apple's sample does, so nothing (not even an error) is missed.
        let resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    diagnostics.update {
                        if result.isFinal { $0.finalResults += 1 } else { $0.volatileResults += 1 }
                        $0.lastResultAt = Date()
                    }
                    // Awaiting keeps volatile and final results in order.
                    await onUpdate(TranscriptUpdate(speaker: speaker, kind: result.isFinal ? .final : .volatile, text: String(result.text.characters)))
                }
                // A normal end is expected only after stop(), which bumps the generation.
                let stillRunning = self?.lock.withLock { self?.generation == token } ?? false
                if stillRunning, !Task.isCancelled {
                    self?.closeInput(token: token)
                    Log.speech.error("Transcriber \(speaker.rawValue, privacy: .public) results ended on their own")
                    diagnostics.update {
                        $0.transcriberState = "Ended unexpectedly"
                        $0.lastError = Failure.endedUnexpectedly.errorDescription
                    }
                    await onError(Failure.endedUnexpectedly)
                }
            } catch is CancellationError {
            } catch {
                // Any analyzer or module error ends the session and is thrown here.
                self?.closeInput(token: token)
                Log.speech.error("Transcriber \(speaker.rawValue, privacy: .public) stopped: \(String(describing: error), privacy: .public)")
                diagnostics.update {
                    $0.transcriberState = "Stopped with an error"
                    $0.lastError = Self.describe(error)
                }
                await onError(error)
            }
        }

        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            resultsTask.cancel()
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let installed: Bool = lock.withLock {
            // stop() ran while this start was suspended: don't leak a running analyzer.
            guard generation == token else { return false }
            self.analyzer = analyzer
            self.analyzerFormat = format
            self.accumulator = ChunkAccumulator(format: format)
            self.continuation = continuation
            self.resultsTask = resultsTask
            return true
        }
        guard installed else {
            continuation.finish()
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            diagnostics.update { $0.transcriberState = "Stopped" }
            return
        }
        diagnostics.update { $0.transcriberState = "Running (\(locale.identifier(.bcp47)))" }
        Log.speech.info("Transcriber \(speaker.rawValue, privacy: .public) started, \(StreamDiagnostics.describe(format), privacy: .public)")
    }

    /// The analyzer finished on its own. It stops reading but doesn't end the input
    /// sequence, so close it: append() then stops counting audio nobody hears.
    private func closeInput(token: Int) {
        let input: AsyncStream<AnalyzerInput>.Continuation? = lock.withLock {
            guard generation == token else { return nil }
            defer {
                continuation = nil
                analyzerFormat = nil
                accumulator = nil
            }
            return continuation
        }
        input?.finish()
    }

    // MARK: - Feeding

    /// Feeds one capture buffer. Called on the capture thread; converts synchronously
    /// because Core Audio buffers are only valid during the callback.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let format = analyzerFormat, let continuation else { return }
        guard let mono = MonoMixer.mix(buffer, fold: fold) else {
            diagnostics.update {
                $0.conversionFailures += 1
                $0.lastConversionError = "can't read \(StreamDiagnostics.describe(buffer.format))"
            }
            return
        }
        do {
            guard let converted = try converter.convert(mono, to: format) else { return }
            let chunks = accumulator?.append(converted) ?? [converted]
            for chunk in chunks {
                let rms = AudioLevelMeter.rms(of: chunk)
                let dropped: Bool
                switch continuation.yield(AnalyzerInput(buffer: chunk)) {
                case .terminated: continue   // nobody reads it; don't count it as fed
                case .dropped: dropped = true
                default: dropped = false
                }
                diagnostics.update {
                    $0.buffersToAnalyzer += 1
                    $0.framesToAnalyzer += Int(chunk.frameLength)
                    if rms > $0.analyzerPeakRMS { $0.analyzerPeakRMS = rms }
                    if rms > AudioLevelMeter.silenceRMS { $0.lastAudibleToAnalyzerAt = Date() }
                    if rms > Self.speechLevelRMS { $0.speechLevelChunks += 1 }
                    if dropped { $0.droppedChunks += 1 }
                }
            }
        } catch {
            let detail = String(describing: error)
            let first = diagnostics.read().conversionFailures == 0
            diagnostics.update {
                $0.conversionFailures += 1
                $0.lastConversionError = detail
            }
            if first {
                Log.speech.error("Audio conversion failed: \(detail, privacy: .public)")
            }
        }
    }

    // MARK: - Teardown

    /// Flushes the last words and stops. Bounded, so ending a meeting can't hang.
    func stop() async {
        let (analyzer, continuation, resultsTask, tail) = lock.withLock {
            () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?, AVAudioPCMBuffer?) in
            let current = (self.analyzer, self.continuation, self.resultsTask, self.accumulator?.flush())
            self.generation += 1
            self.analyzer = nil
            self.continuation = nil
            self.analyzerFormat = nil
            self.accumulator = nil
            self.resultsTask = nil
            return current
        }

        if let tail { continuation?.yield(AnalyzerInput(buffer: tail)) }
        continuation?.finish()

        if let analyzer {
            // finalizeAndFinishThroughEndOfInput keeps the last words; cancelAndFinishNow
            // drops pending finals, so it's only the fallback. Both are bounded, so
            // ending a meeting can't hang on the speech service.
            let finished = await firstResult(within: 3) { () -> Bool in
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    return true
                } catch {
                    return false
                }
            }
            if finished != true {
                _ = await firstResult(within: 1) { await analyzer.cancelAndFinishNow() }
            }
        }
        // The results sequence ends once the analyzer has finished; let the last
        // finals land, but never wait more than 2 s for them.
        if let resultsTask {
            _ = await firstResult(within: 2) { await resultsTask.value }
            resultsTask.cancel()
        }
        diagnostics.update { $0.transcriberState = "Stopped" }
    }

    // MARK: - Errors

    /// A short message for errors from setup or the results sequence.
    static func describe(_ error: Error) -> String {
        if let failure = error as? Failure, let message = failure.errorDescription {
            return message
        }
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }
}
