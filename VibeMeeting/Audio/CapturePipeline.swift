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
        /// System audio couldn't start or be rebuilt; `willRetry` when another attempt is scheduled.
        case systemAudioFailed(Error, willRetry: Bool)
        case systemAudioProblem(SystemAudioTap.Problem)
        /// A reported problem is over: sound or readable IO is back.
        case systemAudioProblemCleared(SystemAudioTap.Problem)
        /// A rebuild succeeded after failing.
        case systemAudioReconnected
        case appAudioNotFound
        /// The chosen app has audio processes again and is tapped on its own.
        case appAudioFound
        case micFailed(Error)
        case micReconnected
        /// Echo cancellation was asked for but had to be turned off (the reason says why).
        case voiceProcessingUnavailable(String)
        /// Echo cancellation was asked for but isn't used on this route (the reason says why).
        case voiceProcessingSkipped(String)
        /// Echo cancellation runs again after it was off.
        case voiceProcessingResumed
    }

    struct Configuration {
        var source: SystemAudioTap.Source
        var voiceProcessing: Bool
        /// Silence the mic where it only carries the call's voice from the speakers.
        var echoGate: Bool = true
    }

    let themDiagnostics = StreamDiagnostics(name: "Them (system audio)")
    let youDiagnostics = StreamDiagnostics(name: "You (microphone)")
    let themMeter = AudioLevelMeter()
    let youMeter = AudioLevelMeter()
    /// Uses the call's audio as the reference to find it in the mic.
    let echoGate = EchoGate()

    private let systemTap: SystemAudioTap
    private let mic: MicrophoneCapture
    private let themTranscriber: LiveTranscriber
    private let youTranscriber: LiveTranscriber
    /// System audio is metered and converted here, not on the Core Audio IO thread.
    private let systemProcessing = DispatchQueue(label: "VibeMeeting.CapturePipeline.system", qos: .userInitiated)
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

        // One after the other: both may need the same speech model download. After
        // every await, check that stop() didn't run meanwhile; anything started after
        // a stop would never be torn down.
        await startTranscriber(themTranscriber)
        guard isRunning else { return }
        await startTranscriber(youTranscriber)
        guard isRunning else { return }

        echoGate.reset()
        await startSystemAudio(configuration.source)
        guard isRunning else {
            await systemTap.stop()
            return
        }
        startMicrophone(voiceProcessing: configuration.voiceProcessing, echoGate: configuration.echoGate)
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        await systemTap.stop()
        mic.stop()
        // Let system audio already queued for processing reach the transcriber, so
        // the last words of a meeting aren't cut off.
        let processing = systemProcessing
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            processing.async { continuation.resume() }
        }
        await themTranscriber.stop()
        await youTranscriber.stop()
    }

    /// The per-stream part of the report. Synchronous, so it can be taken right
    /// before stopping without waiting on any system service.
    func streamReportLines() -> [String] {
        var lines = [
            "mic route: \(mic.routeSummary)",
            "voice processing active: \(mic.voiceProcessingActive)",
            "voice processing off because: \(mic.voiceProcessingOffReason ?? "–")",
            "speaker bleed gate: \(echoGateSummary)",
        ]
        for diagnostics in [themDiagnostics, youDiagnostics] {
            lines.append("")
            lines.append("[\(diagnostics.name)]")
            lines.append(contentsOf: diagnostics.read().reportLines())
        }
        return lines
    }

    /// A copyable plain-text report. Contains no transcript text.
    func report(extra: [String] = []) async -> String {
        let streams = streamReportLines()
        let environment = await AudioEnvironment.boundedReport()
        return (environment + extra + streams).joined(separator: "\n")
    }

    /// "on, coupled: lag 42 ms, -21 dB, r 0.83; muted 12.3 s of 300.0 s".
    var echoGateSummary: String {
        guard echoGateEnabled else { return "off" }
        let stats = echoGate.stats
        var coupling = "no speaker bleed found"
        if stats.isCoupled, let lag = stats.lagSeconds, let gain = stats.couplingGainDB {
            coupling = String(format: "bleed found: lag %.0f ms, %.0f dB", lag * 1000, gain)
            if let r = stats.correlation { coupling += String(format: ", r %.2f", r) }
        }
        return coupling + String(format: "; muted %.1f s of %.1f s", stats.gatedSeconds, stats.processedSeconds)
    }

    private var echoGateEnabled = false

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
                    self?.onEvent?(.transcriberFailed(speaker, error))
                }
            )
            return true
        } catch {
            Log.speech.error("Transcriber failed to start: \(String(describing: error), privacy: .public)")
            onEvent?(.transcriberFailed(speaker, error))
            return false
        }
    }

    private func startSystemAudio(_ source: SystemAudioTap.Source) async {
        let meter = themMeter
        let diagnostics = themDiagnostics
        let transcriber = themTranscriber
        let processing = systemProcessing
        let tap = systemTap
        let gate = echoGate
        tap.onReconnect = { [weak self] result, willRetry in
            switch result {
            case .success: self?.onEvent?(.systemAudioReconnected)
            case .failure(let error): self?.onEvent?(.systemAudioFailed(error, willRetry: willRetry))
            }
        }
        tap.onProblem = { [weak self] problem in
            self?.onEvent?(.systemAudioProblem(problem))
        }
        tap.onProblemCleared = { [weak self] problem in
            self?.onEvent?(.systemAudioProblemCleared(problem))
        }
        tap.onFallbackChange = { [weak self] fellBack in
            self?.onEvent?(fellBack ? .appAudioNotFound : .appAudioFound)
        }
        // Runs on the Core Audio IO thread with a buffer the tap already copied:
        // hand it on and return. The serial queue keeps the order.
        let handler: SystemAudioTap.BufferHandler = { buffer, hostTime in
            let owned = OwnedBuffer(buffer: buffer)
            processing.async {
                diagnostics.recordCapture(owned.buffer, rms: meter.update(with: owned.buffer))
                Self.feedReference(owned.buffer, hostTime: hostTime, to: gate)
                transcriber.append(owned.buffer)
            }
        }
        do {
            // Suspends rather than blocks: while the System Audio Recording prompt is
            // unanswered, creating the aggregate device can take a long time.
            try await tap.start(source: source, handler: handler)
            if tap.fellBackToAllAudio {
                onEvent?(.appAudioNotFound)
            }
        } catch {
            Log.audio.error("System audio failed: \(String(describing: error), privacy: .public)")
            diagnostics.update {
                $0.captureState = "Failed to start"
                $0.lastError = String(describing: error)
            }
            onEvent?(.systemAudioFailed(error, willRetry: false))
        }
    }

    private func startMicrophone(voiceProcessing: Bool, echoGate useGate: Bool) {
        let meter = youMeter
        let diagnostics = youDiagnostics
        let transcriber = youTranscriber
        let gate = useGate ? echoGate : nil
        echoGateEnabled = useGate
        mic.onReconnect = { [weak self] result in
            switch result {
            case .success: self?.onEvent?(.micReconnected)
            case .failure(let error): self?.onEvent?(.micFailed(error))
            }
        }
        mic.onVoiceProcessingFallback = { [weak self] reason in
            self?.onEvent?(.voiceProcessingUnavailable(reason))
        }
        // The user turned echo cancellation on, so a skip is reported too.
        mic.onVoiceProcessingSkipped = { [weak self] reason in
            self?.onEvent?(reason.map { .voiceProcessingSkipped($0) } ?? .voiceProcessingResumed)
        }
        do {
            diagnostics.update { $0.captureState = "Starting" }
            // Buffers arrive mono (channel 0 with echo cancellation, live channels
            // averaged without) and owned, so the gate can work in place and the
            // meter shows exactly what speech gets.
            try mic.start(voiceProcessing: voiceProcessing) { buffer, hostTime in
                if let gate, let samples = buffer.floatChannelData?[0] {
                    gate.process(
                        UnsafeMutableBufferPointer(start: samples, count: Int(buffer.frameLength)),
                        sampleRate: buffer.format.sampleRate,
                        startTime: AVAudioTime.seconds(forHostTime: hostTime)
                    )
                }
                diagnostics.recordCapture(buffer, rms: meter.update(with: buffer))
                transcriber.append(buffer)
            }
        } catch {
            Log.audio.error("Mic failed: \(String(describing: error), privacy: .public)")
            diagnostics.update {
                $0.captureState = "Failed to start"
                $0.lastError = String(describing: error)
            }
            onEvent?(.micFailed(error))
        }
    }
}

extension CapturePipeline {
    /// The call's audio, folded to mono, as the gate's reference.
    nonisolated static func feedReference(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, to gate: EchoGate) {
        let start = AVAudioTime.seconds(forHostTime: hostTime)
        let rate = buffer.format.sampleRate
        if buffer.format.channelCount == 1, !buffer.format.isInterleaved, let samples = buffer.floatChannelData?[0] {
            gate.addReference(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)), sampleRate: rate, startTime: start)
        } else if let mono = MonoMixer.mix(buffer, fold: .average), let samples = mono.floatChannelData?[0] {
            gate.addReference(UnsafeBufferPointer(start: samples, count: Int(mono.frameLength)), sampleRate: rate, startTime: start)
        }
    }
}

/// A buffer the tap copied for us, handed to another queue. Nothing else holds it.
private struct OwnedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
