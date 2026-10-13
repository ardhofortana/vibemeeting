import Foundation
import Observation
import VibeCore

/// User preferences, persisted in UserDefaults. The API key lives in the Keychain.
@MainActor
@Observable
final class AppSettings {
    enum OverlayCorner: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .topLeft: return "Top left"
            case .topRight: return "Top right"
            case .bottomLeft: return "Bottom left"
            case .bottomRight: return "Bottom right"
            }
        }
    }

    private enum Key {
        static let replyModel = "replyModelID"
        static let recapModel = "recapModelID"
        static let aboutMe = "aboutMe"
        static let customPresets = "customPresets"
        static let defaultPreset = "defaultPresetID"
        static let overlayCorner = "overlayCorner"
        static let overlayOpacity = "overlayOpacity"
        static let hideFromSharing = "hideFromScreenSharing"
        static let compactOverlay = "compactOverlay"
        static let audioSourceBundleID = "audioSourceBundleID"
        static let voiceProcessing = "voiceProcessing"
        static let echoGate = "suppressSpeakerBleed"
        static let callLocale = "callLocale"
        static let onboarded = "hasCompletedOnboarding"
    }

    /// Every key these settings are stored under.
    static let storedKeys = [
        Key.replyModel, Key.recapModel, Key.aboutMe, Key.customPresets, Key.defaultPreset,
        Key.overlayCorner, Key.overlayOpacity, Key.hideFromSharing, Key.compactOverlay,
        Key.audioSourceBundleID, Key.voiceProcessing, Key.echoGate, Key.callLocale, Key.onboarded,
    ]

    /// Copied from the earlier bundle ID on first launch. Not onboarding: macOS
    /// asks for the audio permissions again under a new identity, and Welcome
    /// is where that happens.
    static var keysToMigrate: [String] { storedKeys.filter { $0 != Key.onboarded } }

    /// What the earlier app used where it stored nothing: it saved a setting only
    /// once changed. Hide from screen sharing was on, and every call was English
    /// (United States). A migrated install keeps them; new installs get the defaults below.
    static var earlierDefaults: [String: Any] {
        [Key.hideFromSharing: true, Key.callLocale: MeetingLanguage.fallbackCallLocale]
    }

    private let defaults: UserDefaults

    var replyModelID: String { didSet { defaults.set(replyModelID, forKey: Key.replyModel) } }
    var recapModelID: String { didSet { defaults.set(recapModelID, forKey: Key.recapModel) } }
    var aboutMe: String { didSet { defaults.set(aboutMe, forKey: Key.aboutMe) } }
    var customPresets: [StylePreset] { didSet { saveCustomPresets() } }
    var defaultPresetID: String { didSet { defaults.set(defaultPresetID, forKey: Key.defaultPreset) } }
    var overlayCorner: OverlayCorner { didSet { defaults.set(overlayCorner.rawValue, forKey: Key.overlayCorner) } }
    /// Opacity of the overlay background (text stays fully opaque).
    var overlayOpacity: Double { didSet { defaults.set(overlayOpacity, forKey: Key.overlayOpacity) } }
    /// Off by default; Settings shows a disclaimer before turning it on.
    var hideFromScreenSharing: Bool { didSet { defaults.set(hideFromScreenSharing, forKey: Key.hideFromSharing) } }
    var compactOverlay: Bool { didSet { defaults.set(compactOverlay, forKey: Key.compactOverlay) } }
    /// Bundle ID of the one app to capture, or nil for all system audio.
    var audioSourceBundleID: String? { didSet { defaults.set(audioSourceBundleID, forKey: Key.audioSourceBundleID) } }
    /// Echo cancellation on the mic (Apple voice processing).
    var voiceProcessing: Bool { didSet { defaults.set(voiceProcessing, forKey: Key.voiceProcessing) } }
    /// Mute the mic where it only carries the call's voice from the speakers.
    var suppressSpeakerBleed: Bool { didSet { defaults.set(suppressSpeakerBleed, forKey: Key.echoGate) } }
    /// The call language for new meetings (BCP 47). nil follows the Mac's
    /// preferred languages: see `SpeechLanguages.automaticCallLocale`.
    var callLocaleID: String? { didSet { defaults.set(callLocaleID, forKey: Key.callLocale) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarded) } }

    /// Mirrors whether a key is stored, so views update when it changes.
    private(set) var hasAPIKey: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        replyModelID = defaults.string(forKey: Key.replyModel) ?? ClaudeModel.defaultReplyModelID
        recapModelID = defaults.string(forKey: Key.recapModel) ?? ClaudeModel.defaultRecapModelID
        // Empty until the user writes it; Settings shows an outline as placeholder.
        aboutMe = defaults.string(forKey: Key.aboutMe) ?? ""
        if let data = defaults.data(forKey: Key.customPresets),
           let presets = try? JSONDecoder().decode([StylePreset].self, from: data) {
            customPresets = presets
        } else {
            customPresets = []
        }
        defaultPresetID = defaults.string(forKey: Key.defaultPreset) ?? StylePreset.friendlyProID
        overlayCorner = defaults.string(forKey: Key.overlayCorner).flatMap(OverlayCorner.init(rawValue:)) ?? .topRight
        overlayOpacity = defaults.object(forKey: Key.overlayOpacity) as? Double ?? 0.88
        // Installs from before it was off by default keep theirs (`earlierDefaults`).
        hideFromScreenSharing = defaults.object(forKey: Key.hideFromSharing) as? Bool ?? false
        compactOverlay = defaults.bool(forKey: Key.compactOverlay)
        audioSourceBundleID = defaults.string(forKey: Key.audioSourceBundleID)
        // Off by default: macOS voice processing ducks every other app (the call too)
        // and can lower the call app's own mic input. Turned on, it's skipped only with
        // Bluetooth or USB headphones (the headphone jack may drive speakers).
        voiceProcessing = defaults.object(forKey: Key.voiceProcessing) as? Bool ?? false
        suppressSpeakerBleed = defaults.object(forKey: Key.echoGate) as? Bool ?? true
        callLocaleID = defaults.string(forKey: Key.callLocale)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarded)
        hasAPIKey = !(KeychainStore.read(account: KeychainStore.apiKeyAccount) ?? "").isEmpty
    }

    // MARK: - API key

    var apiKey: String {
        KeychainStore.read(account: KeychainStore.apiKeyAccount) ?? ""
    }

    func setAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: KeychainStore.apiKeyAccount)
        } else {
            try KeychainStore.save(trimmed, account: KeychainStore.apiKeyAccount)
        }
        hasAPIKey = !trimmed.isEmpty
    }

    /// Re-reads whether a key is stored, after one was saved outside `setAPIKey`.
    func refreshAPIKeyState() {
        hasAPIKey = !apiKey.isEmpty
    }

    // MARK: - Presets

    var allPresets: [StylePreset] { StylePreset.builtIns + customPresets }

    func preset(id: String) -> StylePreset {
        allPresets.first { $0.id == id } ?? .friendlyPro
    }

    var defaultPreset: StylePreset { preset(id: defaultPresetID) }

    var replyModel: ClaudeModel { ClaudeModel.resolve(replyModelID) }
    var recapModel: ClaudeModel { ClaudeModel.resolve(recapModelID) }

    private func saveCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            defaults.set(data, forKey: Key.customPresets)
        }
    }
}
