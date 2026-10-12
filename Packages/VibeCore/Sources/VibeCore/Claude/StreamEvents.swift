import Foundation

/// Incremental parser for the Messages API server-sent events stream.
///
/// Each Anthropic event carries exactly one `data:` line, so an event is
/// emitted as soon as its data line arrives. That keeps the parser correct
/// even when the line reader drops blank separator lines.
public struct SSEParser: Sendable {
    public struct Event: Equatable, Sendable {
        public var name: String?
        public var data: String
    }

    private var pendingName: String?

    public init() {}

    public mutating func consume(line rawLine: String) -> Event? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            pendingName = nil
            return nil
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            pendingName = Self.value(of: line, field: "event:")
            return nil
        }
        if line.hasPrefix("data:") {
            let event = Event(name: pendingName, data: Self.value(of: line, field: "data:"))
            pendingName = nil
            return event
        }
        return nil
    }

    private static func value(of line: String, field: String) -> String {
        var value = line.dropFirst(field.count)
        if value.first == " " { value = value.dropFirst() }
        return String(value)
    }
}

/// What a streaming reply produces, in order.
public enum ReplyStreamEvent: Equatable, Sendable {
    /// The request was accepted. Carries prompt usage, including cache reads.
    case started(model: String, usage: TokenUsage)
    case textDelta(String)
    /// A server-side fallback took over after a refusal mid-stream: drop the
    /// text received so far, the fallback model starts over.
    case discardPartialOutput
    /// Generation ended. `usage` combines prompt and output tokens.
    case finished(stopReason: String?, usage: TokenUsage)
}

/// Decodes one SSE data payload into zero or more stream events.
public struct MessageStreamDecoder: Sendable {
    private var usage = TokenUsage()
    private var model = ""
    private var textBlockIndexes: Set<Int> = []

    public init() {}

    public mutating func decode(_ event: SSEParser.Event) throws -> [ReplyStreamEvent] {
        guard let data = event.data.data(using: .utf8) else { return [] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)

        switch payload.type {
        case "message_start":
            if let message = payload.message {
                model = message.model ?? ""
                usage = message.usage?.tokenUsage ?? TokenUsage()
            }
            return [.started(model: model, usage: usage)]

        case "content_block_start":
            if payload.contentBlock?.type == "fallback" {
                textBlockIndexes.removeAll()
                return [.discardPartialOutput]
            }
            if let index = payload.index, payload.contentBlock?.type == "text" {
                textBlockIndexes.insert(index)
                if let text = payload.contentBlock?.text, !text.isEmpty {
                    return [.textDelta(text)]
                }
            }
            return []

        case "content_block_delta":
            guard let delta = payload.delta, delta.type == "text_delta", let text = delta.text else { return [] }
            if let index = payload.index, !textBlockIndexes.isEmpty, !textBlockIndexes.contains(index) {
                return []
            }
            return [.textDelta(text)]

        case "message_delta":
            if let usageDelta = payload.usage {
                if let output = usageDelta.outputTokens { usage.outputTokens = output }
                // Some fields can be restated in message_delta; take them when present.
                if let input = usageDelta.inputTokens { usage.inputTokens = input }
                if let created = usageDelta.cacheCreationInputTokens { usage.cacheCreationInputTokens = created }
                if let read = usageDelta.cacheReadInputTokens { usage.cacheReadInputTokens = read }
            }
            if let stopReason = payload.delta?.stopReason {
                return [.finished(stopReason: stopReason, usage: usage)]
            }
            return []

        case "error":
            throw ClaudeError.api(
                status: nil,
                type: payload.error?.type ?? "error",
                message: payload.error?.message ?? "Stream error"
            )

        default:
            // message_stop, content_block_stop, ping, and future event types.
            return []
        }
    }

    // MARK: - Wire types

    struct Payload: Decodable {
        var type: String
        var index: Int?
        var message: MessageInfo?
        var contentBlock: Block?
        var delta: Delta?
        var usage: UsagePayload?
        var error: ErrorInfo?

        enum CodingKeys: String, CodingKey {
            case type, index, message, delta, usage, error
            case contentBlock = "content_block"
        }
    }

    struct MessageInfo: Decodable {
        var model: String?
        var usage: UsagePayload?
    }

    struct Block: Decodable {
        var type: String
        var text: String?
    }

    struct Delta: Decodable {
        var type: String?
        var text: String?
        var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case stopReason = "stop_reason"
        }
    }

    struct ErrorInfo: Decodable {
        var type: String?
        var message: String?
    }
}

/// `usage` object as it appears on the wire.
struct UsagePayload: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens ?? 0,
            outputTokens: outputTokens ?? 0,
            cacheCreationInputTokens: cacheCreationInputTokens ?? 0,
            cacheReadInputTokens: cacheReadInputTokens ?? 0
        )
    }
}
