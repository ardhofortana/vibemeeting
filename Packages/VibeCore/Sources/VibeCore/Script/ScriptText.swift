import Foundation

/// Text helpers for reply scripts.
public enum ScriptText {
    public static let confirmNumberMarker = "[confirm number]"

    /// Cleans up formatting the rules forbid but a model may still produce,
    /// so the script reads as plain spoken text.
    public static func sanitize(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines).map { line -> String in
            var line = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "• ", "* ", "# ", "## ", "### "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }
            return line
        }
        lines.removeAll { $0.isEmpty }
        var result = lines.joined(separator: " ")

        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: " — ", with: ", ")
        result = result.replacingOccurrences(of: "—", with: ", ")
        result = result.replacingOccurrences(of: " – ", with: ", ")
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: ",,", with: ",")
        result = result.trimmingCharacters(in: .whitespaces)

        if result.count >= 2,
           let first = result.first, let last = result.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// The questions of an Ask questions result, one per line, cleaned up. Drops
    /// numbering, bullets, an intro ("Here are some questions:") and lines that
    /// aren't questions ("I hope these help."). While streaming (`final` false)
    /// the line being written is kept as it is. When finished, if no line is a
    /// question (the model wrote prompts like "Walk me through your process."),
    /// those lines are returned rather than nothing.
    public static func questions(from text: String, final: Bool = false) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var questions: [String] = []
        var others: [String] = []
        for (index, raw) in lines.enumerated() {
            var line = raw.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            // "1. ", "2) ", "- ", "• "
            if let match = line.range(of: #"^(\d{1,2}[.)]|[-•])\s+"#, options: .regularExpression) {
                line.removeSubrange(match)
            }
            line = sanitize(line)
            guard !line.isEmpty, !line.hasSuffix(":") else { continue }
            let beingWritten = !final && index == lines.count - 1
            if line.contains("?") || beingWritten {
                questions.append(line)
            } else {
                others.append(line)
            }
        }
        return final && questions.isEmpty ? others : questions
    }

    /// Splits off the first sentence so it can be shown in bold. While a
    /// script is still streaming and has no sentence end yet, everything is "first".
    public static func splitFirstSentence(_ text: String) -> (first: String, rest: String) {
        guard let end = firstSentenceEnd(in: text) else {
            return (text, "")
        }
        var first = String(text[..<end])
        var rest = String(text[end...]).trimmingCharacters(in: .whitespaces)
        if rest.lowercased().hasPrefix(confirmNumberMarker) {
            first += " " + rest.prefix(confirmNumberMarker.count)
            rest = String(rest.dropFirst(confirmNumberMarker.count)).trimmingCharacters(in: .whitespaces)
        }
        return (first.trimmingCharacters(in: .whitespaces), rest)
    }

    /// Sentences in order, with a trailing [confirm number] kept on its sentence.
    public static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while !remaining.isEmpty {
            let (first, rest) = splitFirstSentence(remaining)
            if !first.isEmpty { sentences.append(first) }
            if rest == remaining { break }
            remaining = rest
        }
        return sentences
    }

    /// Index just past the first sentence terminator that is followed by
    /// whitespace or the end of the text. Decimals like "2.5" don't count, and
    /// neither does a spoken pause like "so... it's" unless it ends the text.
    static func firstSentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "." || character == "!" || character == "?" {
                // Swallow runs like "?!" or "..." and a closing quote or bracket.
                var end = next
                while end < text.endIndex, ".!?\"”')".contains(text[end]) {
                    end = text.index(after: end)
                }
                if end == text.endIndex {
                    // Only a real end if the terminator closes the whole text.
                    return end
                }
                let marks = text[index..<end].prefix { ".!?".contains($0) }
                let isPause = marks.count > 1 && marks.allSatisfy { $0 == "." }
                if text[end].isWhitespace, !isPause {
                    return end
                }
                index = end
                continue
            }
            index = next
        }
        return nil
    }
}
