import Foundation

/// `cache_control` marker for a content block.
public struct CacheControl: Encodable, Equatable, Sendable {
    public var type = "ephemeral"
    public var ttl: String?

    public init(ttl: String? = nil) { self.ttl = ttl }

    public static let ephemeral = CacheControl()
}

/// A Messages API content block (the subset VibeMeeting sends).
public enum ContentBlock: Encodable, Equatable, Sendable {
    case text(String, cache: CacheControl? = nil)
    case image(base64: String, mediaType: String, cache: CacheControl? = nil)

    enum CodingKeys: String, CodingKey { case type, text, source, cacheControl = "cache_control" }
    enum SourceKeys: String, CodingKey { case type, mediaType = "media_type", data }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let cache):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(cache, forKey: .cacheControl)
        case .image(let data, let mediaType, let cache):
            try container.encode("image", forKey: .type)
            var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try source.encode("base64", forKey: .type)
            try source.encode(mediaType, forKey: .mediaType)
            try source.encode(data, forKey: .data)
            try container.encodeIfPresent(cache, forKey: .cacheControl)
        }
    }

    public var cacheControl: CacheControl? {
        switch self {
        case .text(_, let cache), .image(_, _, let cache): return cache
        }
    }

    public var text: String? {
        if case .text(let text, _) = self { return text }
        return nil
    }

    func withCache(_ cache: CacheControl?) -> ContentBlock {
        switch self {
        case .text(let text, _): return .text(text, cache: cache)
        case .image(let data, let mediaType, _): return .image(base64: data, mediaType: mediaType, cache: cache)
        }
    }
}

public struct ChatMessage: Encodable, Equatable, Sendable {
    public var role: String
    public var content: [ContentBlock]

    public init(role: String, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ content: [ContentBlock]) -> ChatMessage {
        ChatMessage(role: "user", content: content)
    }
}

public struct ThinkingConfig: Encodable, Equatable, Sendable {
    public var type: String

    public static let disabled = ThinkingConfig(type: "disabled")
    public static let adaptive = ThinkingConfig(type: "adaptive")
    /// Claude Sonnet 5.5's way of turning thinking off.
    public static let betweenTools = ThinkingConfig(type: "between_tools")
}

public struct OutputConfig: Encodable, Equatable, Sendable {
    public struct Format: Encodable, Equatable, Sendable {
        public var type = "json_schema"
        public var schema: JSONValue
    }

    public var effort: String?
    public var format: Format?

    public init(effort: String? = nil, jsonSchema: JSONValue? = nil) {
        self.effort = effort
        self.format = jsonSchema.map { Format(schema: $0) }
    }
}

/// Body of `POST /v1/messages`.
public struct MessagesRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: [ContentBlock]
    public var messages: [ChatMessage]
    public var stream: Bool?
    public var thinking: ThinkingConfig?
    public var outputConfig: OutputConfig?
    /// Server-side refusal fallback (`"default"`), only on models that support it.
    public var fallbacks: String?
    /// Sent as the `anthropic-beta` header, not in the body.
    public var betas: [String] = []

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system, messages, stream, thinking
        case outputConfig = "output_config"
        case fallbacks
    }

    public init(
        model: String,
        maxTokens: Int,
        system: [ContentBlock],
        messages: [ChatMessage],
        stream: Bool? = nil,
        thinking: ThinkingConfig? = nil,
        outputConfig: OutputConfig? = nil,
        fallbacks: String? = nil,
        betas: [String] = []
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.stream = stream
        self.thinking = thinking
        self.outputConfig = outputConfig
        self.fallbacks = fallbacks
        self.betas = betas
    }

    /// Deterministic JSON so identical prompts produce identical bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Number of `cache_control` breakpoints (the API allows at most 4).
    public var cacheBreakpointCount: Int {
        (system + messages.flatMap(\.content)).filter { $0.cacheControl != nil }.count
    }
}
