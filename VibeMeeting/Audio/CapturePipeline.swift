import AVFoundation
import Foundation
import VibeCore

/// Both audio streams end to end: system audio → "Them" transcriber, mic →
/// "You" transcriber, with level meters and diagnostics. Used by a meeting and
/// by the Audio check window.
@MainActor
final class CapturePipeline {
    enum Event {
        case transcriberFailed(Speaker, Error)
        case systemAudioFailed(Error)
        case systemAudioReconnected
        case appAudioNotFound
        case micFailed(Error)
        case micReconnected
        case voiceProcessingUnavailable
    }

    struct Configuration {
        var source: SystemAudioTap.Source
        var voiceProcessing: Bool
    }

    let themDiagnostics = StreamDiagnostics(name: "Them (system audio)")
    let youDiagnostics = StreamDiagnostics(name: "You (microphone)")
    let themMeter = AudioLevelMeter()
    let youMeter = AudioLevelMeter()

    private let systemTap: SystemAudioTap
    private let mic: MicrophoneCapture
    private let themTranscriber: LiveTranscriber
    private let youTranscriber: LiveTranscriber
    private(set) var isRunning = false

    /// Recognizer output, in order, on the main actor.
    var onUpdate: ((TranscriptUpdate) -> Void)?
    var onEvent: ((Event) -> Void)?

    init() {
        systemTap = SystemAudioTap(diagnostics: themDiagnostics)
        mic = MicrophoneCapture(diagnostics: youDiagnostics)
        themTranscriber = LiveTranscriber(speaker: .them, diagnostics: themDiagnostics)
        youTranscriber = LiveTranscriber(speaker: .you, diagnostics: youDiagnostics)
    }

    /// Starts transcription first (so no audio is lost), then capture. A failure
    /// in one stream is reported and doesn't stop the other.
    func start(_ configuration: Configuration) async {
        guard !isRunning else { return }
        isRunning = true

        // One after the other: both may need the same speech model download.
        await startTranscriber(themTranscriber)
        await startTranscriber(youTranscriber)
        guard isRunning else { return }

        startSystemAudio(configuration.source)
        startMicrophone(voiceProcessing: configuration.voiceProcessing)
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        systemTap.stop()
        mic.stop()
        await themTranscriber.stop()
        await youTranscriber.stop()
    }

    /// A copyable plain-text report. Contains no transcript text.
    func report() async -> String {
        var lines = await AudioEnvironment.report()
        lines.append("voice processing active: \(mic.voiceProcessingActive)")
        for diagnostics in [themDiagnostics, youDiagnostics] {
            lines.append("")
            lines.append("[\(diagnostics.name)]")
            lines.append(contentsOf: diagnostics.read().reportLines())
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    @discardableResult
    private func startTranscriber(_ transcriber: LiveTranscriber) async -> Bool {
        let speaker = transcriber.speaker
        do {
            try await transcriber.start(
                onUpdate: { [weak self] update in
                    self?.onUpdate?(update)
                },
                onError: { [weak self] error in
                    Log.speech.error("Transcriber error: \(String(describing: error), privacy: .public)")
                    Task { @MainActor in self?.onEvent?(.transcriberFailed(speaker, error)) }
                }
            )
            return true
        } catch {
            Log.speech.error("Transcriber failed to start: \(String(describing: error), privacy: .public)")
            onEvent?(.transcriberFailed(speaker, error))
            return false
        }
    }

    private func startSystemAudio(_ source: SystemAudioTap.Source) {
        let meter = themMeter
        let diagnostics = themDiagnostics
        let transcriber = themTranscriber
        systemTap.onReconnect = { [weak self] result in
            switch result {
            case .success: self?.onEvent?(.systemAudioReconnected)
            case .failure(let error): self?.onEvent?(.systemAudioFailed(error))
            }
        }
        do {
            try systemTap.start(source: source) { buffer in
                diagnostics.recordCapture(buffer, rms: meter.update(with: buffer))
                transcriber.append(buffer)
            }
            if systemTap.fellBackToAllAudio {
                onEvent?(.appAudioNotFound)
            }
        } catch {
            Log.audio.error("System audio failed: \(String(describing: error), privacy: .public)")
            onEvent?(.systemAudioFailed(error))
        }
    }

    private func startMicrophone(voiceProcessing: Bool) {
        let meter = youMeter
        let diagnostics = youDiagnostics
        let transcriber = youTranscriber
        mic.onReconnect = { [weak self] result in
            switch result {
            case .success: self?.onEvent?(.micReconnected)
            case .failure(let error): self?.onEvent?(.micFailed(error))
            }
        }
        do {
            try mic.start(voiceProcessing: voiceProcessing) { buffer in
                diagnostics.recordCapture(buffer, rms: meter.update(with: buffer))
                transcriber.append(buffer)
            }
            if voiceProcessing && !mic.voiceProcessingActive {
                onEvent?(.voiceProcessingUnavailable)
            }
        } catch {
            Log.audio.error("Mic failed: \(String(describing: error), privacy: .public)")
            onEvent?(.micFailed(error))
        }
    }
}
