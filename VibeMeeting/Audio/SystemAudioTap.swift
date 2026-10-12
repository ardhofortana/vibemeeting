import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Captures what the other side says by tapping system audio output with a
/// Core Audio process tap (macOS 14.2+). Nothing joins the call, and the audio
/// is never written anywhere: buffers go straight to the transcriber.
final class SystemAudioTap: @unchecked Sendable {
    enum Source: Equatable {
        /// Everything the Mac plays, except VibeMeeting itself.
        case allSystemAudio
        /// Only the processes belonging to one app (e.g. "us.zoom.xos").
        case app(bundleID: String)
    }

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private let queue = DispatchQueue(label: "VibeMeeting.SystemAudioTap", qos: .userInteractive)
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var source: Source = .allSystemAudio
    private var handler: BufferHandler?

    /// Called on the main queue when the default output device changes and
    /// the tap was rebuilt (or failed to rebuild).
    var onReconnect: ((Result<Void, Error>) -> Void)?

    /// True when an app source was requested but none of its processes were found.
    private(set) var fellBackToAllAudio = false

    func start(source: Source, handler: @escaping BufferHandler) throws {
        self.source = source
        self.handler = handler
        try startTap()
        listenForDeviceChanges()
    }

    func stop() {
        stopListeningForDeviceChanges()
        stopTap()
        handler = nil
    }

    // MARK: - Tap lifecycle

    private func startTap() throws {
        let description = makeTapDescription()
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "VibeMeeting"

        var newTap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &newTap), "Creating process tap")
        tapID = newTap

        do {
            let outputDevice = try AudioObjectID.defaultSystemOutputDevice()
            let outputUID = try outputDevice.readString(kAudioDevicePropertyDeviceUID)

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "VibeMeeting Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]

            var streamDescription = try tapID.read(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CoreAudioError(status: -1, operation: "Reading tap format")
            }
            format = tapFormat

            var newAggregate = AudioObjectID.unknown
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate), "Creating aggregate device")
            aggregateID = newAggregate

            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
                guard let self, let format = self.format,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
                else { return }
                // The buffer only lives for this callback; the handler must copy what it keeps.
                self.handler?(buffer)
            }, "Creating IO proc")

            try check(AudioDeviceStart(aggregateID, procID), "Starting aggregate device")
            Log.audio.info("System audio tap started")
        } catch {
            stopTap()
            throw error
        }
    }

    private func stopTap() {
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
        format = nil
    }

    private func makeTapDescription() -> CATapDescription {
        fellBackToAllAudio = false
        if case .app(let bundleID) = source {
            let processes = AudioProcessCatalog.processObjects(matching: bundleID)
            if !processes.isEmpty {
                return CATapDescription(stereoMixdownOfProcesses: processes)
            }
            fellBackToAllAudio = true
            Log.audio.notice("No audio processes for the chosen app; tapping all system audio")
        }
        let own = AudioObjectID.process(for: ProcessInfo.processInfo.processIdentifier).map { [$0] } ?? []
        return CATapDescription(stereoGlobalTapButExcludeProcesses: own)
    }

    // MARK: - Device changes

    private func listenForDeviceChanges() {
        var address = AudioObjectID.systemObject.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuild()
        }
        if AudioObjectAddPropertyListenerBlock(.systemObject, &address, queue, listener) == noErr {
            deviceListener = listener
        }
    }

    private func stopListeningForDeviceChanges() {
        guard let deviceListener else { return }
        var address = AudioObjectID.systemObject.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectRemovePropertyListenerBlock(.systemObject, &address, queue, deviceListener)
        self.deviceListener = nil
    }

    /// Runs on `queue` after the output device changed (headphones plugged in, AirPods connected…).
    private func rebuild() {
        guard handler != nil else { return }
        Log.audio.info("Output device changed; rebuilding tap")
        stopTap()
        let result: Result<Void, Error>
        do {
            try startTap()
            result = .success(())
        } catch {
            Log.audio.error("Rebuilding tap failed: \(error.localizedDescription, privacy: .public)")
            result = .failure(error)
        }
        DispatchQueue.main.async { [weak self] in self?.onReconnect?(result) }
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
