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
        /// How long a "You" segment stays open to removal as echo when the
        /// "Them" recognizer delivers the same words after it.
        public var lateEchoWindow: TimeInterval
        /// The same for garbled echo, for segments heard while "Them" was
        /// talking: the mic recognizer can close its garbled copy several
        /// seconds before the "Them" recognizer settles that sentence. Only
        /// garbled runs count this late, so them repeating the user's words
        /// back isn't taken for echo.
        public var lateGarbledEchoWindow: TimeInterval
        /// "You" turns at or under this many words don't break up a "Them" turn
        /// when choosing the reply target ("yeah", "mm-hmm", "right").
        public var backchannelMaxWords: Int
        /// Most "Them" turns merged into one reply target.
        public var maxMergedTargetTurns: Int

        public init(
            maxPauseWithinTurn: TimeInterval = 6,
            echoWindow: TimeInterval = 12,
            lateEchoWindow: TimeInterval = 2.5,
            lateGarbledEchoWindow: TimeInterval = 8,
            backchannelMaxWords: Int = 3,
            maxMergedTargetTurns: Int = 4
        ) {
            self.maxPauseWithinTurn = maxPauseWithinTurn
            self.echoWindow = echoWindow
            self.lateEchoWindow = lateEchoWindow
            self.lateGarbledEchoWindow = lateGarbledEchoWindow
            self.backchannelMaxWords = backchannelMaxWords
            self.maxMergedTargetTurns = maxMergedTargetTurns
        }
    }

    public private(set) var turns: [TranscriptTurn]
    public var configuration: Configuration
    private var openTurnIDs: [Speaker: UUID] = [:]
    private var recentThemText: [(date: Date, text: String)] = []
    /// "You" segments finalized in the last moments, checked again when the
    /// "Them" text they may have echoed arrives after them.
    private var recentYouSegments: [YouSegment] = []
    /// Number of "You" segments dropped, in whole or in part, as speaker echo,
    /// for diagnostics.
    public private(set) var droppedEchoSegments = 0

    private struct YouSegment: Sendable {
        var date: Date
        var turnID: UUID
        var text: String
        /// "Them" was talking then, so it may be their words garbled.
        var heardOverThem: Bool
        /// Already counted in `droppedEchoSegments`.
        var counted: Bool
    }

    public init(turns: [TranscriptTurn] = [], configuration: Configuration = Configuration()) {
        self.turns = turns
        self.configuration = configuration
    }

    public static func == (lhs: TranscriptStore, rhs: TranscriptStore) -> Bool {
        lhs.turns == rhs.turns && lhs.openTurnIDs == rhs.openTurnIDs
    }

    // MARK: - Recognizer input

    public mutating func apply(_ update: TranscriptUpdate, at now: Date = Date()) {
        var text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Their words heard again through the mic: only the user's own words
        // stay. Live text is filtered too, so a double never flashes up.
        var countedEcho = false
        if speaker == .you, let kept = removingEcho(from: text, kind: update.kind, now: now) {
            if update.kind == .final {
                droppedEchoSegments += 1
                countedEcho = true
            }
            guard !kept.isEmpty else {
                if let index = openTurnIndex(for: speaker) {
                    turns[index].volatileText = ""
                    removeIfEmpty(at: index, speaker: speaker)
                }
                return
            }
            text = kept
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

        if speaker == .them {
            removeLateEchoes(now: now, themFinal: update.kind == .final)
        } else if update.kind == .final {
            pruneRecentYouSegments(now: now)
            let heardOverThem = themIsTalking(now: now, within: configuration.lateEchoWindow)
            recentYouSegments.append(YouSegment(date: now, turnID: turns[index].id, text: text, heardOverThem: heardOverThem, counted: countedEcho))
        }
    }

    /// `text` from the mic without what echoes "Them": nil when none of it does.
    /// Garbled runs only count while they're talking or just were (a user
    /// reading their words back afterwards isn't the speakers), and short ones
    /// too in live text while they're talking.
    private func removingEcho(from text: String, kind: TranscriptUpdate.Kind, now: Date) -> String? {
        let reference = echoReference(now: now)
        guard themIsTalking(now: now, within: configuration.lateEchoWindow) else {
            return EchoFilter.isLikelyEcho(text, reference: reference) ? "" : nil
        }
        let live = kind == .volatile && themIsTalking(now: now, within: 0)
        return EchoFilter.removingEcho(from: text, reference: reference, live: live)
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

    /// Everything said so far, for a reply: closed turns in fixed-size chunks
    /// (a complete chunk never changes, so it can be cached across replies), then
    /// the latest turns. Very long meetings drop their oldest chunks.
    public func replyTranscript(
        chunkSize: Int = 12,
        keepRecent: Int = 8,
        maxEarlierCharacters: Int = 60_000,
        maxTurnCharacters: Int = 4_000
    ) -> ReplyTranscript {
        let size = max(1, chunkSize)
        let spoken = turns.filter { !$0.text.isEmpty }.map { Self.clipped($0, to: maxTurnCharacters) }
        var frozen = max(0, spoken.count - keepRecent) / size * size
        // A turn still being spoken stays recent, with everything after it.
        if let live = spoken[..<frozen].firstIndex(where: \.isLive) {
            frozen = live / size * size
        }
        var chunks = stride(from: 0, to: frozen, by: size).map { Array(spoken[$0..<($0 + size)]) }
        var characters = chunks.reduce(0) { $0 + Self.characters(in: $1) }
        while characters > maxEarlierCharacters, !chunks.isEmpty {
            characters -= Self.characters(in: chunks.removeFirst())
        }
        return ReplyTranscript(earlierChunks: chunks, recentTurns: Array(spoken[frozen...]))
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

    /// What "Them" said recently, including what they're saying right now.
    private func echoReference(now: Date) -> String {
        var reference = recentThemText
            .filter { now.timeIntervalSince($0.date) <= configuration.echoWindow }
            .map(\.text)
        if let index = openTurnIndex(for: .them) {
            reference.append(turns[index].volatileText)
        }
        return reference.joined(separator: " ")
    }

    /// What "Them" said in turns that had begun by `date`. Bleed is instant, so
    /// a garbled copy can only be of words they had started saying by then; a
    /// later turn of theirs repeating the user's answer is not its source.
    private func themText(startedBy date: Date, now: Date) -> String {
        turns
            .filter { $0.speaker == .them && $0.startedAt <= date && now.timeIntervalSince($0.updatedAt) <= configuration.echoWindow }
            .map(\.text)
            .joined(separator: " ")
    }

    /// Whether "Them" is talking, or was within `window`, so the mic may carry their voice.
    private func themIsTalking(now: Date, within window: TimeInterval) -> Bool {
        guard let turn = turns.last(where: { $0.speaker == .them }) else { return false }
        return turn.isLive || now.timeIntervalSince(turn.updatedAt) <= window
    }

    /// Forgets "You" segments too old for a late echo check.
    private mutating func pruneRecentYouSegments(now: Date) {
        let configuration = configuration
        recentYouSegments.removeAll { segment in
            let age = now.timeIntervalSince(segment.date)
            return age > configuration.lateEchoWindow
                && !(segment.heardOverThem && age <= configuration.lateGarbledEchoWindow)
        }
    }

    /// The "Them" recognizer can deliver a phrase after the "You" recognizer did.
    /// Check the "You" segments of the last moments again whenever their text
    /// changes and cut out what turns out to be echo: near-verbatim copies only
    /// briefly and only against their finished text (when they repeat the
    /// user's words later, that's not echo), garbled runs only in segments heard
    /// while they were talking, a little longer, and after the first moments
    /// only against what they had started saying by then.
    private mutating func removeLateEchoes(now: Date, themFinal: Bool) {
        pruneRecentYouSegments(now: now)
        guard !recentYouSegments.isEmpty else { return }
        let reference = echoReference(now: now)
        var kept: [YouSegment] = []
        for var segment in recentYouSegments {
            let isRecent = now.timeIntervalSince(segment.date) <= configuration.lateEchoWindow
            let garbledReference = isRecent ? reference : themText(startedBy: segment.date.addingTimeInterval(1), now: now)
            var echoFree = segment.heardOverThem ? EchoFilter.removingGarbledEcho(from: segment.text, reference: garbledReference) : nil
            if echoFree == nil, themFinal, isRecent, EchoFilter.isLikelyEcho(segment.text, reference: reference) {
                echoFree = ""
            }
            guard let remaining = echoFree,
                  let index = turns.firstIndex(where: { $0.id == segment.turnID }),
                  turns[index].editedText == nil,
                  let range = turns[index].finalText.range(of: segment.text, options: .backwards)
            else {
                kept.append(segment)
                continue
            }
            var finalText = turns[index].finalText
            finalText.replaceSubrange(range, with: remaining)
            turns[index].finalText = finalText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !segment.counted {
                droppedEchoSegments += 1
                segment.counted = true
            }
            if remaining.isEmpty {
                removeIfEmpty(at: index, speaker: .you)
            } else {
                segment.text = remaining
                kept.append(segment)
            }
        }
        recentYouSegments = kept
    }

    private static func clipped(_ turn: TranscriptTurn, to limit: Int) -> TranscriptTurn {
        guard turn.text.count > limit else { return turn }
        var clipped = turn
        clipped.editedText = "…" + String(turn.text.suffix(limit))
        return clipped
    }

    private static func characters(in turns: [TranscriptTurn]) -> Int {
        turns.reduce(0) { $0 + $1.text.count }
    }
}

/// The transcript a reply sees. See `TranscriptStore.replyTranscript`.
public struct ReplyTranscript: Equatable, Sendable {
    /// Closed turns in fixed-size chunks, oldest first.
    public var earlierChunks: [[TranscriptTurn]]
    /// The latest turns, including any still being spoken.
    public var recentTurns: [TranscriptTurn]

    public init(earlierChunks: [[TranscriptTurn]] = [], recentTurns: [TranscriptTurn]) {
        self.earlierChunks = earlierChunks
        self.recentTurns = recentTurns
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
