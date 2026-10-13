import Foundation

/// What kind of move the reply should make.
public enum ReplyIntent: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case answer
    case clarify
    case add
    case pushBack
    /// Not a reply: questions to ask the other side (Ask questions).
    case questions

    public var id: String { rawValue }

    /// A move this build doesn't know (saved by a newer version) reads as `.auto`,
    /// so the meeting still opens.
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = ReplyIntent(rawValue: rawValue) ?? .auto
    }

    public var label: String {
        switch self {
        case .auto: return "Reply"
        case .answer: return "Answer"
        case .clarify: return "Clarify"
        case .add: return "Add"
        case .pushBack: return "Push back"
        case .questions: return "Questions"
        }
    }

    /// Intents shown as chips in the overlay (Auto is the main Reply button).
    public static let explicit: [ReplyIntent] = [.answer, .clarify, .add, .pushBack]

    /// Instruction sent to the model.
    public var instruction: String {
        switch self {
        case .auto:
            return "Choose the best move yourself. If it is a question, answer it. If it is an opinion or a plan, respond to it. If something is wrong or ambiguous, clarify it politely."
        case .answer:
            return "Answer directly in the first sentence, then give one or two supporting sentences."
        case .clarify:
            return "Politely correct the point or ask a clarifying question back. Say which assumption you are checking."
        case .add:
            return "Acknowledge their point, then add one relevant idea drawn from the meeting context. Don't take over the conversation."
        case .pushBack:
            return "Disagree respectfully. Give the reason, then offer an alternative."
        case .questions:
            return Prompts.questionsTask
        }
    }
}

/// How a script was produced.
public enum ReplyVariant: String, Codable, Sendable {
    /// First script for a target.
    case fresh
    /// New attempt for the same target.
    case regenerate
    /// Shorter version of the previous script.
    case shorter

    /// A kind this build doesn't know (saved by a newer version) reads as `.fresh`.
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = ReplyVariant(rawValue: rawValue) ?? .fresh
    }
}

/// Why a Reply or Ask questions produced nothing. Logic checks the case; the
/// message is only for display.
public enum ReplyFailure: Equatable, Sendable {
    /// No line in the transcript to answer yet.
    case nothingToReplyTo
    /// Ask questions came back without a usable question.
    case noQuestions
    /// The model declined to write it.
    case declined
    /// Network, API key or server error.
    case requestFailed

    /// Maps a failed request.
    public init(error: Error) {
        if case .refusal = error as? ClaudeError {
            self = .declined
        } else {
            self = .requestFailed
        }
    }

    /// Whether the same request again can help (Try again).
    public var canRetry: Bool { self != .nothingToReplyTo }

    public var message: String {
        switch self {
        case .nothingToReplyTo: return "Nothing to reply to yet."
        case .noQuestions: return "No questions came back. Try again."
        case .declined: return "Claude declined this one. Try rephrasing with Steer."
        case .requestFailed: return "Couldn't draft a reply. Check your connection or API key."
        }
    }
}

/// A reply script generated during a session.
public struct ReplyScript: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var targetTurnIDs: [UUID]
    public var targetText: String
    public var intent: ReplyIntent
    public var steer: String
    public var variant: ReplyVariant
    public var presetName: String
    public var model: String
    public var text: String
    /// Seconds from the hotkey to the first streamed word.
    public var firstTokenLatency: TimeInterval?
    /// Seconds from the hotkey to the end of the script.
    public var totalLatency: TimeInterval?
    public var usage: TokenUsage?
    public var stopReason: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        targetTurnIDs: [UUID],
        targetText: String,
        intent: ReplyIntent,
        steer: String,
        variant: ReplyVariant,
        presetName: String,
        model: String,
        text: String = "",
        firstTokenLatency: TimeInterval? = nil,
        totalLatency: TimeInterval? = nil,
        usage: TokenUsage? = nil,
        stopReason: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.targetTurnIDs = targetTurnIDs
        self.targetText = targetText
        self.intent = intent
        self.steer = steer
        self.variant = variant
        self.presetName = presetName
        self.model = model
        self.text = text
        self.firstTokenLatency = firstTokenLatency
        self.totalLatency = totalLatency
        self.usage = usage
        self.stopReason = stopReason
    }

    /// True when the script asks the user to confirm a number before saying it.
    public var needsNumberConfirmation: Bool {
        ScriptText.containsMarker(text)
    }
}

/// Token counts reported by the API.
public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0, cacheReadInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    /// Total prompt size, cached or not.
    public var totalInputTokens: Int { inputTokens + cacheCreationInputTokens + cacheReadInputTokens }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }
}
