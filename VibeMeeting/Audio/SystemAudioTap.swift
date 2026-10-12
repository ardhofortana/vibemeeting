import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Captures what the other side says by tapping system audio with a Core Audio
/// process tap.
///
/// The aggregate device holds ONLY the tap. No output device is added as a
/// sub-device: when that output is a headset (AirPods, any Bluetooth or USB
/// headset), its microphone becomes an extra input stream in the IO buffer list,
/// `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` returns nil on every cycle, and
/// running that microphone forces a Bluetooth headset into hands-free mode.
final class SystemAudioTap: @unchecked Sendable {
    enum Source: Equatable {
        /// Everything the Mac plays, except VibeMeeting itself.
        case allSystemAudio
        /// Only the processes belonging to one app (e.g. "us.zoom.xos").
        case app(bundleID: String)
    }

    enum Problem: Equatable {
        /// IO runs and other apps are playing, but the tap delivers exact zeros even
        /// after a rebuild. Almost always the System Audio Recording grant: an ad-hoc
        /// ("Sign to Run Locally") build whose grant belongs to an older binary.
        case silentWhileOthersPlay
        /// Buffers keep arriving in a layout that doesn't match the tap stream.
        case unreadableBuffers
        /// The aggregate device stopped calling the IO block while other apps play.
        case noAudioIO
    }

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    /// Creates, destroys and rebuilds the tap; receives property notifications.
    private let controlQueue = DispatchQueue(label: "VibeMeeting.SystemAudioTap.control")
    /// Core Audio dispatches IO blocks synchronously onto this queue. Nothing else
    /// ever runs here, so AudioDeviceStop (called from controlQueue or main) can't
    /// deadlock against an IO cycle that is waiting for the queue.
    private let ioQueue = DispatchQueue(label: "VibeMeeting.SystemAudioTap.io", qos: .userInteractive)
    private let diagnostics: StreamDiagnostics?

    // Everything below is only touched on controlQueue.
    private var source: Source = .allSystemAudio
    private var handler: BufferHandler?
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var stream: TapStream?
    private var tappedProcesses: Set<AudioObjectID> = []
    private var listeners: [Listener] = []
    private var generation = 0
    private var watchdog: DispatchSourceTimer?
    private var pendingRebuild: DispatchWorkItem?
    private var failedRebuilds = 0
    /// Watchdog-triggered rebuilds since audio was last heard; capped so a broken
    /// setup is reported instead of rebuilt forever.
    private var recoveryRebuilds = 0
    private var silentRebuilds = 0
    private var reportedProblem: Problem?

    /// Called on the main queue after the tap was rebuilt (or failed to rebuild).
    var onReconnect: ((Result<Void, Error>) -> Void)?
    /// Called on the main queue when capture is running but unusable.
    var onProblem: ((Problem) -> Void)?

    /// True when an app source was requested but none of its processes were found.
    private(set) var fellBackToAllAudio = false

    init(diagnostics: StreamDiagnostics? = nil) {
        self.diagnostics = diagnostics
    }

    /// Call off the main thread when you can: while the System Audio Recording
    /// prompt is unanswered, creating/starting the aggregate device blocks until
    /// the user answers it.
    func start(source: Source, handler: @escaping BufferHandler) throws {
        try controlQueue.sync {
            self.source = source
            self.handler = handler
            failedRebuilds = 0
            recoveryRebuilds = 0
            silentRebuilds = 0
            reportedProblem = nil
            try startTap()
            startWatchdog()
        }
    }

    func stop() {
        controlQueue.sync {
            handler = nil
            pendingRebuild?.cancel()
            pendingRebuild = nil
            watchdog?.cancel()
            watchdog = nil
            stopTap()
        }
    }

    // MARK: - Tap lifecycle (controlQueue)

    private func startTap() throws {
        generation += 1
        let description = makeTapDescription()
        description.uuid = UUID()
        description.name = "VibeMeeting"
        description.isPrivate = true          // visible only to this process; tapautostart needs a private aggregate
        description.muteBehavior = .unmuted   // never take the call away from the user's ears

        var newTap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &newTap), "Creating process tap")
        tapID = newTap

        do {
            let tapUID = description.uuid.uuidString
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "VibeMeeting Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                // IO runs even while nothing plays, so a missing heartbeat means a dead
                // tap, not a quiet call.
                kAudioAggregateDeviceTapAutoStartKey: false,
                // Deliberately no kAudioAggregateDeviceSubDeviceListKey and no
                // kAudioAggregateDeviceMainSubDeviceKey: the IO buffer list then holds
                // the tap stream and nothing else.
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]

            var newAggregate = AudioObjectID.unknown
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregate), "Creating aggregate device")
            aggregateID = newAggregate

            let stream = try TapStream(tapID: tapID, aggregateID: aggregateID)
            self.stream = stream
            diagnostics?.update {
                $0.sourceFormat = stream.summary
                $0.captureState = "Starting"
            }

            let handler = self.handler
            let diagnostics = self.diagnostics
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inputData, _, _, _ in
                // Copies the tap's samples out; the IO buffer list dies with this cycle.
                guard let buffer = stream.read(inputData) else {
                    diagnostics?.update { $0.unreadableBuffers += 1 }
                    return
                }
                handler?(buffer)
            }, "Creating IO proc")

            try check(AudioDeviceStart(aggregateID, procID), "Starting aggregate device")
            installListeners()
            diagnostics?.update { $0.captureState = "Running" }
            Log.audio.info("System audio tap started: \(stream.summary, privacy: .public)")
        } catch {
            stopTap()
            throw error
        }
    }

    private func stopTap() {
        removeListeners()
        if aggregateID.isValid {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = .unknown
        tapID = .unknown
        stream = nil
    }

    private func makeTapDescription() -> CATapDescription {
        fellBackToAllAudio = false
        tappedProcesses = []
        if case .app(let bundleID) = source {
            let processes = Self.processes(for: bundleID)
            if !processes.isEmpty {
                tappedProcesses = Set(processes)
                let description = CATapDescription(monoMixdownOfProcesses: processes)
                // macOS 26: re-attach these processes by bundle ID if they exit and relaunch.
                description.isProcessRestoreEnabled = true
                return description
            }
            fellBackToAllAudio = true
            Log.audio.notice("No audio processes for the chosen app; tapping all system audio")
        }
        // A global tap is not tied to an output device: it hears every process,
        // whichever speaker or headset that process plays to.
        let own = AudioObjectID.process(for: ProcessInfo.processInfo.processIdentifier).map { [$0] } ?? []
        return CATapDescription(monoGlobalTapButExcludeProcesses: own)
    }

    /// The app's processes and helpers. Safari plays web audio (Meet, Teams on the
    /// web) from the shared WebKit GPU process, which has its own bundle ID.
    private static func processes(for bundleID: String) -> [AudioObjectID] {
        var processes = AudioProcessCatalog.processObjects(matching: bundleID)
        if bundleID == "com.apple.Safari" {
            processes += AudioProcessCatalog.processObjects(matching: "com.apple.WebKit.GPU")
        }
        return processes
    }

    // MARK: - Change detection (controlQueue)

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private func installListeners() {
        addListener(.systemObject, kAudioHardwarePropertyDefaultOutputDevice)
        addListener(.systemObject, kAudioHardwarePropertyProcessObjectList)
        addListener(tapID, kAudioTapPropertyFormat)
        addListener(aggregateID, kAudioDevicePropertyNominalSampleRate)
        addListener(aggregateID, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        addListener(aggregateID, kAudioDevicePropertyDeviceIsAlive)
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = object.address(selector, scope: scope)
        let generation = self.generation
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.propertyChanged(selector, generation: generation)
        }
        // Listener blocks are dispatched asynchronously onto controlQueue.
        let status = AudioObjectAddPropertyListenerBlock(object, &address, controlQueue, block)
        if status == noErr {
            listeners.append(Listener(object: object, address: address, block: block))
        } else {
            Log.audio.error("Couldn't watch property \(selector) of \(object): \(status)")
        }
    }

    private func removeListeners() {
        for var listener in listeners {
            // Removal only matches when the very same block object is passed back.
            let status = AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, controlQueue, listener.block)
            if status != noErr {
                Log.audio.error("Couldn't remove listener \(listener.address.mSelector): \(status)")
            }
        }
        listeners.removeAll()
    }

    private func propertyChanged(_ selector: AudioObjectPropertySelector, generation: Int) {
        // A notification from an older tap (or one already queued at stop) is ignored.
        guard generation == self.generation, handler != nil, let stream else { return }
        switch selector {
        case kAudioHardwarePropertyProcessObjectList:
            if case .app(let bundleID) = source, Set(Self.processes(for: bundleID)) != tappedProcesses {
                scheduleRebuild("the app's audio processes changed")
            }
        case kAudioDevicePropertyDeviceIsAlive:
            scheduleRebuild("the aggregate device died")
        default:
            // Default output, tap format, sample rate or stream layout moved
            // (e.g. AirPods switching to hands-free at 16/24 kHz).
            let current = try? TapStream.formats(tapID: tapID, aggregateID: aggregateID)
            if current?.tap != stream.tapFormat || current?.stream != stream.format {
                scheduleRebuild("the tap format changed")
            }
        }
    }

    private func scheduleRebuild(_ reason: String, after delay: TimeInterval = 0.5) {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(reason) }
        pendingRebuild = work
        controlQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuild(_ reason: String) {
        pendingRebuild = nil
        guard handler != nil else { return }
        Log.audio.info("Rebuilding system audio tap: \(reason, privacy: .public)")
        stopTap()
        let result: Result<Void, Error>
        do {
            try startTap()
            failedRebuilds = 0
            result = .success(())
        } catch {
            Log.audio.error("Rebuilding tap failed: \(error.localizedDescription, privacy: .public)")
            diagnostics?.update {
                $0.captureState = "Failed"
                $0.lastError = error.localizedDescription
            }
            failedRebuilds += 1
            if failedRebuilds <= 4 {
                scheduleRebuild(reason, after: Double(1 << (failedRebuilds - 1)))
            }
            result = .failure(error)
        }
        DispatchQueue.main.async { [weak self] in self?.onReconnect?(result) }
    }

    // MARK: - Watchdog (controlQueue)

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        watchdog = timer
    }

    private func checkHealth() {
        guard handler != nil, pendingRebuild == nil, let stream else { return }
        let health = stream.health()
        guard health.age > 3 else { return }

        if health.secondsSinceSignal < 1 {
            recoveryRebuilds = 0
            silentRebuilds = 0
            reportedProblem = nil
            return
        }

        if health.consecutiveUnreadable >= 100 {
            report(.unreadableBuffers)
            recover("IO buffers don't match the tap stream")
            return
        }

        // Only judge silence while another process is actually playing. A muted or
        // quiet call still reports output, so the window is generous.
        guard AudioProcessCatalog.anyOtherProcessPlaying() else { return }
        if health.secondsSinceCycle > 3 {
            report(.noAudioIO)
            recover("IO stalled")
        } else if health.secondsSinceSignal > 15 {
            if silentRebuilds == 0 {
                // A grant given while a tap exists only takes effect on a new tap.
                silentRebuilds = 1
                recover("only digital silence while other apps play")
            } else if health.secondsSinceSignal > 30 {
                report(.silentWhileOthersPlay)
            }
        }
    }

    private func recover(_ reason: String) {
        guard recoveryRebuilds < 3 else { return }
        recoveryRebuilds += 1
        scheduleRebuild(reason)
    }

    private func report(_ problem: Problem) {
        guard reportedProblem != problem else { return }
        reportedProblem = problem
        DispatchQueue.main.async { [weak self] in self?.onProblem?(problem) }
    }
}

// MARK: - The tap's stream inside the aggregate device

/// The format the IO cycle delivers and the per-cycle reader. `read` runs on the
/// IO queue only; the counters are shared with the watchdog under a lock.
private final class TapStream: @unchecked Sendable {
    struct Health {
        var age: TimeInterval
        var consecutiveUnreadable: Int
        var secondsSinceCycle: TimeInterval
        var secondsSinceSignal: TimeInterval
    }

    /// What the tap reports (kAudioTapPropertyFormat).
    let tapFormat: AVAudioFormat
    /// What the aggregate's tap stream carries; this is what the IO buffers hold.
    let format: AVAudioFormat
    let summary: String

    private let buffersPerCycle: Int
    private let channelsPerBuffer: UInt32
    private let bytesPerFrame: UInt32
    private let isFloat32: Bool

    private let lock = NSLock()
    private let startedAt: TimeInterval
    private var consecutiveUnreadable = 0
    private var lastCycleAt: TimeInterval
    private var lastSignalAt: TimeInterval

    /// Digital silence. A dead tap delivers exact zeros; a live call's comfort
    /// noise sits far above this.
    private static let silence: Float = 1e-6

    static func formats(tapID: AudioObjectID, aggregateID: AudioObjectID) throws
        -> (tap: AVAudioFormat, stream: AVAudioFormat, inputStreams: Int) {
        var tapDescription = try tapID.read(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let tap = AVAudioFormat(streamDescription: &tapDescription) else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareUnsupportedOperationError), operation: "Reading tap format")
        }
        // The aggregate's input streams. Tap-only, that is exactly one: the tap's.
        // (With sub-devices, v2s saw the sub-device inputs ahead of the tap.) A
        // freshly created aggregate can briefly report none; fall back to the tap's.
        let inputStreams = (try? aggregateID.readObjects(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) ?? []
        var stream = tap
        if let tapStream = inputStreams.last,
           var streamDescription = try? tapStream.read(kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()),
           let format = AVAudioFormat(streamDescription: &streamDescription) {
            stream = format
        }
        return (tap, stream, inputStreams.count)
    }

    init(tapID: AudioObjectID, aggregateID: AudioObjectID) throws {
        let formats = try Self.formats(tapID: tapID, aggregateID: aggregateID)
        let stream = formats.stream
        let bytesPerFrame = stream.streamDescription.pointee.mBytesPerFrame
        let buffersPerCycle = stream.isInterleaved ? 1 : Int(stream.channelCount)
        guard bytesPerFrame > 0, buffersPerCycle > 0 else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareUnsupportedOperationError), operation: "Reading tap stream format")
        }
        if formats.inputStreams > 1 {
            Log.audio.error("Tap aggregate has \(formats.inputStreams) input streams; expected only the tap")
        }

        self.tapFormat = formats.tap
        self.format = stream
        self.bytesPerFrame = bytesPerFrame
        self.buffersPerCycle = buffersPerCycle
        self.channelsPerBuffer = stream.isInterleaved ? stream.channelCount : 1
        self.isFloat32 = stream.commonFormat == .pcmFormatFloat32
        self.summary = "\(StreamDiagnostics.describe(stream)); tap reports \(StreamDiagnostics.describe(formats.tap)); "
            + "aggregate input streams: \(formats.inputStreams)"
        let now = ProcessInfo.processInfo.systemUptime
        self.startedAt = now
        self.lastCycleAt = now
        self.lastSignalAt = now
    }

    /// Copies this cycle's tap audio into a buffer that owns its samples, or nil
    /// when the buffer list doesn't hold a run of buffers shaped like the tap stream.
    func read(_ inputData: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        let now = ProcessInfo.processInfo.systemUptime
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        var copy: AVAudioPCMBuffer?
        var hasSignal = false

        if let start = tapBufferStart(in: list) {
            let frames = AVAudioFrameCount(list[start].mDataByteSize / bytesPerFrame)
            if let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                output.frameLength = frames
                let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                if destination.count == buffersPerCycle {
                    var copied = true
                    for index in 0..<buffersPerCycle {
                        let source = list[start + index]
                        guard let from = source.mData, let to = destination[index].mData,
                              destination[index].mDataByteSize >= source.mDataByteSize else {
                            copied = false
                            break
                        }
                        memcpy(to, from, Int(source.mDataByteSize))
                        if isFloat32, !hasSignal {
                            hasSignal = Self.containsSignal(from, byteCount: source.mDataByteSize)
                        }
                    }
                    if copied { copy = output }
                }
            }
        }

        lock.withLock {
            lastCycleAt = now
            if copy == nil {
                consecutiveUnreadable += 1
            } else {
                consecutiveUnreadable = 0
                // Non-float formats can't be checked cheaply; treat them as live.
                if hasSignal || !isFloat32 { lastSignalAt = now }
            }
        }
        return copy
    }

    func health() -> Health {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            Health(
                age: now - startedAt,
                consecutiveUnreadable: consecutiveUnreadable,
                secondsSinceCycle: now - lastCycleAt,
                secondsSinceSignal: now - lastSignalAt
            )
        }
    }

    /// With a tap-only aggregate the list holds exactly the tap's buffers. Should a
    /// sub-device ever sneak in, take the trailing run (v2s saw sub-device inputs
    /// ahead of the tap; one other project reported the reverse, so this is only a
    /// fallback, and the watchdog rebuilds if cycles stay unreadable).
    private func tapBufferStart(in list: UnsafeMutableAudioBufferListPointer) -> Int? {
        guard list.count >= buffersPerCycle else { return nil }
        let start = list.count - buffersPerCycle
        let byteSize = list[start].mDataByteSize
        guard byteSize > 0, byteSize % bytesPerFrame == 0 else { return nil }
        for index in start..<list.count {
            let buffer = list[index]
            guard buffer.mData != nil,
                  buffer.mDataByteSize == byteSize,
                  buffer.mNumberChannels == channelsPerBuffer else { return nil }
        }
        return start
    }

    private static func containsSignal(_ data: UnsafeMutableRawPointer, byteCount: UInt32) -> Bool {
        let count = Int(byteCount) / MemoryLayout<Float>.size
        let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        for sample in samples where abs(sample) > silence {
            return true
        }
        return false
    }
}

/// Apps currently known to Core Audio, for the "capture one app" setting.
enum AudioProcessCatalog {
    struct AudioApp: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let isPlaying: Bool
    }

    /// Process objects whose bundle ID is the app's or one of its helpers'
    /// (e.g. "com.google.Chrome" also matches "com.google.Chrome.helper").
    static func processObjects(matching bundleID: String) -> [AudioObjectID] {
        let objects = (try? AudioObjectID.systemObject.readObjectList(kAudioHardwarePropertyProcessObjectList)) ?? []
        return objects.filter { object in
            guard let id = try? object.readString(kAudioProcessPropertyBundleID) else { return false }
            return id == bundleID || id.hasPrefix(bundleID + ".")
        }
    }

    /// Apps with a Core Audio process object, grouped by their main app.
    static func apps() -> [AudioApp] {
        let objects = (try? AudioObjectID.systemObject.readObjectList(kAudioHardwarePropertyProcessObjectList)) ?? []
        let ownBundleID = Bundle.main.bundleIdentifier
        var byBundle: [String: AudioApp] = [:]
        for object in objects {
            guard let pid = try? object.read(kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0 else { continue }
            let running = NSRunningApplication(processIdentifier: pid)
            guard var bundleID = running?.bundleIdentifier ?? (try? object.readString(kAudioProcessPropertyBundleID)),
                  !bundleID.isEmpty, bundleID != ownBundleID else { continue }
            // Fold helpers into their parent app where the parent is running.
            for app in NSWorkspace.shared.runningApplications {
                if let parent = app.bundleIdentifier, bundleID.hasPrefix(parent + ".") {
                    bundleID = parent
                    break
                }
            }
            let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
                ?? running?.localizedName ?? bundleID
            let playing = ((try? object.read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            let existing = byBundle[bundleID]
            byBundle[bundleID] = AudioApp(bundleID: bundleID, name: name, isPlaying: playing || (existing?.isPlaying ?? false))
        }
        return byBundle.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension AudioProcessCatalog {
    /// Whether any process other than VibeMeeting is sending audio to an output.
    /// (Voice processing on our own mic engine runs an output too, so it's excluded.)
    static func anyOtherProcessPlaying() -> Bool {
        let own = AudioObjectID.process(for: ProcessInfo.processInfo.processIdentifier)
        let objects = (try? AudioObjectID.systemObject.readObjectList(kAudioHardwarePropertyProcessObjectList)) ?? []
        return objects.contains { object in
            object != own && ((try? object.read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
        }
    }
}
