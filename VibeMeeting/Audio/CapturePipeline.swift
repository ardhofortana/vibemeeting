import AVFoundation
import Foundation
import VibeCore

/// Both audio streams end to end: system audio → "Them" transcriber, mic →
/// "You" transcriber, with level meters and diagnostics. Both transcribe the
/// one call language. Used by a meeting and by the Audio check window.
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
    /// Uses the call's audio as the reference to find it in the mic. Delays
    /// start at zero: the acoustic delay (output latency, the air, input
    /// latency) is roughly +5 to +40 ms on these stamps. Accepting a mic ahead
    /// of the call audio would let call audio that carries the user's own voice
    /// (monitoring, a mic test) arm the gate on the user, and with the mic held
    /// for late call audio that gating would hit most of their words. If a
    /// device's stamps put the bleed before zero, the report shows it as the
    /// mic leading (the gate's search counters and best probe).
    let echoGate = EchoGate(configuration: .init())
    /// How the call audio and the mic line up at the gate, for the report.
    let echoTiming = EchoTiming()
    /// The call language both streams are transcribed in.
    let locale: Locale

    private let systemTap: SystemAudioTap
    private let mic: MicrophoneCapture
    private let themTranscriber: LiveTranscriber
    private let youTranscriber: LiveTranscriber
    /// System audio is metered and converted here, not on the Core Audio IO thread.
    private let systemProcessing = DispatchQueue(label: "VibeMeeting.CapturePipeline.system", qos: .userInitiated)
    /// Mic audio waits here until the call audio it overlaps has reached the
    /// gate: not at all while the call audio is on time, at most 0.3 s when
    /// it's late (a little latency for "You" only), never when it stopped.
    ///
    /// Why not feed the gate straight from the tap's IO thread instead: that
    /// only saves the queue hop (well under a millisecond normally), not the
    /// tap's own delivery delay or a stamp convention that puts the call audio
    /// behind the mic, and it would make the real-time thread wait on the
    /// gate's lock while the mic thread runs a coupling search. Holding the
    /// mic covers every source of lateness and touches no real-time thread.
    private let micHold = MicHold<HeldMicBuffer>()
    /// Gates one mic buffer and hands it on (meter, diagnostics, speech).
    /// Kept so `stop` can flush the hold through it.
    private var micRelease: (@Sendable (HeldMicBuffer) -> Void)?
    private(set) var isRunning = false

    /// Recognizer output, in order, on the main actor.
    var onUpdate: ((TranscriptUpdate) -> Void)?
    var onEvent: ((Event) -> Void)?
    /// Speech model download progress (0 to 1) while starting, when the call
    /// language's model isn't on this Mac yet.
    var onModelProgress: ((Double) -> Void)?

    /// `locale` is the call language, for both streams.
    init(locale: Locale) {
        self.locale = locale
        systemTap = SystemAudioTap(diagnostics: themDiagnostics)
        mic = MicrophoneCapture(diagnostics: youDiagnostics)
        themTranscriber = LiveTranscriber(speaker: .them, locale: locale, diagnostics: themDiagnostics)
        youTranscriber = LiveTranscriber(speaker: .you, locale: locale, diagnostics: youDiagnostics)
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
        micHold.reset()
        echoTiming.reset()
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
        // Let system audio already queued for processing reach the transcriber (and
        // the gate), so the last words of a meeting aren't cut off.
        let processing = systemProcessing
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            processing.async { continuation.resume() }
        }
        // Then the mic audio that was still waiting for it.
        if let release = micRelease {
            micHold.flush(release: release)
        }
        micRelease = nil
        await themTranscriber.stop()
        await youTranscriber.stop()
    }

    /// The per-stream part of the report. Synchronous, so it can be taken right
    /// before stopping without waiting on any system service.
    func streamReportLines() -> [String] {
        var lines = [
            "call language: \(locale.identifier(.bcp47))",
            "mic route: \(mic.routeSummary)",
            "voice processing active: \(mic.voiceProcessingActive)",
            "voice processing off because: \(mic.voiceProcessingOffReason ?? "–")",
            "speaker bleed gate: \(echoGateSummary)",
        ]
        lines.append(contentsOf: echoGateReportLines())
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

    /// "bleed found: lag 42 ms, -21 dB, r 0.83; muted 12.3 s of 300.0 s".
    /// A coupling found earlier that no longer arms the gate (held too long
    /// without a new sighting) still shows, so "never found" and "found, but
    /// not now" read differently; so does mic audio the gate couldn't judge
    /// because the call audio wasn't in yet.
    var echoGateSummary: String {
        guard echoGateEnabled else { return "off" }
        let stats = echoGate.stats
        var text = "no speaker bleed found"
        if let lag = stats.lagSeconds, let gain = stats.couplingGainDB {
            var coupling = String(format: "lag %.0f ms, %.0f dB", lag * 1000, gain)
            if let r = stats.correlation { coupling += String(format: ", r %.2f", r) }
            text = stats.isCoupled ? "bleed found: \(coupling)" : "bleed found earlier, not armed now: \(coupling)"
        }
        text += String(format: "; muted %.1f s of %.1f s", stats.gatedSeconds, stats.processedSeconds)
        let unjudged = echoGate.stats.unknownReferenceSeconds
        if unjudged >= 0.05 {
            text += String(format: "; %.1f s unjudged (call audio late)", unjudged)
        }
        return text
    }

    /// One line for the Audio check: how the call audio lines up with the mic
    /// at the gate, and how long the mic waited for it.
    var echoTimingSummary: String {
        var text = echoTiming.summary
        let hold = micHold.stats
        if hold.releasedBuffers > 0 {
            text += String(format: "; mic waited in %d of %d buffers, at most %.0f ms",
                           hold.heldBuffers, hold.releasedBuffers, hold.maxHeldSeconds * 1000)
        }
        return text
    }

    /// The gate's full state and the timing behind it, for the report.
    private func echoGateReportLines() -> [String] {
        var lines: [String] = []
        if echoGateEnabled {
            // Every field, including any VibeCore adds later (best candidate,
            // why windows were rejected), without naming them here.
            let stats = echoGate.stats
            lines.append("  gate searches: \(stats.searches.summary)")
            lines.append("  gate best recent: \(stats.bestRecent?.summary ?? "–")")
            lines.append("  gate best this meeting: \(stats.bestOverall?.summary ?? "–")")
            lines.append(String(format: "  call audio behind mic end: %.0f ms avg, %.0f ms max",
                                stats.referenceTrailSeconds * 1000, stats.maxReferenceTrailSeconds * 1000))
            lines.append("  gate stats: \(stats)")
            lines.append(String(format: "  mic audio not judged, call audio not in yet: %.1f s", echoGate.stats.unknownReferenceSeconds))
            let hold = micHold.stats
            let mean = hold.heldBuffers > 0 ? hold.heldSeconds / Double(hold.heldBuffers) : 0
            lines.append(String(format: "  mic held for call audio: %d of %d buffers, mean %.0f ms, max %.0f ms, %d left without it",
                                hold.heldBuffers, hold.releasedBuffers, mean * 1000, hold.maxHeldSeconds * 1000, hold.timedOutBuffers))
        }
        lines.append(contentsOf: echoTiming.reportLines())
        return lines
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
                },
                onModelProgress: { [weak self] fraction in
                    self?.onModelProgress?(fraction)
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
        let hold = micHold
        let timing = echoTiming
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
            // Read here, so the report shows the queue's wait.
            let delivered = mach_absolute_time()
            let owned = OwnedBuffer(buffer: buffer)
            processing.async {
                // The gate first: mic audio may be waiting for exactly this.
                if let span = Self.feedReference(owned.buffer, hostTime: hostTime, to: gate) {
                    hold.referenceArrived(through: span.end)
                    timing.recordReference(
                        start: span.start,
                        end: span.end,
                        deliveredAt: AVAudioTime.seconds(forHostTime: delivered),
                        fedAt: AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    )
                }
                diagnostics.recordCapture(owned.buffer, rms: meter.update(with: owned.buffer))
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
                $0.captureState = .failedToStart
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
        let hold = micHold
        let timing = echoTiming
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
        // Buffers arrive mono (channel 0 with echo cancellation, live channels
        // averaged without) and owned, so the gate can work in place and the
        // meter shows exactly what speech gets. Runs on the mic's tap thread, or
        // on the main actor for the final flush; the hold serializes the two.
        let release: @Sendable (HeldMicBuffer) -> Void = { held in
            let buffer = held.buffer
            if let gate, let samples = buffer.floatChannelData?[0] {
                timing.recordMicJudged(end: held.end, referenceThrough: hold.referenceArrivedThrough)
                gate.process(
                    UnsafeMutableBufferPointer(start: samples, count: Int(buffer.frameLength)),
                    sampleRate: buffer.format.sampleRate,
                    startTime: held.start
                )
            }
            diagnostics.recordCapture(buffer, rms: meter.update(with: buffer))
            transcriber.append(buffer)
        }
        micRelease = release
        do {
            diagnostics.update { $0.captureState = .starting }
            try mic.start(voiceProcessing: voiceProcessing) { buffer, hostTime in
                let delivered = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                let start = AVAudioTime.seconds(forHostTime: hostTime)
                let rate = buffer.format.sampleRate
                let end = rate > 0 ? start + Double(buffer.frameLength) / rate : start
                let held = HeldMicBuffer(buffer: buffer, start: start, end: end)
                timing.recordMicDelivered(start: start, end: end, deliveredAt: delivered,
                                          referenceThrough: hold.referenceArrivedThrough)
                guard let gate else {
                    release(held)
                    return
                }
                // While armed, the gate needs the call audio at its delay; while
                // searching, through the buffer's end (see MicHold).
                let stats = gate.stats
                let needed = MicHold<HeldMicBuffer>.referenceNeeded(
                    forMicEndingAt: end,
                    coupledLag: stats.isCoupled ? stats.lagSeconds : nil
                )
                hold.push(held, end: end, referenceNeeded: needed, release: release)
            }
        } catch {
            Log.audio.error("Mic failed: \(String(describing: error), privacy: .public)")
            diagnostics.update {
                $0.captureState = .failedToStart
                $0.lastError = String(describing: error)
            }
            onEvent?(.micFailed(error))
        }
    }
}

extension CapturePipeline {
    /// The call's audio, folded to mono, as the gate's reference. Returns the
    /// span it covers on the host clock, in seconds (nil when unusable).
    @discardableResult
    nonisolated static func feedReference(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, to gate: EchoGate) -> (start: Double, end: Double)? {
        let start = AVAudioTime.seconds(forHostTime: hostTime)
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        guard frames > 0, rate > 0 else { return nil }
        if buffer.format.channelCount == 1, !buffer.format.isInterleaved, let samples = buffer.floatChannelData?[0] {
            gate.addReference(UnsafeBufferPointer(start: samples, count: frames), sampleRate: rate, startTime: start)
        } else if let mono = MonoMixer.mix(buffer, fold: .average), let samples = mono.floatChannelData?[0] {
            gate.addReference(UnsafeBufferPointer(start: samples, count: Int(mono.frameLength)), sampleRate: rate, startTime: start)
        } else {
            return nil
        }
        return (start, start + Double(frames) / rate)
    }
}

/// A buffer the tap copied for us, handed to another queue. Nothing else holds it.
private struct OwnedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// A mic buffer (owned, mono) and its span on the host clock, in seconds,
/// while it waits in the hold. Only the hold's lock holder touches it.
private struct HeldMicBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let start: Double
    let end: Double
}
