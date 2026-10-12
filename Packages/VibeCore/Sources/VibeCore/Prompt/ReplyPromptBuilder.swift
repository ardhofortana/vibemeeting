import Foundation

/// Everything that stays the same for a whole meeting (layers 1–4).
public struct MeetingPromptContext: Equatable, Sendable {
    public var aboutMe: String
    public var context: [ContextItem]
    public var preset: StylePreset
    public var meetingInstructions: String

    public init(aboutMe: String, context: [ContextItem], preset: StylePreset, meetingInstructions: String) {
        self.aboutMe = aboutMe
        self.context = context
        self.preset = preset
        self.meetingInstructions = meetingInstructions
    }
}

/// What a single Reply asks for (layers 5–6).
public struct ReplyAsk: Equatable, Sendable {
    public var target: ReplyTarget
    public var recentTurns: [TranscriptTurn]
    public var intent: ReplyIntent
    public var steer: String
    public var variant: ReplyVariant
    /// The script being regenerated or shortened.
    public var previousScript: String?

    public init(
        target: ReplyTarget,
        recentTurns: [TranscriptTurn],
        intent: ReplyIntent = .auto,
        steer: String = "",
        variant: ReplyVariant = .fresh,
        previousScript: String? = nil
    ) {
        self.target = target
        self.recentTurns = recentTurns
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
/// - user: meeting context ← breakpoint, reply style ← breakpoint, then the
///   uncached transcript window and request.
public struct ReplyPromptBuilder: Sendable {
    public var model: ClaudeModel
    public var maxTokens: Int

    public init(model: ClaudeModel, maxTokens: Int = 2_048) {
        self.model = model
        self.maxTokens = maxTokens
    }

    public func request(meeting: MeetingPromptContext, ask: ReplyAsk) -> MessagesRequest {
        var content = cachedMeetingBlocks(meeting)
        content.append(.text(Self.askText(ask, preset: meeting.preset)))
        return baseRequest(meeting: meeting, userContent: content, stream: true, maxTokens: maxTokens)
    }

    /// A `max_tokens: 0` request that writes layers 1–4 to the cache without
    /// generating anything. Same model, thinking and effort as real replies.
    public func warmupRequest(meeting: MeetingPromptContext) -> MessagesRequest {
        var content = cachedMeetingBlocks(meeting)
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
        blocks.append(.text(Self.styleText(preset: meeting.preset, meetingInstructions: meeting.meetingInstructions), cache: .ephemeral))
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

    static func styleText(preset: StylePreset, meetingInstructions: String) -> String {
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
        return text
    }

    /// Layers 5 and 6: the transcript window and the request itself.
    static func askText(_ ask: ReplyAsk, preset: StylePreset) -> String {
        var parts: [String] = []

        let lines = ask.recentTurns.map { turn in
            "\(turn.speaker.label): \(turn.text)\(turn.isLive ? " …" : "")"
        }
        parts.append("<recent_transcript>\n\(lines.isEmpty ? "(nothing yet)" : lines.joined(separator: "\n"))\n</recent_transcript>")

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
                parts.append("Rewrite the previous script shorter, in at most \(limit) sentence\(limit == 1 ? "" : "s"). Keep its main point, any numbers, and any [confirm number] marker.")
            case .regenerate:
                parts.append("Write a new version with a different angle or wording. Don't reuse its first sentence.")
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
