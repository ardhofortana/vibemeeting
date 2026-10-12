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
        /// Other apps play, this capture has never received a non-zero sample (even
        /// after a rebuild), and the permission looks wrong: the tap probe was refused,
        /// the build is ad-hoc ("Sign to Run Locally", whose grant belongs to an older
        /// binary), or the preflight isn't "authorized".
        case silentWhileOthersPlay
        /// The same silence, but the permission looks fine. Could be a lobby or a
        /// muted call, so it's reported softly.
        case nothingHeardYet
        /// Buffers keep arriving in a layout that doesn't match the tap stream.
        case unreadableBuffers
        /// The aggregate device stopped calling the IO block while other apps play.
        case noAudioIO
        /// IO stayed broken after the allowed reconnects.
        case recoveryFailed
        /// The device or format kept changing, so rebuilding was paused.
        case deviceKeepsChanging

        /// About the capture device rather than about what macOS lets the app hear.
        var isDeviceProblem: Bool {
            switch self {
            case .silentWhileOthersPlay, .nothingHeardYet: return false
            case .unreadableBuffers, .noAudioIO, .recoveryFailed, .deviceKeepsChanging: return true
            }
        }
    }

    /// The buffer and the host time (mach ticks) of its first sample.
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

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
    /// True once any tap in this capture delivered a non-zero sample. The System
    /// Audio Recording grant is all or nothing for the process, so silence after
    /// that is a quiet or muted call (WebRTC renders exact zeros then), not a
    /// permission problem. Survives rebuilds; reset on start.
    private var heardSignal = false
    /// Uptime of the last non-zero sample across rebuilds (nil = never).
    private var lastSignalUptime: TimeInterval?
    /// Whether this tap's permission probe was refused (nil = couldn't tell).
    private var tapDenied: Bool?
    /// The fallback state last reported, so only changes are sent.
    private var reportedFallback = false
    /// Tap-only first. If that aggregate never runs IO on this Mac while audio
    /// plays, fall back once to an output device as the aggregate's clock. Only a
    /// device with no input streams qualifies: a device with a mic would put its
    /// mic stream in the IO buffer list next to the tap's, in the same shape.
    private var composition: Composition = .tapOnly
    private var publishedUnreadable = 0
    /// Start times of recent rebuilds, to stop a flapping device from rebuilding forever.
    private var rebuildTimes: [TimeInterval] = []

    private enum Composition: Equatable {
        case tapOnly
        case withClock(uid: String, name: String)

        var label: String {
            switch self {
            case .tapOnly: return "tap only"
            case .withClock(_, let name): return "tap + \(name) as clock"
            }
        }
    }

    /// Called on the main queue when a rebuild fails (`willRetry`: another attempt
    /// is scheduled) and when a rebuild succeeds after failing. Routine rebuilds
    /// (device changes, recovery) aren't reported: a rebuilt tap isn't proof that
    /// audio is back.
    var onReconnect: ((_ result: Result<Void, Error>, _ willRetry: Bool) -> Void)?
    /// Called on the main queue when capture is running but unusable.
    var onProblem: ((Problem) -> Void)?
    /// Called on the main queue when a reported problem is over (sound or IO is back).
    var onProblemCleared: ((Problem) -> Void)?
    /// Called on the main queue when an app source switches between its own
    /// processes and all system audio after start.
    var onFallbackChange: ((_ fellBackToAllAudio: Bool) -> Void)?

    /// True when an app source was requested but none of its processes were found.
    private(set) var fellBackToAllAudio = false

    init(diagnostics: StreamDiagnostics? = nil) {
        self.diagnostics = diagnostics
    }

    /// Starts capture. Runs on the control queue and suspends the caller instead of
    /// blocking a thread: while the System Audio Recording prompt is unanswered,
    /// creating the aggregate device can block for a long time.
    func start(source: Source, handler: @escaping BufferHandler) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                do {
                    try self.startOnControlQueue(source: source, handler: handler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops capture and destroys the tap and aggregate device.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                self.stopOnControlQueue()
                continuation.resume()
            }
        }
    }

    private func startOnControlQueue(source: Source, handler: @escaping BufferHandler) throws {
        // Idempotent: a second start replaces the first instead of leaking it.
        if self.handler != nil { stopOnControlQueue() }
        self.source = source
        self.handler = handler
        failedRebuilds = 0
        recoveryRebuilds = 0
        silentRebuilds = 0
        reportedProblem = nil
        heardSignal = false
        lastSignalUptime = nil
        rebuildTimes = []
        composition = .tapOnly
        diagnostics?.update {
            $0.problem = nil
            $0.chosenAppIdle = false
        }
        do {
            try startTap()
        } catch {
            self.handler = nil
            throw error
        }
        reportedFallback = fellBackToAllAudio
        startWatchdog()
    }

    private func stopOnControlQueue() {
        handler = nil
        pendingRebuild?.cancel()
        pendingRebuild = nil
        watchdog?.cancel()
        watchdog = nil
        stopTap()
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
            var composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "VibeMeeting Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                // IO runs even while nothing plays, so a missing heartbeat means a dead
                // tap, not a quiet call.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            // Tap only (default): no sub-device, so the IO buffer list holds the tap
            // stream and nothing else. The fallback clock never has input streams.
            if case .withClock(let clockUID, _) = self.composition {
                composition[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
                composition[kAudioAggregateDeviceIsStackedKey] = false
                composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockUID]]
            }

            var newAggregate = AudioObjectID.unknown
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregate), "Creating aggregate device")
            aggregateID = newAggregate

            let stream = try TapStream(tapID: tapID, aggregateID: aggregateID)
            self.stream = stream
            publishedUnreadable = 0

            // The IO block only copies and hands on; the handler must not do heavy work
            // here (CapturePipeline moves conversion to its own queue).
            let handler = self.handler
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inputData, inputTime, _, _ in
                // Copies the tap's samples out; the IO buffer list dies with this cycle.
                // Unreadable cycles are counted inside TapStream (no lock traffic here).
                guard let buffer = stream.read(inputData) else { return }
                let time = inputTime.pointee
                handler?(buffer, time.mFlags.contains(.hostTimeValid) ? time.mHostTime : mach_absolute_time())
            }, "Creating IO proc")

            // Chromium's order: probe after creating the IO proc, before starting.
            tapDenied = probeTapPermissionDenied()
            let probe = tapDenied.map { $0 ? "refused" : "ok" } ?? "unknown"
            let detail = "\(stream.summary); aggregate: \(self.composition.label); "
                + "source: \(sourceLabel); "
                + "permission preflight: \(SystemAudioPermission.status.rawValue); tap probe: \(probe)"
            diagnostics?.update {
                $0.deviceDetail = detail
                $0.captureState = "Starting"
            }

            try check(AudioDeviceStart(aggregateID, procID), "Starting aggregate device")
            installListeners()
            diagnostics?.update { $0.captureState = "Running" }
            Log.audio.info("System audio tap started: \(detail, privacy: .public)")
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

    private var sourceLabel: String {
        guard case .app(let bundleID) = source else { return "all system audio" }
        return fellBackToAllAudio ? "all system audio (\(bundleID) had no audio process)" : "only \(bundleID)"
    }

    /// Chromium's permission probe (ProbeAudioTapPermissions): writing the tap's own
    /// description back fails (kAudioDevicePermissionsError) when System Audio
    /// Recording isn't allowed for this process. nil when it can't tell.
    private func probeTapPermissionDenied() -> Bool? {
        var address = tapID.address(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        var value: Unmanaged<CATapDescription>?
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &value) == noErr,
              var description = value
        else { return nil }
        // Core Audio hands out object properties retained.
        defer { description.release() }
        let status = AudioObjectSetPropertyData(tapID, &address, 0, nil, size, &description)
        if status != noErr {
            Log.audio.error("Tap permission probe refused: \(status)")
        }
        return status != noErr
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
        let now = ProcessInfo.processInfo.systemUptime
        rebuildTimes = rebuildTimes.filter { now - $0 < 60 } + [now]
        if rebuildTimes.count > 6 {
            // Something keeps changing (a flapping device or format). Stop rebuilding
            // and say so rather than tearing down the tap forever.
            Log.audio.error("Too many tap rebuilds; pausing: \(reason, privacy: .public)")
            report(.deviceKeepsChanging)
            return
        }
        Log.audio.info("Rebuilding system audio tap: \(reason, privacy: .public)")
        diagnostics?.update {
            $0.rebuilds += 1
            $0.lastRebuildReason = reason
        }
        // checkHealth skips while a rebuild is pending; keep what the old tap heard.
        if let stream { absorb(stream.health()) }
        stopTap()
        do {
            try startTap()
            let recovered = failedRebuilds > 0
            failedRebuilds = 0
            if recovered {
                // The failure notice goes away with this; a problem that persists
                // must be reported (and shown) again.
                reportedProblem = nil
                diagnostics?.update { $0.problem = nil }
                DispatchQueue.main.async { [weak self] in self?.onReconnect?(.success(()), false) }
            }
            let fellBack = fellBackToAllAudio
            if fellBack != reportedFallback {
                reportedFallback = fellBack
                DispatchQueue.main.async { [weak self] in self?.onFallbackChange?(fellBack) }
            }
        } catch {
            Log.audio.error("Rebuilding tap failed: \(error.localizedDescription, privacy: .public)")
            diagnostics?.update {
                $0.captureState = "Failed"
                $0.lastError = error.localizedDescription
            }
            failedRebuilds += 1
            let willRetry = failedRebuilds <= 4
            if willRetry {
                scheduleRebuild(reason, after: Double(1 << (failedRebuilds - 1)))
            }
            DispatchQueue.main.async { [weak self] in self?.onReconnect?(.failure(error), willRetry) }
        }
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
        absorb(health)
        publish(health, of: stream)
        guard health.age > 3 else { return }

        // No IO cycle at all while a tapped process plays means this aggregate layout
        // doesn't run on this Mac: try an output device as the clock, once. (Judged
        // only while something plays, so a quiet start never switches layouts.)
        if health.cycles == 0 {
            guard tappedProcessesPlaying() else { return }
            if composition == .tapOnly, let clock = Self.inputlessOutputDevice() {
                composition = .withClock(uid: clock.uid, name: clock.name)
                Log.audio.error("Tap-only aggregate ran no IO; retrying with \(clock.name, privacy: .public) as clock")
                scheduleRebuild("no IO from the tap-only aggregate")
            } else {
                reportAndRecover(.noAudioIO, "no IO from the aggregate")
            }
            return
        }

        if health.secondsSinceSignal < 1 {
            recoveryRebuilds = 0
            silentRebuilds = 0
            clearProblem()
            publishChosenAppIdle(false)
            return
        }

        if health.consecutiveUnreadable >= 100 {
            reportAndRecover(.unreadableBuffers, "IO buffers don't match the tap stream")
            return
        }
        // Readable IO is flowing again, so an earlier IO problem is over (the call
        // may simply be quiet).
        if health.secondsSinceCycle < 2, health.consecutiveUnreadable == 0,
           let problem = reportedProblem, problem == .noAudioIO || problem == .unreadableBuffers || problem == .recoveryFailed {
            clearProblem()
        }

        let playing = tappedProcessesPlaying()
        publishChosenAppIdle(!playing && isAppSource && AudioProcessCatalog.anyOtherProcessPlaying())
        // Only judge silence while a tapped process is actually playing.
        guard playing else { return }
        if health.secondsSinceCycle > 3 {
            reportAndRecover(.noAudioIO, "IO stalled")
        } else if !heardSignal, health.secondsSinceSignal > 15 {
            // Only before anything was heard: "playing" means only that an output
            // runs, and a muted call delivers exact zeros too.
            if silentRebuilds == 0 {
                // A grant given while a tap exists only takes effect on a new tap.
                silentRebuilds = 1
                recover("only digital silence while other apps play")
            } else if health.secondsSinceSignal > 30 {
                let permissionSuspect = tapDenied == true || CodeSigning.isAdHoc
                    || SystemAudioPermission.status != .authorized
                report(permissionSuspect ? .silentWhileOthersPlay : .nothingHeardYet)
            }
        }
    }

    private var isAppSource: Bool {
        if case .app = source, !tappedProcesses.isEmpty { return true }
        return false
    }

    /// Keeps what a tap heard across rebuilds.
    private func absorb(_ health: TapStream.Health) {
        guard health.everSignal else { return }
        heardSignal = true
        lastSignalUptime = ProcessInfo.processInfo.systemUptime - health.secondsSinceSignal
    }

    private func recover(_ reason: String) {
        guard recoveryRebuilds < 3 else { return }
        recoveryRebuilds += 1
        scheduleRebuild(reason)
    }

    /// Reports an IO problem and rebuilds; once the rebuilds are spent, says so once.
    private func reportAndRecover(_ problem: Problem, _ reason: String) {
        guard recoveryRebuilds < 3 else {
            report(.recoveryFailed)
            return
        }
        report(problem)
        recoveryRebuilds += 1
        scheduleRebuild(reason)
    }

    private func report(_ problem: Problem) {
        guard reportedProblem != problem else { return }
        reportedProblem = problem
        diagnostics?.update { $0.problem = "\(problem)" }
        DispatchQueue.main.async { [weak self] in self?.onProblem?(problem) }
    }

    private func clearProblem() {
        guard let problem = reportedProblem else { return }
        reportedProblem = nil
        diagnostics?.update { $0.problem = nil }
        DispatchQueue.main.async { [weak self] in self?.onProblemCleared?(problem) }
    }

    private func publishChosenAppIdle(_ idle: Bool) {
        diagnostics?.update { $0.chosenAppIdle = idle }
    }

    /// An output device with no input streams, to clock the fallback aggregate.
    /// Prefers the default output, then built-in speakers, then any other.
    private static func inputlessOutputDevice() -> (uid: String, name: String)? {
        let system = AudioObjectID.systemObject
        let defaultOutput = (try? system.read(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown)) ?? .unknown
        let devices = (try? system.readObjectList(kAudioHardwarePropertyDevices)) ?? []
        func streams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
            ((try? device.readObjects(kAudioDevicePropertyStreams, scope: scope)) ?? []).count
        }
        let candidates = devices.filter { streams($0, kAudioObjectPropertyScopeOutput) > 0 && streams($0, kAudioObjectPropertyScopeInput) == 0 }
        let builtIn = candidates.first {
            ((try? $0.read(kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0) == kAudioDeviceTransportTypeBuiltIn
        }
        guard let device = candidates.first(where: { $0 == defaultOutput }) ?? builtIn ?? candidates.first,
              let uid = try? device.readString(kAudioDevicePropertyDeviceUID)
        else { return nil }
        let name = (try? device.readString(kAudioObjectPropertyName)) ?? uid
        return (uid, name)
    }

    /// With one app chosen, only that app's processes count; otherwise any process
    /// but VibeMeeting. (Unrelated music must not make a quiet app look broken.)
    private func tappedProcessesPlaying() -> Bool {
        if case .app = source, !tappedProcesses.isEmpty {
            return tappedProcesses.contains { process in
                ((try? process.read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            }
        }
        return AudioProcessCatalog.anyOtherProcessPlaying()
    }

    /// Copies the IO-side counters into the diagnostics (1 Hz, control queue), so
    /// the IO block never takes the diagnostics lock.
    private func publish(_ health: TapStream.Health, of stream: TapStream) {
        let newUnreadable = health.unreadableTotal - publishedUnreadable
        publishedUnreadable = health.unreadableTotal
        let layout = health.badLayout.map { stream.describe($0) }
        diagnostics?.update {
            $0.unreadableBuffers += newUnreadable
            if let layout { $0.unreadableLayout = layout }
            // Across rebuilds; nil = no non-zero sample yet in this capture.
            $0.tracksNonZero = true
            $0.secondsSinceNonZero = lastSignalUptime.map { ProcessInfo.processInfo.systemUptime - $0 }
            if $0.captureState.hasPrefix("Running") {
                $0.captureState = "Running (\(health.cycles) IO cycles since last start)"
            }
        }
    }
}

// MARK: - The tap's stream inside the aggregate device

/// The format the IO cycle delivers and the per-cycle reader. `read` runs on the
/// IO queue only; the counters are shared with the watchdog under a lock.
private final class TapStream: @unchecked Sendable {
    struct Health {
        var age: TimeInterval
        var cycles: Int
        var unreadableTotal: Int
        var consecutiveUnreadable: Int
        var secondsSinceCycle: TimeInterval
        var secondsSinceSignal: TimeInterval
        /// False until the first non-zero sample of this tap.
        var everSignal: Bool
        var badLayout: BufferLayout?
    }

    /// The shape of one IO buffer list. Plain integers: captured on the IO thread
    /// without allocating, formatted later on the control queue.
    struct BufferLayout {
        var buffers: Int
        var firstChannels: UInt32
        var firstBytes: UInt32
        var lastChannels: UInt32
        var lastBytes: UInt32
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
    private var cycles = 0
    private var unreadableTotal = 0
    private var consecutiveUnreadable = 0
    private var badLayout: BufferLayout?
    private var everSignal = false
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

        var layout: BufferLayout?
        if copy == nil {
            let count = list.count
            layout = BufferLayout(
                buffers: count,
                firstChannels: count > 0 ? list[0].mNumberChannels : 0,
                firstBytes: count > 0 ? list[0].mDataByteSize : 0,
                lastChannels: count > 0 ? list[count - 1].mNumberChannels : 0,
                lastBytes: count > 0 ? list[count - 1].mDataByteSize : 0
            )
        }

        lock.withLock {
            cycles += 1
            lastCycleAt = now
            if copy == nil {
                consecutiveUnreadable += 1
                unreadableTotal += 1
                badLayout = layout
            } else {
                consecutiveUnreadable = 0
                // Non-float formats can't be checked cheaply; treat them as live.
                if hasSignal || !isFloat32 {
                    lastSignalAt = now
                    everSignal = true
                }
            }
        }
        return copy
    }

    func health() -> Health {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            Health(
                age: now - startedAt,
                cycles: cycles,
                unreadableTotal: unreadableTotal,
                consecutiveUnreadable: consecutiveUnreadable,
                secondsSinceCycle: now - lastCycleAt,
                secondsSinceSignal: now - lastSignalAt,
                everSignal: everSignal,
                badLayout: badLayout
            )
        }
    }

    /// "3 buffers (first 1ch/2048B, last 1ch/2048B); expected 1 × 1ch, 4 B/frame".
    func describe(_ layout: BufferLayout) -> String {
        "\(layout.buffers) buffers (first \(layout.firstChannels)ch/\(layout.firstBytes)B, "
            + "last \(layout.lastChannels)ch/\(layout.lastBytes)B); "
            + "expected \(buffersPerCycle) × \(channelsPerBuffer)ch, \(bytesPerFrame) B/frame"
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
