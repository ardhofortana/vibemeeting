import Foundation

/// This build's identity, set per configuration in project.yml. Release and
/// development builds have different bundle IDs, so each keeps its own
/// settings, Keychain item, privacy permissions and meetings.
enum AppIdentity {
    /// "com.djavaweb.vibemeeting", or "com.djavaweb.vibemeeting.debug" for a development build.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.djavaweb.vibemeeting"

    /// "VibeMeeting", or "VibeMeeting Dev": the name System Settings lists the app under.
    static let displayName: String = {
        let name = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? ""
        return name.isEmpty ? "VibeMeeting" : name
    }()

    /// The folder in Application Support for meetings and diagnostics. Release
    /// builds use "VibeMeeting", where earlier versions saved meetings.
    static let dataFolderName: String = {
        let name = (Bundle.main.infoDictionary?["VibeMeetingDataFolder"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.contains("/") ? "VibeMeeting" : name
    }()

    /// `~/Library/Application Support/<dataFolderName>`.
    static var dataDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(dataFolderName, isDirectory: true)
    }
}
