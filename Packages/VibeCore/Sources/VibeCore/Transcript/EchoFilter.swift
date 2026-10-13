import Foundation

/// Text-level defense against speaker bleed: when the other side's voice leaks
/// from the speakers into the mic, the "You" recognizer hears the same words the
/// "Them" recognizer just heard, often garbled. The echo gate on the mic removes
/// most of it (and voice processing, when on); this catches what gets through by
/// comparing "You" text with what "Them" said in the last moments.
///
/// A real answer often reuses their words ("Can you do it in two weeks?" → "I
/// can do it in two weeks"), so both rules are strict:
/// - Near-verbatim copy: most word triples of the candidate appear in the
///   reference, words differing by a letter or two at most ("lunch" for
///   "launch"). The whole candidate is echo.
/// - Garbled copy: the candidate's words are aligned with the reference
///   (Smith-Waterman over words). A long run that follows the reference in
///   order, dense with exact and misheard words ("women's" for "Yemen's",
///   "reporter" for "reporting"), anchored by several exact content words and
///   showing some mishearing, is echo. Only that run is, so "Yeah okay" before
///   it or the user's own words after it stay. The candidate may be longer than
///   the reference. A clean restatement of their sentence has no mishearing and
///   counts as the user talking. Reading their words back once they've stopped
///   can look garbled, so this rule is only for while they talk, which the
///   caller knows.
public enum EchoFilter {
    /// Share of the candidate's word triples that must appear in the reference.
    public static let threshold = 0.75

    /// Bound the work on every recognizer update. Echo is about the last
    /// moments, so older words of either side are left alone.
    static let maxCandidateWords = 120
    static let maxReferenceWords = 120

    public static func isLikelyEcho(_ candidate: String, reference: String) -> Bool {
        (score(candidate, reference: reference) ?? 0) >= threshold
    }

    /// Share of the candidate's word triples found in the reference, or nil when
    /// the candidate is too short to judge (under 3 words).
    public static func score(_ candidate: String, reference: String) -> Double? {
        let words = normalizedWords(candidate)
        guard words.count >= 3 else { return nil }
        let referenceWords = Array(normalizedWords(reference).suffix(maxReferenceWords))
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

    /// `candidate` without what echoes `reference`: nil when none of it does,
    /// empty when all of it does. Garbled runs come out alone; a near-verbatim
    /// copy takes the whole candidate.
    ///
    /// `live` is for in-progress text while they're talking: short garbled runs
    /// count too, so a double doesn't show while it's still too short to judge.
    /// Holding the user's own words back until the final result costs little.
    public static func removingEcho(from candidate: String, reference: String, live: Bool = false) -> String? {
        if let kept = removingGarbledEcho(from: candidate, reference: reference, live: live) { return kept }
        return isLikelyEcho(candidate, reference: reference) ? "" : nil
    }

    /// Like `removingEcho`, with the garbled-copy rule only.
    public static func removingGarbledEcho(from candidate: String, reference: String, live: Bool = false) -> String? {
        let run = live ? Run.live : Run.settled
        let words = tokens(in: candidate)
        guard words.count >= run.minWords else { return nil }
        let referenceWords = tokens(in: reference).suffix(maxReferenceWords).map(\.text)
        guard referenceWords.count >= run.minAnchors else { return nil }
        let aligner = Aligner(candidate: words.map(\.text), reference: Array(referenceWords), run: run)
        let runs = aligner.echoRuns(in: max(0, words.count - maxCandidateWords)..<words.count)
        guard !runs.isEmpty else { return nil }
        return remainder(of: candidate, words: words, removing: runs, run: run)
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

    // MARK: - Garbled copies

    /// What makes an aligned run echo, tuned on real and made-up bleed versus
    /// answers that reuse the other side's words.
    struct Run {
        /// Candidate words from the first to the last matched one.
        var minWords: Int
        /// Exact matches of content words.
        var minAnchors: Int
        /// Share of the run's words that match, exactly or misheard.
        var minDensity = 0.5
        /// Share of the run's content words that match.
        var minContentShare = 0.6
        /// Bleed comes through garbled, a user restating their sentence says it
        /// cleanly. So a run needs a misheard word, and a second misheard or
        /// substituted content word unless it is at least this long.
        var minWordsWithOneSlip: Int?
        /// Words after the last run still taken for its tail: live, the mic
        /// recognizer is often a few garbled words into the next stretch of
        /// echo before it lines up with the reference again.
        var heldBackTailWords = 0

        /// Unmatched content words in a row that split a run: the user's own
        /// words between two stretches of echo.
        static let splitAfterMissedWords = 3

        static let settled = Run(minWords: 10, minAnchors: 4, minWordsWithOneSlip: 16)
        /// Looser in every respect, for text that's only held back for now.
        static let live = Run(minWords: 3, minAnchors: 2, heldBackTailWords: 8)
    }

    /// Alignment scores: exact content words weigh most, misheard words less,
    /// function words little; gaps and mismatches cost.
    enum Weight {
        static let sameContent = 3.0
        static let sameFunction = 0.5
        static let similar = 1.5
        static let different = -0.5
        static let gap = -1.0
    }

    enum Relation: Equatable {
        case same, similar, different
    }

    /// How a candidate word relates to a reference word: the same word, a likely
    /// mishearing of it (close in spelling, sound or stem: "healthies" for
    /// "Halbies", "women's" for "Yemen's", "reporter" for "reporting", "tax" for
    /// "attacks"), or different. Function words and numbers must be the same.
    static func relation(_ a: String, _ b: String) -> Relation {
        relation(WordForm(a), WordForm(b))
    }

    fileprivate static func relation(_ a: WordForm, _ b: WordForm) -> Relation {
        if a.key == b.key { return .same }
        guard let x = a.letters, let y = b.letters else { return .different }
        if x.count >= 4, y.count >= 4 {
            let allowed = max(1, Int(0.34 * Double(max(x.count, y.count))))
            if abs(x.count - y.count) <= allowed, editDistance(x, y, limit: allowed) <= allowed {
                return .similar
            }
        }
        if a.sound.count >= 3, a.sound == b.sound { return .similar }
        if a.stem.count >= 4, a.stem == b.stem { return .similar }
        return .different
    }

    /// Words of a text with where they sit, lowercased, curly apostrophes straightened.
    struct Token {
        var text: String
        var range: Range<String.Index>
    }

    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        func close(at end: String.Index) {
            guard let from = start else { return }
            start = nil
            let word = text[from..<end].lowercased()
                .replacingOccurrences(of: "’", with: "'")
                .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !word.isEmpty { tokens.append(Token(text: word, range: from..<end)) }
        }
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return tokens
    }

    /// The candidate's text outside `runs`. A leftover piece stays only when it
    /// sounds like the user's own words: a reply word ("Yeah", "No"), or four
    /// words or more with a content word. A few words at a run's edge are more
    /// likely the echo's ragged end ("major offenders" for "injured hundreds").
    /// See `Run.heldBackTailWords` for the end of live text.
    private static func remainder(of text: String, words: [Token], removing runs: [ClosedRange<Int>], run: Run) -> String {
        var pieces: [String] = []
        var first = 0
        for bound in runs.map(Optional.some) + [nil] {
            let last = bound.map { $0.lowerBound - 1 } ?? words.count - 1
            let isHeldBackTail = bound == nil && last - first < run.heldBackTailWords
            if first <= last, !isHeldBackTail, isOwnSpeech(words[first...last].map(\.text)) {
                let from = first == 0 ? text.startIndex : words[first - 1].range.upperBound
                let to = bound.map { words[$0.lowerBound].range.lowerBound } ?? text.endIndex
                pieces.append(tidy(text[from..<to]))
            }
            if let bound { first = bound.upperBound + 1 }
        }
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func isOwnSpeech(_ words: [String]) -> Bool {
        if words.contains(where: replyWords.contains) { return true }
        return words.count >= 4 && words.contains { !functionWords.contains($0) }
    }

    /// Single-spaced, without the punctuation left dangling where echo was cut out.
    private static func tidy(_ piece: Substring) -> String {
        let dangling = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "'’\""))
        var piece = piece.drop(while: { $0.unicodeScalars.allSatisfy(dangling.contains) })
        while let last = piece.last, last.isWhitespace || ",;:-–—".contains(last) {
            piece = piece.dropLast()
        }
        return piece.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let replyWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "no", "nope", "okay", "ok", "sure", "right", "alright",
        "thanks", "thank", "great", "good", "cool", "perfect", "exactly", "absolutely", "totally",
    ]

    /// Words too common to tell echo from an answer on the same topic.
    static let functionWords: Set<String> = replyWords.union([
        "a", "an", "the", "and", "or", "but", "nor", "so", "if", "then", "than", "that", "this",
        "these", "those", "there", "here", "of", "to", "in", "on", "at", "by", "for", "with",
        "from", "into", "onto", "about", "as", "up", "down", "out", "off", "over", "under",
        "again", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did",
        "done", "doing", "have", "has", "had", "having", "i", "me", "my", "mine", "we", "us",
        "our", "ours", "you", "your", "yours", "he", "him", "his", "she", "her", "hers", "it",
        "its", "they", "them", "their", "theirs", "what", "which", "who", "whom", "whose",
        "when", "where", "why", "how", "will", "would", "shall", "should", "can", "could",
        "may", "might", "must", "not", "oh", "uh", "um", "erm", "hmm", "mm", "well", "just",
        "really", "very", "too", "also", "all", "any", "some", "each", "every", "both",
        "either", "neither", "one", "ones", "more", "most", "much", "many", "such", "own",
        "same", "other", "get", "got", "gets", "say", "says", "said", "think", "know", "want",
        "like", "make", "take", "see", "go", "goes", "going", "gone", "come", "let", "lets",
        "let's", "i'm", "you're", "we're", "they're", "it's", "that's", "there's", "don't",
        "doesn't", "didn't", "can't", "won't", "isn't", "aren't", "i've", "we've", "you've",
        "i'll", "we'll", "you'll", "i'd", "we'd", "you'd", "now", "still", "even", "only",
    ])
}

/// A word prepared for comparison.
private struct WordForm {
    /// Apostrophes dropped: "yemen's" and "yemens" are the same.
    let key: String
    let isFunctionWord: Bool
    /// Letters of an alphabetic content word of 3+ letters, nil for anything
    /// that must match exactly (function words, numbers, very short words).
    let letters: [Character]?
    /// Consonant skeleton, so "yemens" and "womens" (both "mns") or "tax" and
    /// "attacks" (both "tks") sound alike.
    let sound: String
    /// Without one common suffix ("reporting", "reporter" → "report").
    let stem: String

    init(_ word: String) {
        key = word.replacingOccurrences(of: "'", with: "")
        isFunctionWord = EchoFilter.functionWords.contains(word)
        let isPlain = !isFunctionWord && key.count >= 3 && key.allSatisfy { $0.isASCII && $0.isLetter }
        letters = isPlain ? Array(key) : nil
        sound = isPlain ? Self.sound(of: key) : ""
        stem = isPlain ? Self.stem(of: key) : ""
    }

    private static func sound(of word: String) -> String {
        var sound: [Character] = []
        for letter in word {
            let codes: String
            switch letter {
            case "b", "p": codes = "p"
            case "f", "v": codes = "f"
            case "c", "g", "j", "k", "q": codes = "k"
            case "s", "z": codes = "s"
            case "x": codes = "ks"
            case "d", "t": codes = "t"
            case "l", "m", "n", "r": codes = String(letter)
            default: codes = ""
            }
            for code in codes where sound.last != code { sound.append(code) }
        }
        return String(sound)
    }

    private static func stem(of word: String) -> String {
        for suffix in ["ing", "ers", "er", "ed", "es", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }
}

/// Local alignment of the candidate's words with the reference's.
private struct Aligner {
    private enum Move: UInt8 { case stop, pair, skipCandidate, skipReference }

    /// One step of an alignment: a candidate word paired with a reference word,
    /// a candidate word with no counterpart, or a reference word left out.
    private enum Step {
        case paired(Int, EchoFilter.Relation)
        case extra(Int)
        case missing

        var match: Int? {
            if case .paired(let word, let relation) = self, relation != .different { return word }
            return nil
        }
    }

    private let candidate: [Int]
    private let reference: [Int]
    private let isFunctionWord: [Bool]
    /// Relation of each candidate word form (row) to each reference word form.
    private let relations: [EchoFilter.Relation]
    private let referenceForms: Int
    private let run: EchoFilter.Run

    init(candidate words: [String], reference referenceWords: [String], run: EchoFilter.Run) {
        /// Each word as an index into its distinct forms, so relations are worked out once per pair.
        func intern(_ words: [String]) -> ([Int], [WordForm]) {
            var seen: [String: Int] = [:]
            var forms: [WordForm] = []
            let ids = words.map { word -> Int in
                if let id = seen[word] { return id }
                seen[word] = forms.count
                forms.append(WordForm(word))
                return forms.count - 1
            }
            return (ids, forms)
        }
        let (candidate, candidateForms) = intern(words)
        let (reference, referenceForms) = intern(referenceWords)
        self.candidate = candidate
        self.reference = reference
        self.referenceForms = referenceForms.count
        self.run = run
        isFunctionWord = candidate.map { candidateForms[$0].isFunctionWord }
        relations = candidateForms.flatMap { form in referenceForms.map { EchoFilter.relation(form, $0) } }
    }

    /// Word ranges of the candidate that are echo, in order.
    func echoRuns(in range: Range<Int>, depth: Int = 0) -> [ClosedRange<Int>] {
        guard range.count >= run.minWords, depth < 4 else { return [] }
        let found = pieces(of: bestAlignment(in: range)).compactMap(echoedWords)
        guard let first = found.first, let last = found.last else { return [] }
        return echoRuns(in: range.lowerBound..<first.lowerBound, depth: depth + 1)
            + found
            + echoRuns(in: (last.upperBound + 1)..<range.upperBound, depth: depth + 1)
    }

    private func relation(_ word: Int, _ referenceWord: Int) -> EchoFilter.Relation {
        relations[candidate[word] * referenceForms + reference[referenceWord]]
    }

    private func weight(_ relation: EchoFilter.Relation, word: Int) -> Double {
        switch relation {
        case .same: return isFunctionWord[word] ? EchoFilter.Weight.sameFunction : EchoFilter.Weight.sameContent
        case .similar: return EchoFilter.Weight.similar
        case .different: return EchoFilter.Weight.different
        }
    }

    /// Smith-Waterman over words: the best-scoring stretch where the candidate
    /// follows the reference.
    private func bestAlignment(in range: Range<Int>) -> [Step] {
        let rows = range.count + 1, columns = reference.count + 1
        var score = [Double](repeating: 0, count: rows * columns)
        var moves = [Move](repeating: .stop, count: rows * columns)
        var best = (score: 0.0, cell: 0)
        for i in 1..<rows {
            let word = range.lowerBound + i - 1
            for j in 1..<columns {
                let cell = i * columns + j
                var value = 0.0, move = Move.stop
                let paired = score[cell - columns - 1] + weight(relation(word, j - 1), word: word)
                if paired > value { (value, move) = (paired, .pair) }
                let skippedCandidate = score[cell - columns] + EchoFilter.Weight.gap
                if skippedCandidate > value { (value, move) = (skippedCandidate, .skipCandidate) }
                let skippedReference = score[cell - 1] + EchoFilter.Weight.gap
                if skippedReference > value { (value, move) = (skippedReference, .skipReference) }
                score[cell] = value
                moves[cell] = move
                if value > best.score { best = (value, cell) }
            }
        }
        var steps: [Step] = []
        var (i, j) = (best.cell / columns, best.cell % columns)
        while i > 0, j > 0 {
            let word = range.lowerBound + i - 1
            switch moves[i * columns + j] {
            case .stop: return steps.reversed()
            case .pair: steps.append(.paired(word, relation(word, j - 1))); i -= 1; j -= 1
            case .skipCandidate: steps.append(.extra(word)); i -= 1
            case .skipReference: steps.append(.missing); j -= 1
            }
        }
        return steps.reversed()
    }

    /// The alignment cut where several content words in a row match nothing,
    /// each piece from its first to its last match.
    private func pieces(of steps: [Step]) -> [ArraySlice<Step>] {
        var pieces: [ArraySlice<Step>] = []
        var start: Int?, lastMatch = 0, missed = 0
        for (index, step) in steps.enumerated() {
            if step.match != nil {
                if missed >= EchoFilter.Run.splitAfterMissedWords, let from = start {
                    pieces.append(steps[from...lastMatch])
                    start = nil
                }
                if start == nil { start = index }
                lastMatch = index
                missed = 0
            } else if case .paired(let word, _) = step, !isFunctionWord[word] {
                missed += 1
            } else if case .extra(let word) = step, !isFunctionWord[word] {
                missed += 1
            }
        }
        if let from = start { pieces.append(steps[from...lastMatch]) }
        return pieces
    }

    /// The candidate words a piece covers, when it reads as echo.
    private func echoedWords(_ piece: ArraySlice<Step>) -> ClosedRange<Int>? {
        var matched: [Int] = []
        var anchors = 0, misheard = 0, substituted = 0
        for case .paired(let word, let relation) in piece {
            switch relation {
            case .same:
                matched.append(word)
                if !isFunctionWord[word] { anchors += 1 }
            case .similar:
                matched.append(word)
                misheard += 1
            case .different:
                if !isFunctionWord[word] { substituted += 1 }
            }
        }
        guard let first = matched.first, let last = matched.last else { return nil }
        let length = last - first + 1
        let content = (first...last).filter { !isFunctionWord[$0] }
        let matchedContent = matched.filter { !isFunctionWord[$0] }.count
        guard length >= run.minWords,
              anchors >= run.minAnchors,
              Double(matched.count) >= run.minDensity * Double(length),
              Double(matchedContent) >= run.minContentShare * Double(content.count)
        else { return nil }
        if let minWordsWithOneSlip = run.minWordsWithOneSlip {
            guard misheard >= 1, misheard + substituted >= 2 || length >= minWordsWithOneSlip else { return nil }
        }
        return first...last
    }
}
