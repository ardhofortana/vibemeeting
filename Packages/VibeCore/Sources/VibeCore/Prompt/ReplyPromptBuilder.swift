import Foundation

/// Everything that stays the same for a whole meeting (layers 1–4).
public struct MeetingPromptContext: Equatable, Sendable {
    public var aboutMe: String
    public var context: [ContextItem]
    public var preset: StylePreset
    public var meetingInstructions: String
    /// What the user wants from the meeting (empty when not set).
    public var goal: String

    public init(aboutMe: String, context: [ContextItem], preset: StylePreset, meetingInstructions: String, goal: String = "") {
        self.aboutMe = aboutMe
        self.context = context
        self.preset = preset
        self.meetingInstructions = meetingInstructions
        self.goal = goal
    }
}

/// What an Ask questions request needs (the transcript and an optional steer).
public struct QuestionsAsk: Equatable, Sendable {
    public var recentTurns: [TranscriptTurn]
    public var earlierChunks: [[TranscriptTurn]]
    public var steer: String
    /// Questions shown before, when asking for different ones.
    public var previousQuestions: String?

    public init(recentTurns: [TranscriptTurn], earlierChunks: [[TranscriptTurn]] = [], steer: String = "", previousQuestions: String? = nil) {
        self.recentTurns = recentTurns
        self.earlierChunks = earlierChunks
        self.steer = steer
        self.previousQuestions = previousQuestions
    }
}

/// What a single Reply asks for (the transcript and layers 5–6).
public struct ReplyAsk: Equatable, Sendable {
    public var target: ReplyTarget
    public var recentTurns: [TranscriptTurn]
    /// Older closed turns in fixed chunks (see `TranscriptStore.replyTranscript`).
    public var earlierChunks: [[TranscriptTurn]]
    public var intent: ReplyIntent
    public var steer: String
    public var variant: ReplyVariant
    /// The script being regenerated or shortened.
    public var previousScript: String?

    public init(
        target: ReplyTarget,
        recentTurns: [TranscriptTurn],
        earlierChunks: [[TranscriptTurn]] = [],
        intent: ReplyIntent = .auto,
        steer: String = "",
        variant: ReplyVariant = .fresh,
        previousScript: String? = nil
    ) {
        self.target = target
        self.recentTurns = recentTurns
        self.earlierChunks = earlierChunks
        self.intent = intent
        self.steer = steer
        self.variant = variant
        self.previousScript = previousScript
    }
}

/// Builds Reply requests ordered from most static to most dynamic, so layers
/// 1–4 are served from the prompt cache for the whole meeting.
///
/// Layout:
/// - system: output rules, About me ← breakpoint (shared by every meeting)
/// - user: meeting context ← breakpoint, reply style and goal ← breakpoint, the earlier
///   transcript one block per chunk ← breakpoint on the last chunk, then the
///   uncached recent transcript and request.
///
/// A new transcript chunk only appends a block, so the cache written by the
/// previous reply is still a prefix and is found by the cache lookback.
public struct ReplyPromptBuilder: Sendable {
    public var model: ClaudeModel
    public var maxTokens: Int

    public init(model: ClaudeModel, maxTokens: Int = 2_048) {
        self.model = model
        self.maxTokens = maxTokens
    }

    public func request(meeting: MeetingPromptContext, ask: ReplyAsk) -> MessagesRequest {
        var content = cachedMeetingBlocks(meeting)
        content += Self.earlierTranscriptBlocks(ask.earlierChunks)
        content.append(.text(Self.askText(ask, preset: meeting.preset)))
        return baseRequest(meeting: meeting, userContent: content, stream: true, maxTokens: maxTokens)
    }

    /// Questions the user can ask the other side. Same model, settings and cached
    /// prefix as a reply (a fork of it), so it's as fast; only the tail differs.
    public func questionsRequest(meeting: MeetingPromptContext, ask: QuestionsAsk) -> MessagesRequest {
        var content = cachedMeetingBlocks(meeting)
        content += Self.earlierTranscriptBlocks(ask.earlierChunks)
        content.append(.text(Self.questionsText(ask)))
        return baseRequest(meeting: meeting, userContent: content, stream: true, maxTokens: maxTokens)
    }

    /// A `max_tokens: 0` request that writes layers 1–4 (and the earlier
    /// transcript) to the cache without generating anything. Same model, thinking
    /// and effort as real replies.
    public func warmupRequest(meeting: MeetingPromptContext, earlierChunks: [[TranscriptTurn]] = []) -> MessagesRequest {
        var content = cachedMeetingBlocks(meeting)
        content += Self.earlierTranscriptBlocks(earlierChunks)
        content.append(.text("warmup"))
        return baseRequest(meeting: meeting, userContent: content, stream: nil, maxTokens: 0)
    }

    // MARK: - Layers

    func systemBlocks(aboutMe: String) -> [ContentBlock] {
        let profile = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            .text(Prompts.replyRules),
            .text("<about_me>\n\(profile.isEmpty ? Prompts.emptyAboutMe : profile)\n</about_me>", cache: .ephemeral),
        ]
    }

    func cachedMeetingBlocks(_ meeting: MeetingPromptContext) -> [ContentBlock] {
        var blocks = Self.contextBlocks(meeting.context)
        blocks[blocks.count - 1] = blocks[blocks.count - 1].withCache(.ephemeral)
        blocks.append(.text(Self.styleText(preset: meeting.preset, meetingInstructions: meeting.meetingInstructions, goal: meeting.goal), cache: .ephemeral))
        return blocks
    }

    private func baseRequest(meeting: MeetingPromptContext, userContent: [ContentBlock], stream: Bool?, maxTokens: Int) -> MessagesRequest {
        MessagesRequest(
            model: model.id,
            maxTokens: maxTokens,
            system: systemBlocks(aboutMe: meeting.aboutMe),
            messages: [.user(userContent)],
            stream: stream,
            thinking: model.replyThinking,
            outputConfig: model.replyEffort.map { OutputConfig(effort: $0) }
        )
    }

    /// Meeting context as content blocks: one text block with every document,
    /// then each image after its label, then a closing tag.
    static func contextBlocks(_ items: [ContextItem]) -> [ContentBlock] {
        let documents = items.compactMap { item -> String? in
            guard let text = item.textValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return "<document title=\"\(escapeAttribute(item.title))\">\n\(text)\n</document>"
        }
        let images = items.filter(\.isImage)

        if documents.isEmpty && images.isEmpty {
            return [.text("<meeting_context>\n\(Prompts.emptyContext)\n</meeting_context>")]
        }

        var blocks: [ContentBlock] = []
        var opening = "<meeting_context>"
        if !documents.isEmpty { opening += "\n" + documents.joined(separator: "\n\n") }
        for image in images {
            guard case .image(let data, let mediaType, _, _) = image.content else { continue }
            blocks.append(.text(opening + "\n<screenshot title=\"\(escapeAttribute(image.title))\">"))
            opening = "</screenshot>"
            blocks.append(.image(base64: data.base64EncodedString(), mediaType: mediaType))
        }
        blocks.append(.text(opening + "\n</meeting_context>"))
        return blocks
    }

    static func styleText(preset: StylePreset, meetingInstructions: String, goal: String = "") -> String {
        var text = """
        <reply_style name="\(escapeAttribute(preset.name))">
        \(preset.instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        Length: \(preset.minSentences == preset.maxSentences ? "\(preset.minSentences)" : "\(preset.minSentences) to \(preset.maxSentences)") sentence\(preset.maxSentences == 1 ? "" : "s").
        </reply_style>
        """
        let extra = meetingInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            text += "\n<meeting_instructions>\n\(extra)\n</meeting_instructions>"
        }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty {
            text += "\n<meeting_goal>\n\(goal)\n</meeting_goal>"
        }
        return text
    }

    /// The older transcript, one text block per chunk, cached at the last one.
    /// Each block ends with a newline so lines never run together.
    static func earlierTranscriptBlocks(_ chunks: [[TranscriptTurn]]) -> [ContentBlock] {
        guard !chunks.isEmpty else { return [] }
        var blocks = chunks.enumerated().map { index, chunk in
            let lines = chunk.map(transcriptLine).joined(separator: "\n") + "\n"
            return ContentBlock.text(index == 0 ? "<earlier_transcript>\n" + lines : lines)
        }
        blocks[blocks.count - 1] = blocks[blocks.count - 1].withCache(.ephemeral)
        return blocks
    }

    static func transcriptLine(_ turn: TranscriptTurn) -> String {
        "\(turn.speaker.label): \(turn.text)\(turn.isLive ? " …" : "")"
    }

    /// The recent turns, closing the earlier transcript when there is one.
    static func recentTranscriptText(_ turns: [TranscriptTurn], afterEarlier: Bool) -> String {
        let lines = turns.map(transcriptLine)
        let closing = afterEarlier ? "</earlier_transcript>\n\n" : ""
        return closing + "<recent_transcript>\n\(lines.isEmpty ? "(nothing yet)" : lines.joined(separator: "\n"))\n</recent_transcript>"
    }

    /// The tail of an Ask questions request.
    static func questionsText(_ ask: QuestionsAsk) -> String {
        var parts = [recentTranscriptText(ask.recentTurns, afterEarlier: !ask.earlierChunks.isEmpty)]
        let steer = ask.steer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !steer.isEmpty {
            parts.append("<steer>\n\(steer)\n</steer>")
        }
        if let previous = ask.previousQuestions?.trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty {
            parts.append("<previous_questions>\n\(previous)\n</previous_questions>\nThe user wants different questions from these.")
        }
        parts.append(Prompts.questionsTask)
        return parts.joined(separator: "\n\n")
    }

    /// Layers 5 and 6: the recent transcript and the request itself.
    static func askText(_ ask: ReplyAsk, preset: StylePreset) -> String {
        var parts: [String] = []

        parts.append(recentTranscriptText(ask.recentTurns, afterEarlier: !ask.earlierChunks.isEmpty))

        var target = "<target speaker=\"\(ask.target.speaker.label)\">\n\(ask.target.text)\n</target>"
        if ask.target.isLive {
            target += "\nThey may still be talking. This is what they have said so far."
        }
        if ask.target.speaker == .you {
            target += "\nThe target is the user's own line. Write what the user should say next to build on it or put it better."
        }
        parts.append(target)

        parts.append("<move>\n\(ask.intent.instruction)\n</move>")

        let steer = ask.steer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !steer.isEmpty {
            parts.append("<steer>\n\(steer)\n</steer>")
        }

        if let previous = ask.previousScript?.trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty {
            parts.append("<previous_script>\n\(previous)\n</previous_script>")
            switch ask.variant {
            case .shorter:
                let limit = shorterSentenceLimit(previous: previous, preset: preset)
                parts.append("Rewrite the previous script shorter, in at most \(limit) sentence\(limit == 1 ? "" : "s"). Keep its main point, any numbers, any [confirm number] marker, and the natural way it's spoken: trim it, don't polish it into a summary.")
            case .regenerate:
                parts.append("Write a new version with a different angle or wording. Don't reuse its first sentence or the way it opens.")
            case .fresh:
                parts.append("Write the script now.")
            }
        } else {
            parts.append("Write the script now.")
        }
        return parts.joined(separator: "\n\n")
    }

    static func shorterSentenceLimit(previous: String, preset: StylePreset) -> Int {
        let count = ScriptText.sentences(in: previous).count
        return max(1, min(preset.minSentences, count - 1))
    }

    static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
