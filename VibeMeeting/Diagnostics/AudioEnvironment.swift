import AVFoundation
import CoreAudio
import Foundation
import Security
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

/// How this build is signed. macOS ties privacy permissions to the signature:
/// an ad-hoc build ("Sign to Run Locally", no Team) gets a new identity on every
/// rebuild, so System Settings can show the toggle on while this exact build
/// only receives silence from system audio.
enum CodeSigning {
    static let teamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    static var isAdHoc: Bool { teamIdentifier == nil }

    static var summary: String {
        teamIdentifier.map { "team \($0)" } ?? "ad-hoc (Sign to Run Locally): permissions reset on every rebuild"
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

    /// The report, or a note if the speech service takes too long to answer.
    static func boundedReport() async -> [String] {
        await firstResult(within: 3) { await AudioEnvironment.report() } ?? ["(system details timed out)"]
    }

    static func report() async -> [String] {
        var lines: [String] = []
        lines.append("VibeMeeting \(AppVersion.display)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("code signing: \(CodeSigning.summary)")
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
        let supported = await SpeechTranscriber.supportedLocales
        let hasIndonesian = supported.contains { $0.language.languageCode?.identifier == "id" }
        lines.append("speech supported locales: \(supported.count) (Indonesian: \(hasIndonesian ? "yes" : "no"))")
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier }.sorted()
        lines.append("speech installed locales: \(installed.isEmpty ? "none" : installed.joined(separator: ", "))")
        let reserved = await AssetInventory.reservedLocales.map { $0.identifier }.sorted()
        lines.append("speech reserved locales: \(reserved.isEmpty ? "none" : reserved.joined(separator: ", "))")
        return lines
    }
}
