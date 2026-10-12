import AVFoundation
import CoreAudio
import Foundation

/// Captures the user's own voice and always hands downstream an owned mono
/// Float32 copy at the input's sample rate, so the "You" meter shows exactly
/// what speech recognition gets.
///
/// Apple voice processing (echo cancellation) is skipped where it can't help or
/// is known to fail: Bluetooth or USB headphones, and a Bluetooth mic with other
/// speakers (that pairing fails with -10875). The headphone jack counts as
/// speakers, because it reports the same whether headphones or speakers are
/// plugged in. It falls back to a plain mic when it fails to start, delivers no
/// audio, or its processed channel stays digitally silent. A route that failed
/// once is not retried during this capture session.
final class MicrophoneCapture: @unchecked Sendable {
    /// An owned mono buffer and the host time (mach ticks) of its first sample.
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

    enum Failure: Error, LocalizedError {
        case noInputDevice
        case invalidInputFormat(String)
        case voiceProcessingNotEnabled
        case noAudio
        case tooManyRestarts

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone is selected in Sound settings."
            case .invalidInputFormat(let format): return "The microphone reported an unusable format (\(format))."
            case .voiceProcessingNotEnabled: return "Echo cancellation didn't turn on."
            case .noAudio: return "The microphone isn't delivering audio."
            case .tooManyRestarts: return "The audio device keeps changing, so the microphone stopped."
            }
        }
    }

    // Main thread only.
    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private var handler: BufferHandler?
    private var wantsVoiceProcessing = false
    private var configurationObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    /// The skip reason last announced, so a restart on the same route stays quiet.
    private var announcedSkip: String?
    private var pendingRestart: DispatchWorkItem?
    private var restartTimes: [Date] = []
    /// Bumped on every engine start, so stale health checks do nothing.
    private var generation = 0
    private var routeKey: String?
    private var brokenRoutes: Set<String> = []
    /// Replaced on every engine start, so a late buffer from a previous engine
    /// can't count toward the current engine's health check.
    private var health = CaptureHealth()
    private let diagnostics: StreamDiagnostics?

    /// Whether echo cancellation is running right now.
    private(set) var voiceProcessingActive = false
    /// Why echo cancellation isn't running although it was asked for (nil when running or not asked).
    private(set) var voiceProcessingOffReason: String?
    /// Input and output device, for the report.
    private(set) var routeSummary = "–"

    /// Main queue. Capture restarted after a device change, or stopped for good.
    var onReconnect: ((Result<Void, Error>) -> Void)?
    /// Main queue. Echo cancellation was asked for but had to be turned off.
    var onVoiceProcessingFallback: ((String) -> Void)?
    /// Main queue. Echo cancellation was asked for but isn't used on this route.
    var onVoiceProcessingSkipped: ((String) -> Void)?

    init(diagnostics: StreamDiagnostics? = nil) {
        self.diagnostics = diagnostics
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Call on the main thread.
    func start(voiceProcessing: Bool, handler: @escaping BufferHandler) throws {
        self.handler = handler
        wantsVoiceProcessing = voiceProcessing
        brokenRoutes = []
        restartTimes = []
        announcedSkip = nil
        // Watch before the first attempt: if it fails (no mic yet, device busy), a
        // mic appearing later still starts capture.
        observeConfigurationChanges()
        observeDefaultInput()
        try startChoosingMode()
    }

    /// Call on the main thread.
    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let block = defaultInputListener {
            var address = AudioObjectID.systemObject.address(kAudioHardwarePropertyDefaultInputDevice)
            // Removal only matches the very same block and queue.
            AudioObjectRemovePropertyListenerBlock(.systemObject, &address, .main, block)
            defaultInputListener = nil
        }
        teardown()
        handler = nil
        generation += 1
    }

    // MARK: - Starting

    private func startChoosingMode() throws {
        voiceProcessingOffReason = nil
        let route = AudioRoute.current()
        routeKey = route?.key
        routeSummary = route?.summary ?? "unknown"

        var tryVoiceProcessing = false
        if wantsVoiceProcessing {
            if let reason = AudioRoute.reasonToSkipVoiceProcessing(route) {
                // Not a failure, but the user turned it on, so say why it's off.
                voiceProcessingOffReason = reason
                if announcedSkip != reason {
                    announcedSkip = reason
                    let callback = onVoiceProcessingSkipped
                    DispatchQueue.main.async { callback?(reason) }
                }
            } else if let key = route?.key, brokenRoutes.contains(key) {
                voiceProcessingOffReason = "Echo cancellation failed earlier on these devices"
            } else {
                tryVoiceProcessing = true
            }
        }

        if tryVoiceProcessing {
            do {
                try startEngine(voiceProcessing: true)
                return
            } catch {
                Log.audio.error("Mic with voice processing failed: \(String(describing: error), privacy: .public)")
                teardown()
                markRouteBroken()
                announceFallback("Echo cancellation couldn't start on these devices (\(error.localizedDescription))")
            }
        }
        try startEngine(voiceProcessing: false)
    }

    private func startEngine(voiceProcessing: Bool) throws {
        generation += 1
        let generation = self.generation
        voiceProcessingActive = false

        // Touching inputNode without an input device can raise an Objective-C
        // exception, which Swift can't catch, so check for a device first.
        let inputDevice = (try? AudioObjectID.systemObject.read(kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID.unknown)) ?? .unknown
        guard inputDevice.isValid else { throw Failure.noInputDevice }

        // A fresh engine every time: voice processing state sticks to an engine.
        engine = AVAudioEngine()
        let input = engine.inputNode

        if voiceProcessing {
            // Only while the engine is stopped; it switches both I/O nodes.
            _ = engine.outputNode
            try input.setVoiceProcessingEnabled(true)
            guard input.isVoiceProcessingEnabled else { throw Failure.voiceProcessingNotEnabled }
            // Every other app's audio, including the call, counts as "other audio"
            // and is ducked; .min keeps it as loud as voice processing allows.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }

        // Read after enabling voice processing: it changes the channel count
        // (3, 5, 7 or 9 reported) and sometimes the sample rate.
        let format = input.outputFormat(forBus: 0)
        // installTap with a 0 Hz or 0-channel format raises an uncatchable exception.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Failure.invalidInputFormat(StreamDiagnostics.describe(format))
        }

        // Voice processing: the processed voice is channel 0; the others can be echo
        // references and must not be mixed in. Plain mic: average the live channels,
        // so a 2-channel interface with one mic on input 2 still works.
        let policy: MonoExtractor.Policy = voiceProcessing ? .firstChannel : .averageLiveChannels
        // Captured by value: the tap thread never reads properties that main writes.
        let handler = self.handler
        let health = CaptureHealth()
        health.reset(sampleRate: format.sampleRate)
        self.health = health
        let diagnostics = self.diagnostics

        // Tap at the node's own format (always valid). ~100 ms buffers.
        let bufferSize = AVAudioFrameCount(max(format.sampleRate / 10, 1024))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, when in
            guard let extraction = MonoExtractor.extract(buffer, policy: policy) else {
                diagnostics?.update { $0.unreadableBuffers += 1 }
                return
            }
            health.record(frames: Int(buffer.frameLength), extractedPeak: extraction.peak,
                          otherChannelsRMS: extraction.otherChannelsRMS)
            diagnostics?.recordChannels(extraction.channelRMS)
            handler?(extraction.mono, when.isHostTimeValid ? when.hostTime : mach_absolute_time())
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        voiceProcessingActive = voiceProcessing

        let mode = voiceProcessing ? "echo cancellation on" : "plain mic"
        let described = StreamDiagnostics.describe(format)
        let reason = voiceProcessingOffReason.map { " (echo cancellation off: \($0))" } ?? ""
        let detail = "\(routeSummary); \(mode); input \(described) → mono\(reason)"
        diagnostics?.update {
            $0.captureState = "Running, \(mode)"
            $0.deviceDetail = detail
            $0.channelPeakRMS = []
        }
        Log.audio.info("Mic started: \(detail, privacy: .public)")
        scheduleHealthCheck(generation: generation, after: 3, attempt: 1)
    }

    private func teardown() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        voiceProcessingActive = false
    }

    // MARK: - Fallback

    private func markRouteBroken() {
        if let routeKey { brokenRoutes.insert(routeKey) }
    }

    private func announceFallback(_ reason: String) {
        voiceProcessingOffReason = reason
        Log.audio.notice("Echo cancellation off: \(reason, privacy: .public)")
        let callback = onVoiceProcessingFallback
        DispatchQueue.main.async { callback?(reason) }
    }

    private func restartWithoutVoiceProcessing(_ reason: String) {
        markRouteBroken()
        teardown()
        announceFallback(reason)
        do {
            try startEngine(voiceProcessing: false)
        } catch {
            diagnostics?.update {
                $0.captureState = "Failed"
                $0.lastError = String(describing: error)
            }
            onReconnect?(.failure(error))
        }
    }

    // MARK: - Health checks (main queue)

    private func scheduleHealthCheck(generation: Int, after seconds: Double, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == generation, self.handler != nil else { return }
            self.checkHealth(generation: generation, attempt: attempt)
        }
    }

    private func checkHealth(generation: Int, attempt: Int) {
        let state = health.snapshot()

        if state.buffers == 0 {
            if voiceProcessingActive {
                restartWithoutVoiceProcessing("Echo cancellation delivered no audio on these devices")
            } else if attempt < 2 {
                // Bluetooth mics can take a moment to switch profiles.
                scheduleHealthCheck(generation: generation, after: 3, attempt: attempt + 1)
            } else {
                diagnostics?.update { $0.captureState = "No audio from the microphone" }
                onReconnect?(.failure(Failure.noAudio))
            }
            return
        }

        // A live mic always has a noise floor. If the processed channel never carried
        // a single non-zero sample while the other channels had sound (or for 10 s),
        // voice processing is broken on this route: the "meter moves, no words" case.
        if voiceProcessingActive && !state.extractedEverNonZero
            && (state.otherChannelsHadSignal || state.seconds >= 10) {
            restartWithoutVoiceProcessing("Echo cancellation produced only silence on these devices")
            return
        }

        if attempt < 4 {
            scheduleHealthCheck(generation: generation, after: 3, attempt: attempt + 1)
        }
    }

    // MARK: - Device changes (main queue)

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? AVAudioEngine) === self.engine, self.handler != nil else { return }
            self.scheduleRestart()
        }
    }

    /// The default input changed (a mic was plugged in or chosen). Unlike the
    /// engine notification, this fires even when no engine runs: the first start
    /// failed, or a restart found no input device.
    private func observeDefaultInput() {
        guard defaultInputListener == nil else { return }
        var address = AudioObjectID.systemObject.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.handler != nil else { return }
            // Same debounce as the engine notification; the two coalesce.
            self.scheduleRestart()
        }
        let status = AudioObjectAddPropertyListenerBlock(.systemObject, &address, .main, block)
        if status == noErr {
            defaultInputListener = block
        } else {
            Log.audio.error("Couldn't watch the default input device: \(status)")
        }
    }

    /// Device switches arrive in bursts; restart once they settle.
    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartAfterConfigurationChange() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func restartAfterConfigurationChange() {
        guard handler != nil else { return }
        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < 30 } + [now]
        let wasProcessing = voiceProcessingActive
        Log.audio.info("Audio configuration changed; restarting mic")
        teardown()
        diagnostics?.update {
            $0.rebuilds += 1
            $0.lastRebuildReason = "audio configuration changed"
        }

        if restartTimes.count > 5 {
            if wasProcessing {
                // Voice processing reconfiguring the device can trigger its own restarts.
                markRouteBroken()
                announceFallback("Echo cancellation kept resetting the audio device")
                restartTimes = [now]
            } else {
                diagnostics?.update { $0.captureState = "Stopped: device keeps changing" }
                onReconnect?(.failure(Failure.tooManyRestarts))
                return
            }
        }

        do {
            try startChoosingMode()
            onReconnect?(.success(()))
        } catch {
            diagnostics?.update {
                $0.captureState = "Failed"
                $0.lastError = String(describing: error)
            }
            onReconnect?(.failure(error))
        }
    }
}

// MARK: - Mono extraction

/// Turns any PCM buffer into an owned mono Float32 non-interleaved copy.
enum MonoExtractor {
    enum Policy: Sendable {
        /// Voice processing: the processed voice is channel 0.
        case firstChannel
        /// Plain mic: average the channels that carry sound.
        case averageLiveChannels
    }

    struct Extraction {
        let mono: AVAudioPCMBuffer
        /// Largest absolute sample in `mono`.
        let peak: Float
        /// RMS of channels 1… (0 with a single channel).
        let otherChannelsRMS: Float
        /// RMS of every raw channel, for diagnostics.
        let channelRMS: [Float]
    }

    static func extract(_ buffer: AVAudioPCMBuffer, policy: Policy) -> Extraction? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0,
              let read = sampleReader(for: buffer),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                             channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0]
        else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        var rms = [Float](repeating: 0, count: channels)
        for channel in 0..<channels {
            var sum: Float = 0
            for frame in 0..<frames {
                let sample = read(channel, frame)
                sum += sample * sample
            }
            rms[channel] = (sum / Float(frames)).squareRoot()
        }

        let used: [Int]
        switch policy {
        case .firstChannel:
            used = [0]
        case .averageLiveChannels:
            let live = (0..<channels).filter { rms[$0] > AudioLevelMeter.silenceRMS }
            used = live.isEmpty ? [0] : live
        }

        let scale = 1 / Float(used.count)
        var peak: Float = 0
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in used { sum += read(channel, frame) }
            let value = sum * scale
            destination[frame] = value
            peak = max(peak, abs(value))
        }

        var others: Float = 0
        if channels > 1 {
            var energy: Float = 0
            for channel in 1..<channels { energy += rms[channel] * rms[channel] }
            others = (energy / Float(channels - 1)).squareRoot()
        }
        return Extraction(mono: output, peak: peak, otherChannelsRMS: others, channelRMS: rms)
    }

    /// Reads sample (channel, frame) as a Float in -1…1 for any PCM layout.
    private static func sampleReader(for buffer: AVAudioPCMBuffer) -> ((Int, Int) -> Float)? {
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        if let data = buffer.floatChannelData {
            if interleaved { return { channel, frame in data[0][frame * stride + channel] } }
            return { channel, frame in data[channel][frame] }
        }
        if let data = buffer.int16ChannelData {
            let scale: Float = 1 / 32_768
            if interleaved { return { channel, frame in Float(data[0][frame * stride + channel]) * scale } }
            return { channel, frame in Float(data[channel][frame]) * scale }
        }
        if let data = buffer.int32ChannelData {
            let scale: Float = 1 / 2_147_483_648
            if interleaved { return { channel, frame in Float(data[0][frame * stride + channel]) * scale } }
            return { channel, frame in Float(data[channel][frame]) * scale }
        }
        return nil
    }
}

// MARK: - Health counters

/// Written by the tap thread, read on the main queue.
private final class CaptureHealth: @unchecked Sendable {
    struct Snapshot {
        var buffers = 0
        var seconds: Double = 0
        var extractedEverNonZero = false
        var otherChannelsHadSignal = false
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var frames = 0
    private var sampleRate: Double = 48_000

    func reset(sampleRate: Double) {
        lock.withLock {
            state = Snapshot()
            frames = 0
            self.sampleRate = sampleRate
        }
    }

    func record(frames newFrames: Int, extractedPeak: Float, otherChannelsRMS: Float) {
        lock.withLock {
            state.buffers += 1
            frames += newFrames
            state.seconds = Double(frames) / sampleRate
            if extractedPeak > 0 { state.extractedEverNonZero = true }
            if otherChannelsRMS > AudioLevelMeter.silenceRMS { state.otherChannelsHadSignal = true }
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock { state }
    }
}

// MARK: - Device route

/// The default input and output devices, as far as echo cancellation cares.
struct AudioRoute {
    let key: String
    let summary: String
    let inputTransport: UInt32
    let outputTransport: UInt32
    let outputIsHeadphones: Bool

    static func current() -> AudioRoute? {
        let system = AudioObjectID.systemObject
        guard let input = try? system.read(kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID.unknown),
              let output = try? system.read(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown),
              input.isValid, output.isValid
        else { return nil }
        let inputUID = (try? input.readString(kAudioDevicePropertyDeviceUID)) ?? String(input)
        let outputUID = (try? output.readString(kAudioDevicePropertyDeviceUID)) ?? String(output)
        let inputName = (try? input.readString(kAudioObjectPropertyName)) ?? inputUID
        let outputName = (try? output.readString(kAudioObjectPropertyName)) ?? outputUID
        let inputTransport = transport(of: input)
        let outputTransport = transport(of: output)
        let headphones = isHeadphones(output)
        return AudioRoute(
            key: "\(inputUID)>\(outputUID)",
            summary: "mic \(inputName) [\(fourCC(inputTransport))] → out \(outputName) [\(fourCC(outputTransport))\(headphones ? ", headphones" : "")]",
            inputTransport: inputTransport,
            outputTransport: outputTransport,
            outputIsHeadphones: headphones
        )
    }

    /// nil when echo cancellation is worth trying on this route.
    static func reasonToSkipVoiceProcessing(_ route: AudioRoute?) -> String? {
        guard let route else { return "Couldn't read the audio devices" }
        let bluetooth: Set<UInt32> = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
        if bluetooth.contains(route.outputTransport) {
            return "Bluetooth headphones in use, so there's no speaker echo to cancel"
        }
        // The built-in headphone jack reports 'hdpn' whatever is plugged in (macOS
        // calls it "External Headphones" with speakers too, common on a Mac mini),
        // so only a USB headset's headphone flag means there are no speakers.
        if route.outputIsHeadphones && route.outputTransport != kAudioDeviceTransportTypeBuiltIn {
            return "Headset in use, so there's no speaker echo to cancel"
        }
        if bluetooth.contains(route.inputTransport) {
            // AirPods mic + Mac speakers: voice processing fails with -10875.
            return "Echo cancellation doesn't work with a Bluetooth mic and other speakers"
        }
        return nil
    }

    private static func transport(of device: AudioObjectID) -> UInt32 {
        (try? device.read(kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
    }

    private static func isHeadphones(_ device: AudioObjectID) -> Bool {
        // Built-in output with the headphone jack in use ('hdpn' data source)…
        if let source = try? device.read(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)),
           source == code("hdpn") {
            return true
        }
        // …or any output stream whose terminal type is headphones.
        let streams = (try? device.readObjects(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)) ?? []
        return streams.contains { stream in
            (try? stream.read(kAudioStreamPropertyTerminalType, initial: UInt32(0))) == kAudioStreamTerminalTypeHeadphones
        }
    }

    private static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// 'blue', 'bltn', 'usb ' … for the report.
    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(value) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
