import Foundation

/// A reply style: a name, a long instruction, and a target length.
public struct StylePreset: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var instructions: String
    public var minSentences: Int
    public var maxSentences: Int
    public var isBuiltIn: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        instructions: String,
        minSentences: Int,
        maxSentences: Int,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.minSentences = max(1, minSentences)
        self.maxSentences = max(self.minSentences, maxSentences)
        self.isBuiltIn = isBuiltIn
    }

    public var lengthDescription: String {
        minSentences == maxSentences
            ? "\(minSentences) sentence\(minSentences == 1 ? "" : "s")"
            : "\(minSentences)–\(maxSentences) sentences"
    }
}

extension StylePreset {
    public static let friendlyProID = "builtin.friendly-pro"

    public static let builtIns: [StylePreset] = [
        StylePreset(
            id: friendlyProID,
            name: "Friendly Pro",
            instructions: """
            Warm, clear, relaxed but professional. Sound like a helpful expert who enjoys the work. \
            Use plain words and a friendly tone, and keep it easy to follow for a non-native listener.
            """,
            minSentences: 2, maxSentences: 4, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.consultant",
            name: "Consultant",
            instructions: """
            Structured and confident. Lead the discussion: frame the issue, give a clear recommendation, \
            and suggest the next step. Sound like someone who has done this many times.
            """,
            minSentences: 3, maxSentences: 5, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.negotiator",
            name: "Negotiator",
            instructions: """
            Firm on scope and price while staying polite. Don't offer discounts or extra work unprompted. \
            Tie any change in price to a change in scope, and anchor on the value delivered.
            """,
            minSentences: 2, maxSentences: 4, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.tech-explainer",
            name: "Tech Explainer",
            instructions: """
            Explain technical points in everyday language. Use one simple analogy when it helps. \
            State assumptions clearly and avoid jargon unless the client used it first.
            """,
            minSentences: 3, maxSentences: 5, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.short-sweet",
            name: "Short & Sweet",
            instructions: "Get straight to the point. No warm-up, no recap of what they said.",
            minSentences: 1, maxSentences: 2, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.diplomatic",
            name: "Diplomatic",
            instructions: """
            Clarify or disagree without making anyone feel wrong. Acknowledge their view first, \
            use soft language, and frame corrections as shared problem solving.
            """,
            minSentences: 2, maxSentences: 4, isBuiltIn: true
        ),
    ]

    public static var friendlyPro: StylePreset { builtIns[0] }
}
