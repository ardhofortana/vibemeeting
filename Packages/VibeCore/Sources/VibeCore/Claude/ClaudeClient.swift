import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClaudeError: Error, Equatable, LocalizedError, Sendable {
    case missingAPIKey
    case http(status: Int, body: String)
    case api(status: Int?, type: String, message: String)
    case refusal(category: String?)
    case invalidResponse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key. Add your Claude API key in Settings."
        case .http(let status, _):
            return "Claude API returned HTTP \(status)."
        case .api(let status, let type, let message):
            return "Claude API error\(status.map { " \($0)" } ?? "") (\(type)): \(message)"
        case .refusal:
            return "Claude declined to draft this reply."
        case .invalidResponse(let detail):
            return "Unexpected response from Claude: \(detail)"
        case .transport(let detail):
            return "Network error: \(detail)"
        }
    }

    /// Worth retrying as is (rate limits, overload, network).
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _): return status == 408 || status == 429 || status >= 500
        case .api(let status, let type, _):
            return type == "overloaded_error" || type == "rate_limit_error" || type == "api_error" || (status ?? 0) >= 500
        case .transport: return true
        default: return false
        }
    }

    /// The key itself is the problem.
    public var isAuthenticationFailure: Bool {
        switch self {
        case .missingAPIKey: return true
        case .http(let status, _): return status == 401 || status == 403
        case .api(let status, let type, _): return status == 401 || status == 403 || type == "authentication_error" || type == "permission_error"
        default: return false
        }
    }
}

/// Moves bytes for the client. Swappable for tests.
public protocol ClaudeTransport: Sendable {
    /// Streams the response body line by line. Throws `ClaudeError` for non-2xx responses.
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error>
    /// Sends a request and returns the whole body. Throws `ClaudeError` for non-2xx responses.
    func data(for request: URLRequest) async throws -> Data
}

/// Minimal Claude Messages API client over raw HTTP (there is no official Swift SDK).
public struct ClaudeClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let apiVersion = "2023-06-01"

    public var apiKey: String
    public var baseURL: URL
    public var transport: ClaudeTransport

    public init(apiKey: String, baseURL: URL = ClaudeClient.defaultBaseURL, transport: ClaudeTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport
    }

    public func urlRequest(for body: MessagesRequest) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClaudeError.missingAPIKey }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !body.betas.isEmpty {
            request.setValue(body.betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try body.encoded()
        return request
    }

    /// Streams a reply. The request must have `stream: true`.
    public func stream(_ body: MessagesRequest) -> AsyncThrowingStream<ReplyStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try urlRequest(for: body)
                    var parser = SSEParser()
                    var decoder = MessageStreamDecoder()
                    var finished = false
                    for try await line in transport.lines(for: request) {
                        guard let event = parser.consume(line: line) else { continue }
                        for output in try decoder.decode(event) {
                            if case .finished = output { finished = true }
                            continuation.yield(output)
                        }
                    }
                    if !finished {
                        throw ClaudeError.invalidResponse("stream ended early")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams a request and collects the text. Used for the recap.
    public func complete(_ body: MessagesRequest) async throws -> (text: String, stopReason: String?, usage: TokenUsage) {
        var streaming = body
        streaming.stream = true
        var text = ""
        var stopReason: String?
        var usage = TokenUsage()
        for try await event in stream(streaming) {
            switch event {
            case .started(_, let started): usage = started
            case .textDelta(let delta): text += delta
            case .discardPartialOutput: text = ""
            case .finished(let reason, let final):
                stopReason = reason
                usage = final
            }
        }
        if stopReason == "refusal" { throw ClaudeError.refusal(category: nil) }
        return (text, stopReason, usage)
    }

    /// Sends a `max_tokens: 0` request to write the prompt cache. Returns the usage.
    @discardableResult
    public func warm(_ body: MessagesRequest) async throws -> TokenUsage {
        var warmup = body
        warmup.stream = nil
        warmup.maxTokens = 0
        do {
            let data = try await transport.data(for: try urlRequest(for: warmup))
            struct Response: Decodable { var usage: UsagePayload? }
            let response = try JSONDecoder().decode(Response.self, from: data)
            return response.usage?.tokenUsage ?? TokenUsage()
        } catch {
            throw Self.normalize(error)
        }
    }

    static func normalize(_ error: Error) -> Error {
        if error is ClaudeError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return ClaudeError.transport(urlError.localizedDescription)
        }
        if error is DecodingError { return ClaudeError.invalidResponse(String(describing: error)) }
        return ClaudeError.transport(error.localizedDescription)
    }

    /// Turns an error response body into a `ClaudeError`.
    public static func error(status: Int, body: Data) -> ClaudeError {
        struct Envelope: Decodable {
            struct Info: Decodable { var type: String?; var message: String? }
            var error: Info?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body), let info = envelope.error {
            return .api(status: status, type: info.type ?? "error", message: info.message ?? "")
        }
        return .http(status: status, body: String(decoding: body.prefix(2_000), as: UTF8.self))
    }
}
