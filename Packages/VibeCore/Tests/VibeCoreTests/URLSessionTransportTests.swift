import XCTest
@testable import VibeCore

/// Exercises the real URLSession transport against a local SSE server.
/// Skipped unless `VIBE_LOCAL_SSE_URL` points at one (run `python3 scripts/sse_test_server.py 18777`).
final class URLSessionTransportTests: XCTestCase {
    func baseURL() throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["VIBE_LOCAL_SSE_URL"], let url = URL(string: value) else {
            throw XCTSkip("Set VIBE_LOCAL_SSE_URL to run transport tests")
        }
        return url
    }

    func request(stream: Bool) -> MessagesRequest {
        MessagesRequest(model: "claude-haiku-5-5", maxTokens: 10, system: [], messages: [.user([.text("hi")])], stream: stream ? true : nil)
    }

    func testStreamsAcrossOddChunkBoundaries() async throws {
        let client = ClaudeClient(apiKey: "good", baseURL: try baseURL())
        var text = ""
        var usage: TokenUsage?
        for try await event in client.stream(request(stream: true)) {
            switch event {
            case .textDelta(let delta): text += delta
            case .finished(_, let final): usage = final
            default: break
            }
        }
        XCTAssertEqual(text, "Héllo — world.")
        XCTAssertEqual(usage?.cacheReadInputTokens, 3000)
        XCTAssertEqual(usage?.outputTokens, 5)
    }

    func testErrorStatusBecomesClaudeError() async throws {
        let client = ClaudeClient(apiKey: "bad", baseURL: try baseURL())
        do {
            for try await _ in client.stream(request(stream: true)) {}
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .api(status: 401, type: "authentication_error", message: "invalid x-api-key"))
        }
    }

    func testWarmAndSequentialRequestsReuseTheSession() async throws {
        let client = ClaudeClient(apiKey: "good", baseURL: try baseURL())
        let usage = try await client.warm(request(stream: false))
        XCTAssertEqual(usage.cacheCreationInputTokens, 2048)
        for _ in 0..<3 {
            var text = ""
            for try await event in client.stream(request(stream: true)) {
                if case .textDelta(let delta) = event { text += delta }
            }
            XCTAssertEqual(text, "Héllo — world.")
        }
    }
}
