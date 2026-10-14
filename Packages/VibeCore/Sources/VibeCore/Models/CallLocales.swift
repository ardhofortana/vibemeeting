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

    /// `speechEquivalents` are Dictation locales the speech model accepts under
    /// another identifier; they're left out so no language is listed twice.
    public init(speech: [String], dictation: [String], speechEquivalents: Set<String> = []) {
        var all: [String] = []
        var seen: Set<String> = []
        for identifier in speech.map(MeetingLanguage.normalized) where seen.insert(identifier).inserted {
            all.append(identifier)
        }
        self.speech = all
        let equivalents = Set(speechEquivalents.map(MeetingLanguage.normalized))
        var dictationOnly: Set<String> = []
        for identifier in dictation.map(MeetingLanguage.normalized)
        where !equivalents.contains(identifier) && seen.insert(identifier).inserted {
            all.append(identifier)
            dictationOnly.insert(identifier)
        }
        self.all = all
        self.dictationOnly = dictationOnly
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
