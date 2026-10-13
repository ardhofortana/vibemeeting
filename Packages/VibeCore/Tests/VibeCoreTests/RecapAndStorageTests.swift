import XCTest
@testable import VibeCore

final class RecapTests: XCTestCase {
    static let sampleJSON = """
    {"summary":"We scoped a WooCommerce subscription store.","key_points":["Budget is around $3,600"],"decisions":["Two milestones"],"action_items":[{"task":"Send the revised proposal","owner":"You","due":"Friday"},{"task":"Share brand assets","owner":"Them","due":""}],"open_questions":["Which payment gateway?"]}
    """

    func record(turns: [TranscriptTurn] = []) -> MeetingRecord {
        MeetingRecord(name: "Acme kickoff", startedAt: Date(timeIntervalSince1970: 0), presetID: StylePreset.friendlyProID, presetName: "Friendly Pro", turns: turns, replyModel: ClaudeModel.haiku55.id)
    }

    func testParseAndMarkdown() throws {
        let recap = try RecapPromptBuilder.parse(Self.sampleJSON)
        XCTAssertEqual(recap.actionItems.count, 2)
        XCTAssertEqual(recap.actionItems[0].owner, .you)
        XCTAssertEqual(recap.actionItems[1].owner, .them)

        let markdown = recap.markdown(title: "Acme kickoff", date: Date(timeIntervalSince1970: 0), duration: 45 * 60, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(markdown.hasPrefix("# Acme kickoff\n_Thu, Jan 1, 1970 at 00:00 · 45 min_"))
        XCTAssertTrue(markdown.contains("## Action items\n- [ ] Send the revised proposal (You, due Friday)\n- [ ] Share brand assets (Them)"))
        XCTAssertTrue(markdown.contains("## Open questions\n- Which payment gateway?"))
    }

    func testParseToleratesSurroundingText() throws {
        XCTAssertEqual(try RecapPromptBuilder.parse("Here you go:\n" + Self.sampleJSON + "\n").summary, "We scoped a WooCommerce subscription store.")
        XCTAssertThrowsError(try RecapPromptBuilder.parse("{\"nope\": true}"))
    }

    func testOlderRecordsAndRecapsStillLoad() throws {
        // A record saved before goals and goal progress existed.
        let record = MeetingRecord(name: "Old", presetID: "friendly-pro", presetName: "Friendly Pro", recap: Recap(summary: "S"), replyModel: "claude-haiku-5-5")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "goal")
        var recap = try XCTUnwrap(json["recap"] as? [String: Any])
        recap.removeValue(forKey: "goal_progress")
        json["recap"] = recap
        let decoded = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.goal, "")
        XCTAssertEqual(decoded.recap?.goalProgress, "")
        XCTAssertEqual(decoded.name, "Old")
    }

    func testGoalInRecapRequestAndMarkdown() throws {
        let record = MeetingRecord(name: "Acme", presetID: "friendly-pro", presetName: "Friendly Pro", goal: "Get a go-ahead for milestone 1.", replyModel: "claude-opus-5-5")
        let request = RecapPromptBuilder(model: .opus55).recapRequest(record: record, aboutMe: "")
        XCTAssertTrue(request.messages[0].content.last?.text?.contains("<meeting_goal>\nGet a go-ahead for milestone 1.\n</meeting_goal>") == true)
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Recap.jsonSchema)) as? [String: Any])
        XCTAssertTrue((schema["required"] as? [String])?.contains("goal_progress") == true)

        let recap = Recap(summary: "We scoped it.", goalProgress: "Scope agreed; the go-ahead waits on their CFO.")
        let markdown = recap.markdown(title: "Acme", date: nil, duration: nil, goal: record.goal)
        XCTAssertTrue(markdown.contains("## Goal\nGet a go-ahead for milestone 1.\n\nScope agreed; the go-ahead waits on their CFO."))
        XCTAssertFalse(Recap(summary: "x").markdown(title: "", date: nil, duration: nil).contains("## Goal"))
    }

    func testRecapRoundTripsThroughCodable() throws {
        let recap = try RecapPromptBuilder.parse(Self.sampleJSON)
        let data = try JSONEncoder().encode(recap)
        XCTAssertEqual(try JSONDecoder().decode(Recap.self, from: data), recap)
    }

    func testRecapRequestUsesSchemaAndFallbackOnOpus() throws {
        let request = RecapPromptBuilder(model: .opus55).recapRequest(record: record(), aboutMe: "Ardho")
        XCTAssertEqual(request.fallbacks, "default")
        XCTAssertEqual(request.betas, ["server-side-fallback-2026-07-01"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "medium")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertNil(body["thinking"])

        let haiku = RecapPromptBuilder(model: .haiku55).recapRequest(record: record(), aboutMe: "")
        XCTAssertNil(haiku.fallbacks, "Haiku 5.5 has no server-side fallback")
        XCTAssertTrue(haiku.betas.isEmpty)
    }

    func testLongMeetingsAreSplit() {
        let start = Date(timeIntervalSince1970: 0)
        let turns = (0..<200).map { index in
            TranscriptTurn(speaker: index.isMultiple(of: 2) ? .them : .you, finalText: String(repeating: "word ", count: 40), startedAt: start.addingTimeInterval(Double(index) * 15))
        }
        let builder = RecapPromptBuilder(model: .opus55, singlePassCharacterLimit: 10_000, chunkCharacterLimit: 5_000)
        let parts = builder.transcriptParts(for: record(turns: turns))
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 5_000 })
        XCTAssertEqual(parts.joined(separator: "\n"), record(turns: turns).transcriptText())

        let final = builder.recapRequest(record: record(turns: turns), aboutMe: "", partNotes: ["notes 1", "notes 2"])
        let text = final.messages[0].content.last?.text ?? ""
        XCTAssertTrue(text.contains("<meeting_notes>"))
        XCTAssertFalse(text.contains("<transcript>"))

        XCTAssertEqual(RecapPromptBuilder(model: .opus55).transcriptParts(for: record(turns: turns)).count, 1)
    }

    func testGeneratorEndToEnd() async throws {
        let transport = MockTransport()
        let escaped = Self.sampleJSON.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        transport.streamLines = [
            #"data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":900}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(escaped)\"}}",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":120}}"#,
        ]
        let generator = RecapGenerator(client: ClaudeClient(apiKey: "sk", transport: transport), builder: RecapPromptBuilder(model: .opus55))
        let result = try await generator.generate(record: record(), aboutMe: "Ardho")
        XCTAssertEqual(result.recap.decisions, ["Two milestones"])
        XCTAssertEqual(result.usage.outputTokens, 120)
    }
}

final class SessionStoreTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveLoadSearchDelete() throws {
        let store = try SessionStore(directory: directory)
        var older = MeetingRecord(name: "Older", startedAt: Date(timeIntervalSince1970: 100), presetID: "p", presetName: "P", replyModel: "m")
        older.turns = [TranscriptTurn(speaker: .them, finalText: "Can you handle WooCommerce subscriptions?", startedAt: Date(timeIntervalSince1970: 110))]
        older.context = [ContextItem(title: "shot.png", content: .image(data: Data([1, 2, 3]), mediaType: "image/png", pixelWidth: 10, pixelHeight: 10))]
        let newer = MeetingRecord(name: "", startedAt: Date(timeIntervalSince1970: 5_000), presetID: "p", presetName: "P", replyModel: "m", stats: {
            var stats = SessionStats()
            stats.replyCount = 4
            stats.regenerateCount = 1
            return stats
        }())
        try store.save(older)
        try store.save(newer)

        let all = store.loadAll()
        XCTAssertEqual(all.map(\.id), [newer.id, older.id])
        XCTAssertEqual(try store.load(id: older.id), older)
        XCTAssertEqual(all[0].stats.regenerateRate, 0.25)

        XCTAssertTrue(older.matches("woocommerce"))
        XCTAssertFalse(newer.matches("woocommerce"))
        XCTAssertTrue(newer.matches(""))
        XCTAssertTrue(newer.displayName.hasPrefix("Meeting "))

        try store.delete(id: older.id)
        XCTAssertEqual(store.loadAll().map(\.id), [newer.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: older.id).path))
    }

    func testStarSavesAndOlderRecordsLoadUnstarred() throws {
        let store = try SessionStore(directory: directory)
        let starred = MeetingRecord(name: "Starred", presetID: "p", presetName: "P", replyModel: "m", isStarred: true)
        try store.save(starred)
        XCTAssertEqual(try store.load(id: starred.id).isStarred, true)

        // A record saved before starring existed.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(starred)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "isStarred"))
        let decoded = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.isStarred)
        XCTAssertEqual(decoded.name, "Starred")
        XCTAssertFalse(MeetingRecord(name: "New", presetID: "p", presetName: "P", replyModel: "m").isStarred)
    }

    func testTranscriptTextOffsets() {
        let start = Date(timeIntervalSince1970: 0)
        let record = MeetingRecord(name: "x", startedAt: start, presetID: "p", presetName: "P", turns: [
            TranscriptTurn(speaker: .them, finalText: "Hi", startedAt: start.addingTimeInterval(5)),
            TranscriptTurn(speaker: .you, finalText: "Hello", startedAt: start.addingTimeInterval(3_725)),
        ], replyModel: "m")
        XCTAssertEqual(record.transcriptText(), "[00:05] Them: Hi\n[1:02:05] You: Hello")
    }

    func testPercentiles() {
        XCTAssertNil(SessionStats.percentile([], 0.5))
        XCTAssertEqual(SessionStats.percentile([1, 2, 3], 0.5), 2)
        XCTAssertEqual(SessionStats.percentile([1, 2, 3, 4], 0.5), 2.5)
        XCTAssertEqual(SessionStats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9)!, 9.1, accuracy: 0.0001)
    }

    func testPresetValidation() {
        let preset = StylePreset(name: "Custom", instructions: "x", minSentences: 0, maxSentences: -1)
        XCTAssertEqual(preset.minSentences, 1)
        XCTAssertEqual(preset.maxSentences, 1)
        XCTAssertEqual(preset.lengthDescription, "1 sentence")
        XCTAssertEqual(StylePreset.builtIns.count, 6)
        XCTAssertEqual(Set(StylePreset.builtIns.map(\.id)).count, 6)
    }
}
