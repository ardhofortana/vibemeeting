import AVFoundation
import Foundation
import Speech
import VibeCore

/// On-device transcription for one audio stream (Them or You) in the meeting's
/// call language, built on SpeechAnalyzer + SpeechTranscriber (macOS 26), or
/// DictationTranscriber for the languages only Dictation supports. Two
/// instances run at once in the same locale, so they share the backing engine.
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
    /// Speech model download progress, 0 to 1, on the main actor.
    typealias ProgressHandler = @MainActor @Sendable (Double) -> Void

    let speaker: Speaker
    /// The call language this stream is transcribed in.
    let locale: Locale
    let diagnostics: StreamDiagnostics
    private let fold: MonoFold
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var accumulator: ChunkAccumulator?
    private var resultsTask: Task<Void, Never>?
    /// The locale this transcriber marked as in use, until it stops.
    private var localeInUse: String?
    /// Bumped by every start and stop (under `lock`). A start that finds it changed
    /// after its awaits was stopped meanwhile and must not install its analyzer.
    private var generation = 0
    private let converter = BufferConverter()

    /// RMS of a 100 ms chunk that counts as speech level (about -40 dBFS).
    static let speechLevelRMS: Float = 0.01

    init(speaker: Speaker, locale: Locale, diagnostics: StreamDiagnostics) {
        self.speaker = speaker
        self.locale = locale
        self.diagnostics = diagnostics
        // Mic: channel 0 (voice processing exposes discrete channels). System audio: average L/R.
        self.fold = speaker == .you ? .firstChannel : .average
    }

    // MARK: - Setup

    /// The module that turns one stream's speech into text.
    private enum Recognizer: Sendable {
        /// The more accurate model, for every language it supports.
        case speech(SpeechTranscriber)
        /// The model behind macOS Dictation, for languages SpeechTranscriber
        /// doesn't support (such as Indonesian and Malay).
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let transcriber): return transcriber
            case .dictation(let transcriber): return transcriber
            }
        }

        /// For diagnostics and logs.
        var name: String {
            switch self {
            case .speech: return "SpeechTranscriber"
            case .dictation: return "DictationTranscriber"
            }
        }

        /// Hands each result's text to `body`, in order, until the results end.
        /// Throws what ends them: an analyzer or module error, or cancellation.
        func forEachResult(_ body: (_ text: String, _ isFinal: Bool) async -> Void) async throws {
            switch self {
            case .speech(let transcriber):
                for try await result in transcriber.results {
                    await body(String(result.text.characters), result.isFinal)
                }
            case .dictation(let transcriber):
                for try await result in transcriber.results {
                    await body(String(result.text.characters), result.isFinal)
                }
            }
        }
    }

    /// A recognizer for `requested` and the exact locale it supports for it:
    /// SpeechTranscriber whenever it supports the language, since it's the more
    /// accurate model, else DictationTranscriber. Never another language.
    /// SpeechLanguages lists the call languages by the same rule.
    private static func makeTranscriber(for requested: Locale) async throws -> (recognizer: Recognizer, locale: Locale) {
        // The speech model's equivalent counts only in the same language.
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested),
           MeetingLanguage.isSameLanguage(locale.identifier(.bcp47), requested.identifier(.bcp47)) {
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                // Volatile results drive the live subtitle; finals lock the text in.
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            return (.speech(transcriber), locale)
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [],
                // Without punctuation Dictation writes none, and the transcript
                // splits sentences on it.
                transcriptionOptions: [.punctuation],
                // Frequent finals keep turns in order: without them Dictation
                // finalizes about once a minute, which keeps one side's turn
                // open while the other talks.
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: []
            )
            return (.dictation(transcriber), locale)
        }
        throw Failure.unsupportedLocale(requested.identifier(.bcp47))
    }

    /// Reserves the locale, downloads the model if needed (reporting progress),
    /// and waits until it's usable.
    private static func ensureAssets(for recognizer: Recognizer, locale: Locale, onProgress: ProgressHandler? = nil) async throws {
        try await reserve(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [recognizer.module]) {
            let progress = request.progress
            // Progress is read a few times a second while the download runs.
            let reporter = onProgress.map { report in
                Task {
                    while !Task.isCancelled {
                        await report(progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            do {
                try await request.downloadAndInstall()
            } catch {
                reporter?.cancel()
                throw error
            }
            reporter?.cancel()
            await onProgress?(1)
        }
        // downloadAndInstall() can return before the model is usable;
        // bestAvailableAudioFormat stays nil until it is.
        for _ in 0..<40 {
            if await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recognizer.module]) != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.assetsNotReady
    }

    /// Reservations are capped (5 measured) and persist across launches. When
    /// the cap is reached, one not used by a running transcriber makes room.
    private static func reserve(_ locale: Locale) async throws {
        let key = locale.identifier(.bcp47)
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == key }) { return }
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            guard reserved.count >= AssetInventory.maximumReservedLocales,
                  let stale = reserved.first(where: { $0.identifier(.bcp47) != key && !localesInUse.contains($0.identifier(.bcp47)) })
            else { throw error }
            await AssetInventory.release(reservedLocale: stale)
            try await AssetInventory.reserve(locale: locale)
        }
    }

    /// Downloads the model for `locale` up front (onboarding, Settings).
    static func prepareAssets(for locale: Locale, onProgress: ProgressHandler? = nil) async throws {
        let (recognizer, supported) = try await makeTranscriber(for: locale)
        try await ensureAssets(for: recognizer, locale: supported, onProgress: onProgress)
    }

    /// Locales that running transcribers use, which a new reservation never releases.
    private static let localesInUse = LocaleUsage()

    /// Starts transcribing. `onModelProgress` hears about a speech model download, if one is needed.
    func start(onUpdate: @escaping UpdateHandler, onError: @escaping ErrorHandler, onModelProgress: ProgressHandler? = nil) async throws {
        let token: Int? = lock.withLock {
            guard analyzer == nil else { return nil }
            generation += 1
            return generation
        }
        guard let token else { return }
        diagnostics.update { $0.transcriberState = .checkingModel }
        do {
            try await startAnalyzer(token: token, onUpdate: onUpdate, onError: onError, onModelProgress: onModelProgress)
        } catch {
            releaseLocale()
            diagnostics.update {
                $0.transcriberState = .failedToStart
                $0.lastError = Self.describe(error)
            }
            throw error
        }
    }

    private func startAnalyzer(token: Int, onUpdate: @escaping UpdateHandler, onError: @escaping ErrorHandler, onModelProgress: ProgressHandler?) async throws {
        let diagnostics = self.diagnostics
        let (recognizer, locale) = try await Self.makeTranscriber(for: self.locale)
        markLocaleInUse(locale.identifier(.bcp47))
        diagnostics.update {
            $0.transcriberState = .preparingModel
            $0.engine = recognizer.name
        }
        try await Self.ensureAssets(for: recognizer, locale: locale) { fraction in
            diagnostics.update { $0.transcriberState = .downloadingModel(percent: Int((fraction * 100).rounded())) }
            onModelProgress?(fraction)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recognizer.module]) else {
            throw Failure.noAudioFormat
        }
        diagnostics.update {
            $0.transcriberState = .startingAnalyzer
            $0.analyzerFormat = StreamDiagnostics.describe(format)
        }

        let analyzer = SpeechAnalyzer(
            modules: [recognizer.module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        // bufferingNewest drops the oldest chunk on overflow; 600 × 100 ms = 60 s of headroom.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(600))
        let speaker = self.speaker

        // Consume results before starting, as Apple's sample does, so nothing (not even an error) is missed.
        let resultsTask = Task { [weak self] in
            do {
                try await recognizer.forEachResult { text, isFinal in
                    diagnostics.update {
                        if isFinal { $0.finalResults += 1 } else { $0.volatileResults += 1 }
                        $0.lastResultAt = Date()
                    }
                    // Awaiting keeps volatile and final results in order.
                    await onUpdate(TranscriptUpdate(speaker: speaker, kind: isFinal ? .final : .volatile, text: text))
                }
                // A normal end is expected only after stop(), which bumps the generation.
                let stillRunning = self?.lock.withLock { self?.generation == token } ?? false
                if stillRunning, !Task.isCancelled {
                    self?.closeInput(token: token)
                    Log.speech.error("Transcriber \(speaker.rawValue, privacy: .public) results ended on their own")
                    diagnostics.update {
                        $0.transcriberState = .endedUnexpectedly
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
                    $0.transcriberState = .stoppedWithError
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
            releaseLocale()
            diagnostics.update { $0.transcriberState = .stopped }
            return
        }
        diagnostics.update { $0.transcriberState = .running(locale: locale.identifier(.bcp47), engine: recognizer.name) }
        Log.speech.info("Transcriber \(speaker.rawValue, privacy: .public) started on \(recognizer.name, privacy: .public), \(StreamDiagnostics.describe(format), privacy: .public)")
    }

    private func markLocaleInUse(_ key: String) {
        let previous: String? = lock.withLock {
            defer { localeInUse = key }
            return localeInUse
        }
        if let previous { Self.localesInUse.remove(previous) }
        Self.localesInUse.add(key)
    }

    private func releaseLocale() {
        let key: String? = lock.withLock {
            defer { localeInUse = nil }
            return localeInUse
        }
        if let key { Self.localesInUse.remove(key) }
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
        releaseLocale()
        diagnostics.update { $0.transcriberState = .stopped }
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

/// How many running transcribers use each locale (BCP 47).
private final class LocaleUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func add(_ key: String) {
        lock.withLock { counts[key, default: 0] += 1 }
    }

    func remove(_ key: String) {
        lock.withLock {
            let count = counts[key, default: 0] - 1
            counts[key] = count > 0 ? count : nil
        }
    }

    func contains(_ key: String) -> Bool {
        lock.withLock { counts[key] != nil }
    }
}
