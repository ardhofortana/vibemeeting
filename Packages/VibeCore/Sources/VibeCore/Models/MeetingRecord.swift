import Foundation

/// Everything saved for one meeting. Audio is never part of it.
public struct MeetingRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var presetID: String
    public var presetName: String
    public var meetingInstructions: String
    public var context: [ContextItem]
    public var turns: [TranscriptTurn]
    public var scripts: [ReplyScript]
    public var recap: Recap?
    public var recapError: String?
    public var replyModel: String
    public var recapModel: String?
    public var stats: SessionStats

    public init(
        id: UUID = UUID(),
        name: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        presetID: String,
        presetName: String,
        meetingInstructions: String = "",
        context: [ContextItem] = [],
        turns: [TranscriptTurn] = [],
        scripts: [ReplyScript] = [],
        recap: Recap? = nil,
        recapError: String? = nil,
        replyModel: String,
        recapModel: String? = nil,
        stats: SessionStats = SessionStats()
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.presetID = presetID
        self.presetName = presetName
        self.meetingInstructions = meetingInstructions
        self.context = context
        self.turns = turns
        self.scripts = scripts
        self.recap = recap
        self.recapError = recapError
        self.replyModel = replyModel
        self.recapModel = recapModel
        self.stats = stats
    }

    /// Name shown in lists.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return "Meeting \(formatter.string(from: startedAt))"
    }

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Plain-text transcript with time offsets from the start.
    public func transcriptText() -> String {
        turns.filter { !$0.text.isEmpty }.map { turn in
            "[\(Self.offset(turn.startedAt.timeIntervalSince(startedAt)))] \(turn.speaker.label): \(turn.text)"
        }.joined(separator: "\n")
    }

    /// Case-insensitive match against name, transcript, scripts and recap.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if displayName.localizedCaseInsensitiveContains(query) { return true }
        if turns.contains(where: { $0.text.localizedCaseInsensitiveContains(query) }) { return true }
        if scripts.contains(where: { $0.text.localizedCaseInsensitiveContains(query) }) { return true }
        if let recap, recap.markdown(title: "", date: nil, duration: nil).localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    static func offset(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// Local usage numbers for the success metrics in the PRD.
public struct SessionStats: Codable, Equatable, Sendable {
    public var replyCount = 0
    public var regenerateCount = 0
    public var shorterCount = 0
    public var failedCount = 0
    public var firstTokenLatencies: [TimeInterval] = []
    public var usage = TokenUsage()
    public var recapUsage = TokenUsage()
    /// Estimated USD, from the catalog prices at the time of the call.
    public var estimatedCost: Double = 0

    public init() {}

    public var medianFirstTokenLatency: TimeInterval? { Self.percentile(firstTokenLatencies, 0.5) }
    public var p90FirstTokenLatency: TimeInterval? { Self.percentile(firstTokenLatencies, 0.9) }

    /// Share of replies that were regenerated (target: under 30%).
    public var regenerateRate: Double? {
        replyCount == 0 ? nil : Double(regenerateCount) / Double(replyCount)
    }

    public static func percentile(_ values: [TimeInterval], _ p: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let weight = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }
}
