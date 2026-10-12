import Foundation

/// Second line of defense against speaker bleed: when the other side's voice
/// leaks from the speakers into the mic, the "You" recognizer hears the same
/// words the "Them" recognizer just heard. Voice processing on the mic removes
/// most of it; this catches what slips through.
///
/// Bleed is a near-verbatim copy, while a real answer often reuses a phrase
/// ("Can you do it in two weeks?" → "I can do it in two weeks"). So the bar is
/// high: most word triples of the candidate must appear in the reference.
public enum EchoFilter {
    /// Share of the candidate's word triples that must appear in the reference.
    public static let threshold = 0.75

    public static func isLikelyEcho(_ candidate: String, reference: String) -> Bool {
        let words = normalizedWords(candidate)
        guard words.count >= 3 else { return false }
        let referenceWords = normalizedWords(reference)
        guard referenceWords.count >= words.count else { return false }

        let candidateTriples = ngrams(words, 3)
        let referenceTriples = Set(ngrams(referenceWords, 3))
        let hits = candidateTriples.filter(referenceTriples.contains).count
        return Double(hits) / Double(candidateTriples.count) >= threshold
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    private static func ngrams(_ words: [String], _ n: Int) -> [String] {
        guard words.count >= n else { return [] }
        return (0...(words.count - n)).map { words[$0..<($0 + n)].joined(separator: " ") }
    }
}
