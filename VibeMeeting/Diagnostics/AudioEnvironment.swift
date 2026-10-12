import AVFoundation
import CoreAudio
import Foundation
import Speech

/// System audio capture permission ("System Audio Recording Only" in Privacy & Security).
///
/// macOS has no public API to check or request it, and a tap without permission
/// silently delivers zeros. Like other capture tools, this asks the private TCC
/// framework; it's fine for a personal tool outside the App Store.
enum SystemAudioPermission {
    enum Status: String {
        case authorized = "authorized"
        case denied = "denied"
        case unknown = "not determined"
    }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: PreflightFunction.self)
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet.
    static func request() async -> Bool {
        let current = status
        guard current == .unknown else { return current == .authorized }
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return false }
        let request = unsafeBitCast(symbol, to: RequestFunction.self)
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

/// A plain-text snapshot of the audio setup for the diagnostics report.
enum AudioEnvironment {
    static func deviceName(_ device: AudioObjectID) -> String {
        guard device.isValid else { return "none" }
        let name = (try? device.readString(kAudioObjectPropertyName)) ?? "?"
        let uid = (try? device.readString(kAudioDevicePropertyDeviceUID)) ?? "?"
        return "\(name) [\(uid)]"
    }

    static func report() async -> [String] {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        lines.append("VibeMeeting \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("system audio permission: \(SystemAudioPermission.status.rawValue)")
        let mic: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted: mic = "granted"
        case .denied: mic = "denied"
        case .undetermined: mic = "not determined"
        @unknown default: mic = "unknown"
        }
        lines.append("microphone permission: \(mic)")

        let output = (try? AudioObjectID.systemObject.read(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown)) ?? .unknown
        let systemOutput = (try? AudioObjectID.defaultSystemOutputDevice()) ?? .unknown
        let input = (try? AudioObjectID.systemObject.read(kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID.unknown)) ?? .unknown
        lines.append("default output: \(deviceName(output))")
        lines.append("sound effects output: \(deviceName(systemOutput))")
        lines.append("default input: \(deviceName(input))")

        lines.append("speech transcriber available: \(SpeechTranscriber.isAvailable)")
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier }.sorted()
        lines.append("speech installed locales: \(installed.isEmpty ? "none" : installed.joined(separator: ", "))")
        let reserved = await AssetInventory.reservedLocales.map { $0.identifier }.sorted()
        lines.append("speech reserved locales: \(reserved.isEmpty ? "none" : reserved.joined(separator: ", "))")
        return lines
    }
}
