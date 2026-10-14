import Foundation
import Observation
import Speech
import VibeCore

/// The call languages speech recognition offers on this Mac, which of their
/// models are installed, and model downloads in progress. The languages come
/// from two models: SpeechTranscriber, and DictationTranscriber for the ones
/// only Dictation supports (see `LiveTranscriber`).
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
    /// English: the variant in the user's preferred languages when the speech
    /// model supports it, else English (United States). Known once `refresh()` ran.
    private(set) var automaticCallLocale = MeetingLanguage.fallbackCallLocale

    /// Reads the lists from the speech service. Quick, so windows call it when they open.
    func refresh() async {
        let locales = await Self.callLocales()
        let speechInstalled = await SpeechTranscriber.installedLocales
        let dictationInstalled = await DictationTranscriber.installedLocales
        supported = locales.all.sorted { MeetingLanguage.displayName(of: $0).localizedStandardCompare(MeetingLanguage.displayName(of: $1)) == .orderedAscending }
        installed = locales.installed(speech: speechInstalled.map { $0.identifier(.bcp47) }, dictation: dictationInstalled.map { $0.identifier(.bcp47) })
        // Automatic stays on the speech model, the more accurate one: an English
        // only Dictation has (such as en-ID) gives the usual form instead. Without
        // the speech model, Dictation hears every language.
        let automaticCandidates = locales.speech.isEmpty ? locales.all : locales.speech
        automaticCallLocale = MeetingLanguage.defaultCallLocale(preferredLanguages: Locale.preferredLanguages, supported: automaticCandidates)
    }

    /// The supported lists don't change while the app runs, so they're read once.
    private static var cachedCallLocales: CallLocales?

    /// Every call language, and which ones DictationTranscriber hears, by the
    /// rule `LiveTranscriber` picks a model with: SpeechTranscriber for every
    /// locale it accepts, listed or equivalent, and DictationTranscriber for the rest.
    static func callLocales() async -> CallLocales {
        if let cached = cachedCallLocales { return cached }
        let speechAvailable = SpeechTranscriber.isAvailable
        var speech: [Locale] = []
        if speechAvailable {
            speech = await SpeechTranscriber.supportedLocales
        }
        let dictation = await DictationTranscriber.supportedLocales
        let speechIdentifiers = Set(speech.map { $0.identifier(.bcp47) })
        let candidates = speechAvailable ? dictation.filter { !speechIdentifiers.contains($0.identifier(.bcp47)) } : []
        // One question to the speech service per locale, asked side by side.
        let equivalents = await withTaskGroup(of: String?.self, returning: Set<String>.self) { group in
            for locale in candidates {
                group.addTask {
                    let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
                    return equivalent == nil ? nil : locale.identifier(.bcp47)
                }
            }
            var found: Set<String> = []
            for await identifier in group {
                if let identifier { found.insert(identifier) }
            }
            return found
        }
        let locales = CallLocales(
            speech: speech.map { $0.identifier(.bcp47) },
            dictation: dictation.map { $0.identifier(.bcp47) },
            speechEquivalents: equivalents
        )
        // A list may come back empty from a speech service that isn't ready yet,
        // and a refresh cancelled when its window closes skips the equivalence
        // checks: keep only a complete answer, and ask again next time.
        let complete = !Task.isCancelled && !dictation.isEmpty && (!speechAvailable || !speech.isEmpty)
        if complete { cachedCallLocales = locales }
        return locales
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
        isPreview(identifier)
            ? String(localized: "\(displayName(of: identifier)) (preview)", comment: "A language in a picker, marked as a preview.")
            : displayName(of: identifier)
    }

    /// Languages offered for replies and recaps, sorted by name.
    static let sortedWritingLanguages: [String] = writingLanguages.sorted {
        displayName(of: $0).localizedStandardCompare(displayName(of: $1)) == .orderedAscending
    }

    /// Shown wherever a preview language can be picked.
    static var previewNote: String {
        String(localized: "Languages not written in the Latin or Cyrillic alphabet (such as Chinese, Japanese, Korean, Thai, Arabic and Hebrew) are a preview for now: sentence splitting, word counts and the echo filter are tuned for the others.")
    }
}
