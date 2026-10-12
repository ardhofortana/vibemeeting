import Foundation

/// Runs the recap: one call for normal meetings, part notes first for very long ones.
public struct RecapGenerator: Sendable {
    public var client: ClaudeClient
    public var builder: RecapPromptBuilder

    public init(client: ClaudeClient, builder: RecapPromptBuilder) {
        self.client = client
        self.builder = builder
    }

    public func generate(record: MeetingRecord, aboutMe: String) async throws -> (recap: Recap, usage: TokenUsage) {
        var usage = TokenUsage()
        let parts = builder.transcriptParts(for: record)
        var notes: [String]?
        if parts.count > 1 {
            var collected: [String] = []
            for (index, part) in parts.enumerated() {
                let request = builder.partRequest(record: record, aboutMe: aboutMe, part: part, index: index, total: parts.count)
                let result = try await client.complete(request)
                usage += result.usage
                collected.append(result.text)
            }
            notes = collected
        }
        let result = try await client.complete(builder.recapRequest(record: record, aboutMe: aboutMe, partNotes: notes))
        usage += result.usage
        if result.stopReason == "max_tokens" {
            throw ClaudeError.invalidResponse("the recap was cut off")
        }
        return (try RecapPromptBuilder.parse(result.text), usage)
    }
}
