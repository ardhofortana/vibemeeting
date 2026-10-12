import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VibeCore

/// Replays canned responses and records requests.
final class MockTransport: ClaudeTransport, @unchecked Sendable {
    var streamLines: [String] = []
    var streamError: Error?
    var dataResponse: Result<Data, Error> = .success(Data())
    private(set) var requests: [URLRequest] = []

    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        let lines = streamLines
        let error = streamError
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish(throwing: error)
        }
    }

    func data(for request: URLRequest) async throws -> Data {
        requests.append(request)
        return try dataResponse.get()
    }
}

final class ClaudeClientTests: XCTestCase {
    static let sampleStream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[],"usage":{"input_tokens":120,"cache_creation_input_tokens":0,"cache_read_input_tokens":3400,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: ping
    data: {"type":"ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"It usually lands"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" in the range from the proposal."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":14}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    func makeRequest() -> MessagesRequest {
        MessagesRequest(model: "claude-haiku-5-5", maxTokens: 100, system: [.text("rules")], messages: [.user([.text("hi")])], stream: true, betas: ["beta-a", "beta-b"])
    }

    func testStreamDecodesTextAndUsage() async throws {
        let transport = MockTransport()
        transport.streamLines = Self.sampleStream.components(separatedBy: "\n")
        let client = ClaudeClient(apiKey: "sk-test", transport: transport)

        var text = ""
        var started: TokenUsage?
        var finished: (String?, TokenUsage)?
        for try await event in client.stream(makeRequest()) {
            switch event {
            case .started(let model, let usage):
                XCTAssertEqual(model, "claude-haiku-5-5")
                started = usage
            case .textDelta(let delta): text += delta
            case .discardPartialOutput: XCTFail("unexpected")
            case .finished(let reason, let usage): finished = (reason, usage)
            }
        }
        XCTAssertEqual(text, "It usually lands in the range from the proposal.")
        XCTAssertEqual(started?.cacheReadInputTokens, 3400)
        XCTAssertEqual(finished?.0, "end_turn")
        XCTAssertEqual(finished?.1.outputTokens, 14)
        XCTAssertEqual(finished?.1.inputTokens, 120)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "beta-a,beta-b")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        let body = try XCTUnwrap(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertNil(body["betas"], "betas go in the header, not the body")
    }

    func testStreamWorksWithoutBlankLines() async throws {
        let transport = MockTransport()
        transport.streamLines = Self.sampleStream.components(separatedBy: "\n").filter { !$0.isEmpty }
        let client = ClaudeClient(apiKey: "sk-test", transport: transport)
        var text = ""
        for try await event in client.stream(makeRequest()) {
            if case .textDelta(let delta) = event { text += delta }
        }
        XCTAssertEqual(text, "It usually lands in the range from the proposal.")
    }

    func testThinkingDeltasAreIgnoredAndFallbackResets() throws {
        var decoder = MessageStreamDecoder()
        func decode(_ json: String) throws -> [ReplyStreamEvent] {
            try decoder.decode(SSEParser.Event(name: nil, data: json))
        }
        XCTAssertEqual(try decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#), [])
        XCTAssertEqual(try decode(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#), [])
        XCTAssertEqual(try decode(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#), [])
        XCTAssertEqual(try decode(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"partial"}}"#), [.textDelta("partial")])
        XCTAssertEqual(try decode(#"{"type":"content_block_start","index":2,"content_block":{"type":"fallback"}}"#), [.discardPartialOutput])
        XCTAssertEqual(try decode(#"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#), [])
        XCTAssertEqual(try decode(#"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"full"}}"#), [.textDelta("full")])
    }

    func testStreamErrorEventThrows() async {
        let transport = MockTransport()
        transport.streamLines = [
            "event: error",
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ]
        let client = ClaudeClient(apiKey: "sk-test", transport: transport)
        do {
            for try await _ in client.stream(makeRequest()) {}
            XCTFail("expected error")
        } catch let error as ClaudeError {
            XCTAssertEqual(error, .api(status: nil, type: "overloaded_error", message: "Overloaded"))
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTruncatedStreamThrows() async {
        let transport = MockTransport()
        transport.streamLines = Array(Self.sampleStream.components(separatedBy: "\n").prefix(8))
        let client = ClaudeClient(apiKey: "sk-test", transport: transport)
        do {
            for try await _ in client.stream(makeRequest()) {}
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .invalidResponse("stream ended early"))
        }
    }

    func testMissingKeyFails() async {
        let client = ClaudeClient(apiKey: "  ", transport: MockTransport())
        do {
            for try await _ in client.stream(makeRequest()) {}
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .missingAPIKey)
            XCTAssertTrue((error as? ClaudeError)?.isAuthenticationFailure == true)
        }
    }

    func testErrorBodyMapping() {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        let error = ClaudeClient.error(status: 401, body: body)
        XCTAssertEqual(error, .api(status: 401, type: "authentication_error", message: "invalid x-api-key"))
        XCTAssertTrue(error.isAuthenticationFailure)
        XCTAssertFalse(error.isRetryable)
        XCTAssertEqual(ClaudeClient.error(status: 502, body: Data("bad gateway".utf8)), .http(status: 502, body: "bad gateway"))
        XCTAssertTrue(ClaudeClient.error(status: 529, body: Data()).isRetryable)
    }

    func testWarmSendsZeroMaxTokensWithoutStreaming() async throws {
        let transport = MockTransport()
        transport.dataResponse = .success(Data(#"{"id":"msg","content":[],"stop_reason":"max_tokens","usage":{"input_tokens":5,"cache_creation_input_tokens":4100,"cache_read_input_tokens":0,"output_tokens":0}}"#.utf8))
        let client = ClaudeClient(apiKey: "sk-test", transport: transport)
        let usage = try await client.warm(makeRequest())
        XCTAssertEqual(usage.cacheCreationInputTokens, 4100)
        let body = try XCTUnwrap(transport.requests.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["max_tokens"] as? Int, 0)
        XCTAssertNil(body["stream"])
    }

    func testCompleteCollectsTextAndRejectsRefusal() async throws {
        let transport = MockTransport()
        transport.streamLines = Self.sampleStream.components(separatedBy: "\n")
        let client = ClaudeClient(apiKey: "sk-test", transport: transport)
        let result = try await client.complete(makeRequest())
        XCTAssertEqual(result.text, "It usually lands in the range from the proposal.")

        transport.streamLines = [
            #"data: {"type":"message_start","message":{"model":"m","usage":{"input_tokens":1}}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#,
        ]
        do {
            _ = try await client.complete(makeRequest())
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .refusal(category: nil))
        }
    }

    func testSSEParserIgnoresCommentsAndCarriageReturns() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: ": keep-alive"))
        XCTAssertNil(parser.consume(line: "event: ping\r"))
        XCTAssertEqual(parser.consume(line: "data: {}\r"), SSEParser.Event(name: "ping", data: "{}"))
        XCTAssertEqual(parser.consume(line: "data:{}"), SSEParser.Event(name: nil, data: "{}"))
    }

    func testPricing() throws {
        let pricing = try XCTUnwrap(ClaudeModel.haiku55.pricing)
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheCreationInputTokens: 0, cacheReadInputTokens: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage), 0.61, accuracy: 0.0001)
        XCTAssertEqual(ClaudeModel.resolve("claude-opus-5-5").displayName, "Claude Opus 5.5")
        XCTAssertNil(ClaudeModel.resolve("custom").pricing)
    }
}
