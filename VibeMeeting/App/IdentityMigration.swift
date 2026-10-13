import Foundation

/// A one-time move from the bundle ID every build used before the Djavaweb
/// identity. macOS keeps settings, Keychain items and privacy permissions per
/// bundle ID, so a new identity starts empty. Release and development builds
/// each run it once. The earlier app's settings and key stay where they are,
/// so rolling back to an earlier version still finds them.
enum IdentityMigration {
    static let legacyBundleID = "com.ardhofortana.VibeMeeting"
    private static let doneKey = "migratedFromLegacyIdentity"

    /// Copies `keys` from the earlier identity's settings, once, and only while
    /// this identity has none of `ownKeys`, so nothing chosen here is overwritten.
    /// Returns whether the earlier app's settings were found and copied. Call it
    /// before anything reads these settings.
    static func copySettings(_ keys: [String], unlessSet ownKeys: [String], defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        defaults.set(true, forKey: doneKey)
        guard !ownKeys.contains(where: { defaults.object(forKey: $0) != nil }),
              let legacy = defaults.persistentDomain(forName: legacyBundleID), !legacy.isEmpty
        else { return false }
        var copied = 0
        for key in keys {
            guard let value = legacy[key] else { continue }
            defaults.set(value, forKey: key)
            copied += 1
        }
        Log.app.info("Copied \(copied, privacy: .public) settings from the earlier app identity")
        return true
    }

    /// Copies the Claude API key from the earlier identity's Keychain item, off
    /// the main thread, because macOS may ask the user to allow it. If they
    /// don't, or anything fails, they enter the key again in Settings. A key
    /// already saved here is never replaced.
    static func copyAPIKey(into settings: AppSettings) {
        let account = KeychainStore.apiKeyAccount
        let legacyService = legacyBundleID
        Task.detached(priority: .utility) {
            guard let key = KeychainStore.read(account: account, service: legacyService), !key.isEmpty,
                  KeychainStore.read(account: account) == nil
            else { return }
            do {
                try KeychainStore.save(key, account: account)
                await settings.refreshAPIKeyState()
                Log.app.info("Copied the API key from the earlier app identity")
            } catch {
                Log.app.error("Copying the API key failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
