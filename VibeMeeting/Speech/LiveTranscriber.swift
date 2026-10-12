import AVFoundation
import Foundation
import Speech
import VibeCore

/// On-device English transcription for one audio stream (Them or You),
/// built on SpeechAnalyzer + SpeechTranscriber (macOS 26).
final class LiveTranscriber: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case unsupportedLocale
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale: return "English speech recognition isn't available on this Mac."
            case .noAudioFormat: return "Speech recognition couldn't pick an audio format."
            }
        }
    }

    /// Runs on the main actor; results are delivered one at a time, in order.
    typealias UpdateHandler = @MainActor @Sendable (TranscriptUpdate) -> Void

    let speaker: Speaker
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private let converter = BufferConverter()

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    static let preferredLocale = Locale(identifier: "en-US")

    /// Downloads the on-device English model if it isn't installed yet.
    static func prepareAssets() async throws {
        let transcriber = try await makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.speech.info("Downloading speech model")
            try await request.downloadAndInstall()
        }
    }

    private static func makeTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw Failure.unsupportedLocale }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) else {
            throw Failure.unsupportedLocale
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Volatile results drive the live subtitle; finals lock the text in.
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    func start(onUpdate: @escaping UpdateHandler, onError: @escaping @Sendable (Error) -> Void) async throws {
        let transcriber = try await Self.makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let speaker = self.speaker
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    // Awaiting keeps volatile and final results in order.
                    await onUpdate(TranscriptUpdate(speaker: speaker, kind: result.isFinal ? .final : .volatile, text: text))
                }
            } catch is CancellationError {
            } catch {
                onError(error)
            }
        }

        try await analyzer.start(inputSequence: stream)

        lock.withLock {
            self.analyzer = analyzer
            self.analyzerFormat = format
            self.inputContinuation = continuation
        }
        Log.speech.info("Transcriber started for \(speaker.rawValue, privacy: .public)")
    }

    /// Feeds one capture buffer. Called on the audio thread; converts synchronously
    /// because tap buffers are only valid during the callback.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let format = analyzerFormat
        let continuation = inputContinuation
        lock.unlock()
        guard let format, let continuation else { return }
        do {
            let converted = try converter.convert(buffer, to: format)
            continuation.yield(AnalyzerInput(buffer: converted))
        } catch {
            Log.speech.error("Audio conversion failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Flushes the last words and stops.
    func stop() async {
        let (analyzer, continuation) = lock.withLock {
            let current = (self.analyzer, inputContinuation)
            self.analyzer = nil
            inputContinuation = nil
            analyzerFormat = nil
            return current
        }

        continuation?.finish()
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }
        // Let the last final results arrive, but never hang the end of a meeting on it.
        if let task = resultsTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            task.cancel()
        }
        resultsTask = nil
    }
}
