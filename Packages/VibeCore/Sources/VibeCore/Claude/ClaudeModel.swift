import Foundation

/// Known models and the request settings VibeMeeting uses with each.
public struct ClaudeModel: Identifiable, Hashable, Sendable {
    /// USD per million tokens.
    public struct Pricing: Hashable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        /// 5-minute cache write.
        public var cacheWrite: Double

        public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }

        public func cost(of usage: TokenUsage) -> Double {
            (Double(usage.inputTokens) * input
                + Double(usage.outputTokens) * output
                + Double(usage.cacheReadInputTokens) * cacheRead
                + Double(usage.cacheCreationInputTokens) * cacheWrite) / 1_000_000
        }
    }

    public var id: String
    public var displayName: String
    public var pricing: Pricing?
    /// Thinking setting for replies, where the fastest first token matters most.
    /// `nil` leaves the field out of the request.
    public var replyThinking: ThinkingConfig?
    /// Effort for replies. `nil` leaves it out.
    public var replyEffort: String?
    /// Effort for the recap.
    public var recapEffort: String?
    /// Whether `fallbacks: "default"` (server-side refusal fallback) is accepted.
    public var supportsDefaultFallback: Bool

    public init(
        id: String,
        displayName: String,
        pricing: Pricing? = nil,
        replyThinking: ThinkingConfig? = nil,
        replyEffort: String? = nil,
        recapEffort: String? = nil,
        supportsDefaultFallback: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.pricing = pricing
        self.replyThinking = replyThinking
        self.replyEffort = replyEffort
        self.recapEffort = recapEffort
        self.supportsDefaultFallback = supportsDefaultFallback
    }

    public static func == (lhs: ClaudeModel, rhs: ClaudeModel) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ClaudeModel {
    /// Fastest model; the default for replies. Thinking off for the quickest first token.
    /// Prices are the ≤100K-token prompt rate card.
    public static let haiku55 = ClaudeModel(
        id: "claude-haiku-5-5",
        displayName: "Claude Haiku 5.5",
        pricing: Pricing(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
        replyThinking: .disabled,
        replyEffort: "low",
        recapEffort: "medium"
    )

    /// Thinking can only be turned off with `between_tools` on this model.
    public static let sonnet55 = ClaudeModel(
        id: "claude-sonnet-5-5",
        displayName: "Claude Sonnet 5.5",
        pricing: Pricing(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5),
        replyThinking: .betweenTools,
        replyEffort: "low",
        recapEffort: "medium",
        supportsDefaultFallback: true
    )

    /// Most capable; the default for recaps. Thinking can't be disabled, so replies run at low effort.
    public static let opus55 = ClaudeModel(
        id: "claude-opus-5-5",
        displayName: "Claude Opus 5.5",
        pricing: Pricing(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5),
        replyThinking: nil,
        replyEffort: "low",
        recapEffort: "medium",
        supportsDefaultFallback: true
    )

    public static let catalog: [ClaudeModel] = [haiku55, sonnet55, opus55]

    public static let defaultReplyModelID = haiku55.id
    public static let defaultRecapModelID = opus55.id

    /// A catalog entry, or a bare entry for a custom model ID with no extra settings.
    public static func resolve(_ id: String) -> ClaudeModel {
        catalog.first { $0.id == id } ?? ClaudeModel(id: id, displayName: id)
    }

    public static let serverFallbackBeta = "server-side-fallback-2026-07-01"
}
