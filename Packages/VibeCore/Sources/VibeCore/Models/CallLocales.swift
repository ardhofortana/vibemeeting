import Foundation

/// The call languages speech recognition offers on this Mac (BCP 47). Two
/// on-device models hear them: the speech model (SpeechTranscriber), the more
/// accurate one, for every language it supports, and the Dictation model
/// (DictationTranscriber) for the languages only it supports, such as
/// Indonesian and Malay.
public struct CallLocales: Equatable, Sendable {
    /// Every call language once: the speech model's, then the Dictation-only ones.
    public let all: [String]
    /// The call languages the speech model transcribes.
    public let speech: [String]
    /// The call languages the Dictation model transcribes.
    public let dictationOnly: Set<String>
    /// Dictation locales whose speech model "equivalent" doesn't count: one it
    /// doesn't list itself, or in another language. They stay with Dictation;
    /// kept for the diagnostics report.
    public let ignoredEquivalents: [String: String]

    /// `speechEquivalents` maps Dictation locales to what the speech model's
    /// supportedLocale(equivalentTo:) answered for them. A Dictation locale is
    /// left out, so no language is listed twice, only when that answer is in
    /// `speech` and in the same language. The answer alone proves nothing: on
    /// macOS 26.6.2 the speech model answered for Indonesian and every other
    /// language only Dictation lists.
    public init(speech: [String], dictation: [String], speechEquivalents: [String: String] = [:]) {
        var all: [String] = []
        var seen: Set<String> = []
        for identifier in speech.map(MeetingLanguage.normalized) where seen.insert(identifier).inserted {
            all.append(identifier)
        }
        self.speech = all
        var covered: Set<String> = []
        var ignored: [String: String] = [:]
        for (dictationLocale, speechLocale) in speechEquivalents {
            let dictationLocale = MeetingLanguage.normalized(dictationLocale)
            let speechLocale = MeetingLanguage.normalized(speechLocale)
            if MeetingLanguage.isSameLanguage(dictationLocale, speechLocale),
               MeetingLanguage.entry(for: speechLocale, in: all) != nil {
                covered.insert(dictationLocale)
            } else {
                ignored[dictationLocale] = speechLocale
            }
        }
        var dictationOnly: Set<String> = []
        for identifier in dictation.map(MeetingLanguage.normalized)
        where !covered.contains(identifier) && seen.insert(identifier).inserted {
            all.append(identifier)
            dictationOnly.insert(identifier)
        }
        self.all = all
        self.dictationOnly = dictationOnly
        self.ignoredEquivalents = ignored
    }

    /// The call languages whose model is on this Mac. Each counts only with the
    /// model that transcribes it: `speech` and `dictation` are the locales each
    /// model has installed.
    public func installed(speech: [String], dictation: [String]) -> Set<String> {
        let speech = Set(speech.map(MeetingLanguage.normalized)).subtracting(dictationOnly)
        let dictation = Set(dictation.map(MeetingLanguage.normalized)).intersection(dictationOnly)
        return speech.union(dictation)
    }
}
