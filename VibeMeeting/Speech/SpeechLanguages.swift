import Foundation
import Observation
import Speech
import VibeCore

/// The call languages speech recognition offers on this Mac, which of their
/// models are installed, and model downloads in progress.
@MainActor
@Observable
final class SpeechLanguages {
    /// BCP 47 identifiers speech recognition supports, sorted by display name.
    private(set) var supported: [String] = []
    /// Locales whose speech model is on this Mac.
    private(set) var installed: Set<String> = []
    /// Download progress (0 to 1) by locale, while a download runs.
    private(set) var downloads: [String: Double] = [:]
    /// Why the last download of a locale failed.
    private(set) var downloadErrors: [String: String] = [:]
    /// The first of the user's preferred languages that speech recognition
    /// supports, else English (United States). Known once `refresh()` ran.
    private(set) var automaticCallLocale = MeetingLanguage.fallbackCallLocale

    /// Reads both lists from the speech service. Quick, so windows call it when they open.
    func refresh() async {
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let installedLocales = await SpeechTranscriber.installedLocales
        let identifiers = Set(supportedLocales.map { $0.identifier(.bcp47) })
        supported = identifiers.sorted { MeetingLanguage.displayName(of: $0).localizedStandardCompare(MeetingLanguage.displayName(of: $1)) == .orderedAscending }
        installed = Set(installedLocales.map { $0.identifier(.bcp47) })
        automaticCallLocale = MeetingLanguage.defaultCallLocale(preferredLanguages: Locale.preferredLanguages, supported: supported)
    }

    func isInstalled(_ identifier: String) -> Bool {
        installed.contains(identifier)
    }

    /// Downloads the speech model for a call language, with progress in `downloads`.
    func download(_ identifier: String) async {
        guard downloads[identifier] == nil else { return }
        downloads[identifier] = 0
        downloadErrors[identifier] = nil
        do {
            try await LiveTranscriber.prepareAssets(for: Locale(identifier: identifier)) { [weak self] fraction in
                // A late report must not bring back a finished download.
                guard self?.downloads[identifier] != nil else { return }
                self?.downloads[identifier] = fraction
            }
            installed.insert(identifier)
        } catch {
            downloadErrors[identifier] = LiveTranscriber.describe(error)
        }
        downloads[identifier] = nil
    }

    /// The options for a call language picker: the supported locales, plus the
    /// current choice if speech recognition no longer lists it.
    func callLocaleOptions(including current: String) -> [String] {
        supported.contains(current) ? supported : [current] + supported
    }
}

/// Language names for the app's pickers and messages.
extension MeetingLanguage {
    /// Names follow the app's own language (English until it's translated),
    /// not the system's, so they match the words around them.
    private static let displayLocale = Locale(identifier: Bundle.main.preferredLocalizations.first { $0 != "Base" } ?? "en")

    /// "German (Germany)", in the app's language.
    static func displayName(of identifier: String) -> String {
        displayLocale.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// The name, marked "preview" for languages the transcript tools aren't tuned for yet.
    static func pickerName(of identifier: String) -> String {
        isPreview(identifier) ? "\(displayName(of: identifier)) (preview)" : displayName(of: identifier)
    }

    /// Languages offered for replies and recaps, sorted by name.
    static let sortedWritingLanguages: [String] = writingLanguages.sorted {
        displayName(of: $0).localizedStandardCompare(displayName(of: $1)) == .orderedAscending
    }

    /// Shown wherever a preview language can be picked.
    static let previewNote = "Languages not written in the Latin or Cyrillic alphabet (such as Chinese, Japanese, Korean, Thai, Arabic and Hebrew) are a preview for now: sentence splitting, word counts and the echo filter are tuned for the others."
}
