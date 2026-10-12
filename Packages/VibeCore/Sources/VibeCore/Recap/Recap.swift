import Foundation

/// Post-meeting recap returned by the model as structured JSON.
public struct Recap: Codable, Equatable, Sendable {
    public struct ActionItem: Codable, Equatable, Sendable, Identifiable {
        public var id: String { task + "|" + owner.rawValue + "|" + due }
        public var task: String
        public var owner: Speaker
        /// Deadline as spoken ("Friday", "end of month"), or empty when none was mentioned.
        public var due: String

        public init(task: String, owner: Speaker, due: String = "") {
            self.task = task
            self.owner = owner
            self.due = due
        }

        enum CodingKeys: String, CodingKey { case task, owner, due }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            task = try container.decode(String.self, forKey: .task)
            let ownerLabel = try container.decode(String.self, forKey: .owner)
            owner = ownerLabel.lowercased() == "you" ? .you : .them
            due = try container.decodeIfPresent(String.self, forKey: .due) ?? ""
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(task, forKey: .task)
            try container.encode(owner.label, forKey: .owner)
            try container.encode(due, forKey: .due)
        }
    }

    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]

    public init(summary: String, keyPoints: [String] = [], decisions: [String] = [], actionItems: [ActionItem] = [], openQuestions: [String] = []) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    enum CodingKeys: String, CodingKey {
        case summary
        case keyPoints = "key_points"
        case decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    /// JSON schema for `output_config.format`, matching `CodingKeys`.
    public static let jsonSchema: JSONValue = .object([
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "key_points", "decisions", "action_items", "open_questions"],
        "properties": .object([
            "summary": .object([
                "type": "string",
                "description": "Three to five sentences on what the meeting covered and where it landed.",
            ]),
            "key_points": stringArray("Important facts, numbers, and requirements that came up."),
            "decisions": stringArray("Things both sides agreed on. Empty if nothing was decided."),
            "action_items": .object([
                "type": "array",
                "items": .object([
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["task", "owner", "due"],
                    "properties": .object([
                        "task": .object(["type": "string", "description": "The concrete next step."]),
                        "owner": .object(["type": "string", "enum": ["You", "Them"]]),
                        "due": .object(["type": "string", "description": "Deadline as mentioned, or an empty string if none was mentioned."]),
                    ]),
                ]),
            ]),
            "open_questions": stringArray("Questions that were raised but not answered."),
        ]),
    ])

    private static func stringArray(_ description: String) -> JSONValue {
        .object(["type": "array", "description": .string(description), "items": .object(["type": "string"])])
    }
}

extension Recap {
    /// Markdown for "Copy as Markdown" and .md export.
    public func markdown(title: String, date: Date?, duration: TimeInterval?, timeZone: TimeZone = .current) -> String {
        var lines: [String] = ["# \(title.isEmpty ? "Meeting recap" : title)"]

        var meta: [String] = []
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEE, MMM d, yyyy 'at' HH:mm"
            meta.append(formatter.string(from: date))
        }
        if let duration, duration > 0 {
            meta.append(Self.formatDuration(duration))
        }
        if !meta.isEmpty { lines.append("_\(meta.joined(separator: " · "))_") }

        lines.append("")
        lines.append("## Summary")
        lines.append(summary.isEmpty ? "_No summary._" : summary)

        func section(_ heading: String, _ items: [String]) {
            lines.append("")
            lines.append("## \(heading)")
            if items.isEmpty {
                lines.append("_None._")
            } else {
                lines.append(contentsOf: items.map { "- \($0)" })
            }
        }

        section("Key points", keyPoints)
        section("Decisions", decisions)
        section("Action items", actionItems.map { item in
            var detail = item.owner.label
            if !item.due.isEmpty { detail += ", due \(item.due)" }
            return "[ ] \(item.task) (\(detail))"
        })
        section("Open questions", openQuestions)
        return lines.joined(separator: "\n") + "\n"
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
