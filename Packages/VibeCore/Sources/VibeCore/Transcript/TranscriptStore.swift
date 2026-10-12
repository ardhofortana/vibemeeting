import Foundation

/// Groups recognizer output from the two audio streams into speaking turns.
///
/// Each speaker has at most one *open* turn that keeps growing while that
/// person keeps talking. A new turn starts when the other side spoke in
/// between, or after a long pause.
public struct TranscriptStore: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Pause after which the same speaker starts a fresh turn.
        public var maxPauseWithinTurn: TimeInterval
        /// How far back "You" text is compared with "Them" text for echo.
        public var echoWindow: TimeInterval
        /// "You" turns at or under this many words don't break up a "Them" turn
        /// when choosing the reply target ("yeah", "mm-hmm", "right").
        public var backchannelMaxWords: Int
        /// Most "Them" turns merged into one reply target.
        public var maxMergedTargetTurns: Int

        public init(
            maxPauseWithinTurn: TimeInterval = 6,
            echoWindow: TimeInterval = 12,
            backchannelMaxWords: Int = 3,
            maxMergedTargetTurns: Int = 4
        ) {
            self.maxPauseWithinTurn = maxPauseWithinTurn
            self.echoWindow = echoWindow
            self.backchannelMaxWords = backchannelMaxWords
            self.maxMergedTargetTurns = maxMergedTargetTurns
        }
    }

    public private(set) var turns: [TranscriptTurn]
    public var configuration: Configuration
    private var openTurnIDs: [Speaker: UUID] = [:]
    private var recentThemText: [(date: Date, text: String)] = []
    /// Number of "You" segments dropped as speaker echo, for diagnostics.
    public private(set) var droppedEchoSegments = 0

    public init(turns: [TranscriptTurn] = [], configuration: Configuration = Configuration()) {
        self.turns = turns
        self.configuration = configuration
    }

    public static func == (lhs: TranscriptStore, rhs: TranscriptStore) -> Bool {
        lhs.turns == rhs.turns && lhs.openTurnIDs == rhs.openTurnIDs
    }

    // MARK: - Recognizer input

    public mutating func apply(_ update: TranscriptUpdate, at now: Date = Date()) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let speaker = update.speaker

        if speaker == .them {
            pruneEchoReference(now: now)
            if update.kind == .final, !text.isEmpty {
                recentThemText.append((now, text))
            }
        }

        if text.isEmpty {
            // An empty volatile result means the in-progress text went away.
            if let index = openTurnIndex(for: speaker) {
                turns[index].volatileText = ""
                removeIfEmpty(at: index, speaker: speaker)
            }
            return
        }

        if update.kind == .final, speaker == .you, isLikelyEcho(text, now: now) {
            droppedEchoSegments += 1
            if let index = openTurnIndex(for: speaker) {
                turns[index].volatileText = ""
                removeIfEmpty(at: index, speaker: speaker)
            }
            return
        }

        let index = turnIndexForNewText(from: speaker, now: now)
        switch update.kind {
        case .volatile:
            turns[index].volatileText = text
        case .final:
            turns[index].finalText = TranscriptTurn.join(turns[index].finalText, text)
            turns[index].volatileText = ""
        }
        turns[index].updatedAt = now
    }

    /// Closes all open turns, e.g. when the meeting ends. In-progress text is kept as final.
    public mutating func finalizeAll(at now: Date = Date()) {
        for index in turns.indices where !turns[index].volatileText.isEmpty {
            turns[index].finalText = TranscriptTurn.join(turns[index].finalText, turns[index].volatileText)
            turns[index].volatileText = ""
            turns[index].updatedAt = now
        }
        openTurnIDs.removeAll()
        turns.removeAll { $0.text.isEmpty }
    }

    // MARK: - Manual edits

    /// Replaces a turn's text with a manual correction. The turn is closed, so
    /// later speech from the same person goes into a new turn.
    public mutating func edit(turnID: UUID, text: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recognized = TranscriptTurn.join(turns[index].finalText, turns[index].volatileText)
        if trimmed.isEmpty || trimmed == recognized {
            turns[index].editedText = nil
        } else {
            turns[index].finalText = recognized
            turns[index].volatileText = ""
            turns[index].editedText = trimmed
        }
        if openTurnIDs[turns[index].speaker] == turnID {
            openTurnIDs[turns[index].speaker] = nil
        }
    }

    // MARK: - Queries

    public func turn(id: UUID) -> TranscriptTurn? {
        turns.first { $0.id == id }
    }

    /// What a reply should respond to.
    ///
    /// With a selected turn, that turn is the target. Otherwise it is the
    /// latest "Them" turn, merged with earlier "Them" turns that were only
    /// interrupted by short backchannels from "You".
    public func replyTarget(selectedTurnID: UUID? = nil) -> ReplyTarget? {
        if let selectedTurnID, let turn = turn(id: selectedTurnID), !turn.text.isEmpty {
            return ReplyTarget(turnIDs: [turn.id], speaker: turn.speaker, text: turn.text, isLive: turn.isLive)
        }
        guard let last = turns.lastIndex(where: { $0.speaker == .them && !$0.text.isEmpty }) else {
            return nil
        }
        var picked = [turns[last]]
        var index = last - 1
        while index >= 0, picked.count < configuration.maxMergedTargetTurns {
            let turn = turns[index]
            if turn.text.isEmpty {
                index -= 1
            } else if turn.speaker == .them {
                picked.insert(turn, at: 0)
                index -= 1
            } else if turn.wordCount <= configuration.backchannelMaxWords {
                index -= 1
            } else {
                break
            }
        }
        return ReplyTarget(
            turnIDs: picked.map(\.id),
            speaker: .them,
            text: picked.map(\.text).joined(separator: " "),
            isLive: picked.contains(where: \.isLive)
        )
    }

    /// The most recent turns that fit the budget, oldest first. Keeps the
    /// prompt size flat no matter how long the meeting runs.
    public func recentTurns(maxTurns: Int = 16, maxCharacters: Int = 3_000) -> [TranscriptTurn] {
        var picked: [TranscriptTurn] = []
        var used = 0
        for turn in turns.reversed() where !turn.text.isEmpty {
            guard picked.count < maxTurns else { break }
            let length = turn.text.count
            if used + length > maxCharacters {
                if picked.isEmpty {
                    var clipped = turn
                    clipped.editedText = "…" + String(turn.text.suffix(maxCharacters))
                    picked.append(clipped)
                }
                break
            }
            used += length
            picked.append(turn)
        }
        return picked.reversed()
    }

    // MARK: - Private

    private func openTurnIndex(for speaker: Speaker) -> Int? {
        guard let id = openTurnIDs[speaker] else { return nil }
        return turns.lastIndex { $0.id == id }
    }

    private mutating func turnIndexForNewText(from speaker: Speaker, now: Date) -> Int {
        if let index = openTurnIndex(for: speaker), turns[index].editedText == nil {
            let turn = turns[index]
            // Still mid-utterance: keep growing it even if the other side talked over.
            if !turn.volatileText.isEmpty { return index }
            let isLast = index == turns.count - 1
            let paused = now.timeIntervalSince(turn.updatedAt) > configuration.maxPauseWithinTurn
            if isLast && !paused { return index }
        }
        let turn = TranscriptTurn(speaker: speaker, startedAt: now)
        turns.append(turn)
        openTurnIDs[speaker] = turn.id
        return turns.count - 1
    }

    private mutating func removeIfEmpty(at index: Int, speaker: Speaker) {
        guard turns[index].text.isEmpty else { return }
        if openTurnIDs[speaker] == turns[index].id { openTurnIDs[speaker] = nil }
        turns.remove(at: index)
    }

    private mutating func pruneEchoReference(now: Date) {
        recentThemText.removeAll { now.timeIntervalSince($0.date) > configuration.echoWindow }
    }

    private func isLikelyEcho(_ text: String, now: Date) -> Bool {
        var reference = recentThemText
            .filter { now.timeIntervalSince($0.date) <= configuration.echoWindow }
            .map(\.text)
        if let index = openTurnIndex(for: .them) {
            reference.append(turns[index].volatileText)
        }
        return EchoFilter.isLikelyEcho(text, reference: reference.joined(separator: " "))
    }
}

/// The text a reply responds to.
public struct ReplyTarget: Equatable, Sendable {
    public var turnIDs: [UUID]
    public var speaker: Speaker
    public var text: String
    /// True when the speaker may still be talking.
    public var isLive: Bool

    public init(turnIDs: [UUID], speaker: Speaker, text: String, isLive: Bool) {
        self.turnIDs = turnIDs
        self.speaker = speaker
        self.text = text
        self.isLive = isLive
    }
}
