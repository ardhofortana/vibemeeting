import Foundation

/// Text-level defense against speaker bleed: when the other side's voice leaks
/// from the speakers into the mic, the "You" recognizer hears the same words the
/// "Them" recognizer just heard. The echo gate on the mic removes most of it
/// (and voice processing, when on); this catches near-verbatim repeats that get
/// through, and only while "Them" is being transcribed.
///
/// Bleed is a near-verbatim copy, while a real answer often reuses a phrase
/// ("Can you do it in two weeks?" → "I can do it in two weeks"). So the bar is
/// high: most word triples of the candidate must appear in the reference. Words
/// may differ by a letter or two, as the second recognizer mishears some
/// ("lunch" for "launch").
public enum EchoFilter {
    /// Share of the candidate's word triples that must appear in the reference.
    public static let threshold = 0.75

    public static func isLikelyEcho(_ candidate: String, reference: String) -> Bool {
        (score(candidate, reference: reference) ?? 0) >= threshold
    }

    /// Share of the candidate's word triples found in the reference, or nil when
    /// the candidate is too short to judge (under 3 words).
    public static func score(_ candidate: String, reference: String) -> Double? {
        let words = normalizedWords(candidate)
        guard words.count >= 3 else { return nil }
        let referenceWords = normalizedWords(reference)
        // A copy can't be longer than what it copies.
        guard referenceWords.count >= words.count else { return 0 }

        let candidateTriples = ngrams(words, 3)
        let referenceTriples = ngrams(referenceWords, 3)
        let exact = Set(referenceTriples.map { $0.joined(separator: " ") })
        let hits = candidateTriples.filter { triple in
            exact.contains(triple.joined(separator: " "))
                || referenceTriples.contains { zip($0, triple).allSatisfy { similar($0, $1) } }
        }.count
        return Double(hits) / Double(candidateTriples.count)
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    /// Equal, or a likely mishearing of the same word: both at least 4 letters
    /// and at most one edit apart (two for words of 7+ letters). Numbers and
    /// short words must match exactly ("the" vs "that", "1200" vs "1300").
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4,
              a.allSatisfy(\.isLetter), b.allSatisfy(\.isLetter)
        else { return false }
        let allowed = min(a.count, b.count) >= 7 ? 2 : 1
        guard abs(a.count - b.count) <= allowed else { return false }
        return editDistance(Array(a), Array(b), limit: allowed) <= allowed
    }

    /// Levenshtein distance, stopping early once it exceeds `limit`.
    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return rowMin }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func ngrams(_ words: [String], _ n: Int) -> [[String]] {
        guard words.count >= n else { return [] }
        return (0...(words.count - n)).map { Array(words[$0..<($0 + n)]) }
    }
}
