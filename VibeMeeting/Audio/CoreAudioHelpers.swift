import AudioToolbox
import CoreAudio
import Foundation

struct CoreAudioError: Error, LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? { "\(operation) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
}

extension AudioObjectID {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        try check(status, "Reading property \(selector)")
        return value
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        try check(status, "Reading string property \(selector)")
        return value as String
    }

    func readObjectList(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "Sizing list \(selector)")
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var list = [AudioObjectID](repeating: .unknown, count: count)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &list), "Reading list \(selector)")
        return list
    }

    /// The Core Audio process object for a PID, if that process has one.
    static func process(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(.systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object.isValid ? object : nil
    }

    static func defaultSystemOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.systemObject.read(kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID.unknown)
    }
}
