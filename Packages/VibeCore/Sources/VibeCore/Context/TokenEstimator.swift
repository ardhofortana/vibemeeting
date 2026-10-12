import Foundation

/// Offline token estimates for UI warnings. Exact counts come back in `usage`.
public enum TokenEstimator {
    /// Newer Claude tokenizers average roughly 3.3 characters per token on English prose.
    public static let charactersPerToken = 3.3

    public static func tokens(forText text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / charactersPerToken).rounded(.up))
    }

    /// Images cost about width × height / 750 tokens after the API scales them
    /// to fit within 1568 px on the long edge.
    public static func tokens(forImageWidth width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let longEdge = Double(max(width, height))
        let scale = min(1, 1568 / longEdge)
        let w = Double(width) * scale
        let h = Double(height) * scale
        return Int((w * h / 750).rounded(.up))
    }
}

/// Whether the meeting context is a comfortable size for fast replies.
public enum ContextBudget: Equatable, Sendable {
    case ok
    /// Replies still work but the first one is slower and each costs more.
    case large
    /// Above the point where speed and price get noticeably worse.
    case tooLarge

    public static let largeThreshold = 40_000
    public static let tooLargeThreshold = 90_000

    public static func status(forTokens tokens: Int) -> ContextBudget {
        if tokens >= tooLargeThreshold { return .tooLarge }
        if tokens >= largeThreshold { return .large }
        return .ok
    }

    public static func status(for items: [ContextItem]) -> ContextBudget {
        status(forTokens: items.reduce(0) { $0 + $1.estimatedTokens })
    }

    public var warning: String? {
        switch self {
        case .ok: return nil
        case .large: return "Large context. The first reply may be slower."
        case .tooLarge: return "Context is very large. Replies will be slower and cost more. Consider trimming it."
        }
    }
}
