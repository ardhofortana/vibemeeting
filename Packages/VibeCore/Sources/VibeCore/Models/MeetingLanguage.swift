import Foundation

/// The languages of one meeting. One language is spoken in the call and heard
/// on both streams (Them and You). Replies, Ask questions and the recap are
/// written in that language too, unless the user picked another for them.
///
/// Identifiers are BCP 47 ("en-US", "de-DE"). Speech recognition supports
/// fewer languages than Claude writes, so the call language comes from the
/// recognizer's list and the written languages from a longer one.
public struct MeetingLanguage: Codable, Hashable, Sendable {
    /// What's spoken in the call. Speech recognition uses it for both streams.
    public var callLocale: String
    /// What reply scripts and Ask questions are written in; nil follows the call.
    public var scriptLanguage: String?
    /// What the recap is written in; nil follows the call.
    public var recapLanguage: String?

    public init(callLocale: String = MeetingLanguage.fallbackCallLocale, scriptLanguage: String? = nil, recapLanguage: String? = nil) {
        self.callLocale = callLocale
        self.scriptLanguage = scriptLanguage
        self.recapLanguage = recapLanguage
    }

    /// The call language of meetings saved before languages existed, and the
    /// default when speech recognition supports none of the user's languages.
    public static let fallbackCallLocale = "en-US"

    /// English (United States) for everything, as before meetings had a language.
    public static let english = MeetingLanguage()

    /// The language replies and Ask questions are written in.
    public var script: String { scriptLanguage ?? callLocale }

    /// The language the recap is written in.
    public var recap: String { recapLanguage ?? callLocale }

    /// Whether the call is in English. Some transcript rules are tuned on English speech.
    public var isEnglishCall: Bool { Self.isEnglish(callLocale) }

    // Meetings saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callLocale = try container.decodeIfPresent(String.self, forKey: .callLocale) ?? Self.fallbackCallLocale
        scriptLanguage = try container.decodeIfPresent(String.self, forKey: .scriptLanguage)
        recapLanguage = try container.decodeIfPresent(String.self, forKey: .recapLanguage)
    }

    // MARK: - Identifiers

    /// The BCP 47 form of an identifier ("en_US" → "en-US").
    public static func normalized(_ identifier: String) -> String {
        Locale(identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines)).identifier(.bcp47)
    }

    /// The language part of an identifier ("pt-BR" → "pt").
    public static func languageCode(of identifier: String) -> String? {
        Locale(identifier: identifier).language.languageCode?.identifier.lowercased()
    }

    public static func isEnglish(_ identifier: String) -> Bool {
        languageCode(of: identifier) == "en"
    }

    /// The language's name in English, for prompts: "German (Germany)". The
    /// identifier itself when the name isn't known.
    public static func englishName(of identifier: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Written in a script other than Latin or Cyrillic (Chinese, Japanese,
    /// Korean, Thai, Arabic, Hebrew…). Sentence splitting, word counts and the
    /// echo filter are tuned for languages written left to right with spaces
    /// between words, so these work as a preview for now.
    public static func isPreview(_ identifier: String) -> Bool {
        let language = Locale.Language(identifier: identifier)
        guard let script = Locale.Language(identifier: language.maximalIdentifier).script?.identifier ?? language.script?.identifier else {
            return false
        }
        return !["Latn", "Cyrl"].contains(script)
    }

    // MARK: - Defaults

    /// The call language for a new user: the first of their preferred languages
    /// that speech recognition supports, matched exactly, then by region, then
    /// by the language's usual form ("en" → "en-US"). English (United States)
    /// when none is supported.
    public static func defaultCallLocale(preferredLanguages: [String], supported: [String]) -> String {
        let supported = supported.map(normalized)
        for preferred in preferredLanguages.map(normalized) {
            if let exact = supported.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) {
                return exact
            }
            guard let language = languageCode(of: preferred) else { continue }
            let sameLanguage = supported.filter { languageCode(of: $0) == language }
            guard !sameLanguage.isEmpty else { continue }
            let regions = [
                Locale(identifier: preferred).region?.identifier,
                Locale.Language(identifier: language).maximalIdentifier.split(separator: "-").last.map(String.init),
            ].compactMap { $0 }
            for region in regions {
                if let match = sameLanguage.first(where: { Locale(identifier: $0).region?.identifier == region }) {
                    return match
                }
            }
            return sameLanguage.sorted()[0]
        }
        return fallbackCallLocale
    }

    /// Languages offered for replies and recaps besides the call's own. Claude
    /// writes many more languages than speech recognition hears.
    public static let writingLanguages = [
        "ar", "cs", "da", "de-DE", "el", "en-GB", "en-US", "es-ES", "es-MX", "fi", "fil", "fr-FR", "fr-CA",
        "he", "hi", "hu", "id", "it-IT", "ja-JP", "ko-KR", "ms", "nb", "nl-NL", "pl", "pt-BR", "pt-PT",
        "ro", "ru", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ]
}
