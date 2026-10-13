import Foundation

/// Everything saved for one meeting. Audio is never part of it.
public struct MeetingRecord: Identifiable, Codable, Equatable, Sendable {
    /// Format version written by this build. History:
    /// 1: no version field; action item owners saved as labels ("You").
    /// 2: action item owners saved by raw value ("you").
    /// 3: the meeting's languages (`language`).
    public static let currentSchemaVersion = 3

    public let id: UUID
    /// Format version of the saved file. `SessionStore.save` writes the current one.
    public var schemaVersion: Int
    public var name: String
    public var startedAt: Date
    public var endedAt: Date?
    public var presetID: String
    public var presetName: String
    public var meetingInstructions: String
    /// What the user wants from this meeting. Every reply and question steers toward it.
    public var goal: String
    /// What's spoken in the call and what replies and the recap are written in.
    /// English (United States) for meetings saved before languages existed.
    public var language: MeetingLanguage
    public var context: [ContextItem]
    public var turns: [TranscriptTurn]
    public var scripts: [ReplyScript]
    public var recap: Recap?
    public var recapError: String?
    public var replyModel: String
    public var recapModel: String?
    public var stats: SessionStats
    /// Starred in the main window, to find it again quickly.
    public var isStarred: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        presetID: String,
        presetName: String,
        meetingInstructions: String = "",
        goal: String = "",
        language: MeetingLanguage = .english,
        context: [ContextItem] = [],
        turns: [TranscriptTurn] = [],
        scripts: [ReplyScript] = [],
        recap: Recap? = nil,
        recapError: String? = nil,
        replyModel: String,
        recapModel: String? = nil,
        stats: SessionStats = SessionStats(),
        isStarred: Bool = false
    ) {
        self.id = id
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.presetID = presetID
        self.presetName = presetName
        self.meetingInstructions = meetingInstructions
        self.goal = goal
        self.language = language
        self.context = context
        self.turns = turns
        self.scripts = scripts
        self.recap = recap
        self.recapError = recapError
        self.replyModel = replyModel
        self.recapModel = recapModel
        self.stats = stats
        self.isStarred = isStarred
    }

    // Meetings saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        name = try container.decode(String.self, forKey: .name)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        presetID = try container.decode(String.self, forKey: .presetID)
        presetName = try container.decode(String.self, forKey: .presetName)
        meetingInstructions = try container.decodeIfPresent(String.self, forKey: .meetingInstructions) ?? ""
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        language = try container.decodeIfPresent(MeetingLanguage.self, forKey: .language) ?? .english
        context = try container.decodeIfPresent([ContextItem].self, forKey: .context) ?? []
        turns = try container.decodeIfPresent([TranscriptTurn].self, forKey: .turns) ?? []
        scripts = try container.decodeIfPresent([ReplyScript].self, forKey: .scripts) ?? []
        recap = try container.decodeIfPresent(Recap.self, forKey: .recap)
        recapError = try container.decodeIfPresent(String.self, forKey: .recapError)
        replyModel = try container.decode(String.self, forKey: .replyModel)
        recapModel = try container.decodeIfPresent(String.self, forKey: .recapModel)
        stats = try container.decodeIfPresent(SessionStats.self, forKey: .stats) ?? SessionStats()
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
    }

    /// Saved by a newer VibeMeeting. Shown read-only and never saved by this
    /// build, so data it doesn't know about isn't lost.
    public var isFromNewerVersion: Bool { schemaVersion > Self.currentSchemaVersion }

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

    /// Plain-text transcript with time offsets from the start, for the user
    /// (speakers by their display label).
    public func transcriptText() -> String {
        transcriptText(speakerName: \.label)
    }

    /// The same transcript for prompts, with the speakers' prompt tokens.
    public func promptTranscriptText() -> String {
        transcriptText(speakerName: \.promptToken)
    }

    private func transcriptText(speakerName: (Speaker) -> String) -> String {
        turns.filter { !$0.text.isEmpty }.map { turn in
            "[\(Self.offset(turn.startedAt.timeIntervalSince(startedAt)))] \(speakerName(turn.speaker)): \(turn.text)"
        }.joined(separator: "\n")
    }

    /// Case-insensitive match against name, transcript, scripts and recap.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if displayName.localizedCaseInsensitiveContains(query) { return true }
        if turns.contains(where: { $0.text.localizedCaseInsensitiveContains(query) }) { return true }
        if scripts.contains(where: { $0.text.localizedCaseInsensitiveContains(query) }) { return true }
        if goal.localizedCaseInsensitiveContains(query) { return true }
        if let recap, recap.markdown(title: "", date: nil, duration: nil).localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    public static func offset(_ seconds: TimeInterval) -> String {
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
