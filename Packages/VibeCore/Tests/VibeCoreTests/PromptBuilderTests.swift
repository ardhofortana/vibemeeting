import XCTest
@testable import VibeCore

final class PromptBuilderTests: XCTestCase {
    let meeting = MeetingPromptContext(
        aboutMe: "Name: Ardho\nBrand: Detheme",
        context: [
            .text("Milestone 1: design, $1,200. Milestone 2: build, $2,400.", title: "proposal.pdf"),
            ContextItem(title: "chat.png", content: .image(data: Data([0x89, 0x50]), mediaType: "image/png", pixelWidth: 800, pixelHeight: 600)),
            .text("Client wants subscriptions."),
        ],
        preset: .friendlyPro,
        meetingInstructions: "Keep pricing vague until scope is clear."
    )

    func ask(_ text: String = "What would something like this cost, roughly?", steer: String = "", intent: ReplyIntent = .auto) -> ReplyAsk {
        let turn = TranscriptTurn(speaker: .them, finalText: text, startedAt: Date(timeIntervalSince1970: 0))
        return ReplyAsk(
            target: ReplyTarget(turnIDs: [turn.id], speaker: .them, text: text, isLive: false),
            recentTurns: [turn],
            intent: intent,
            steer: steer
        )
    }

    func json(_ request: MessagesRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
    }

    func testLayersAreOrderedStaticToDynamicWithThreeBreakpoints() throws {
        let request = ReplyPromptBuilder(model: .haiku55).request(meeting: meeting, ask: ask())
        XCTAssertEqual(request.cacheBreakpointCount, 3)
        XCTAssertEqual(request.system.count, 2)
        XCTAssertEqual(request.system[0].text, Prompts.replyRules)
        XCTAssertNil(request.system[0].cacheControl)
        XCTAssertNotNil(request.system[1].cacheControl)
        XCTAssertTrue(request.system[1].text?.contains("Detheme") == true)

        let content = request.messages[0].content
        // Context text + image label, image, closing tag (cached), style (cached), ask (uncached).
        XCTAssertEqual(content.count, 5)
        XCTAssertTrue(content[0].text?.contains("<document title=\"proposal.pdf\">") == true)
        XCTAssertTrue(content[0].text?.contains("<screenshot title=\"chat.png\">") == true)
        if case .image(_, let mediaType, _) = content[1] { XCTAssertEqual(mediaType, "image/png") } else { XCTFail("expected image") }
        XCTAssertNotNil(content[2].cacheControl)
        XCTAssertTrue(content[3].text?.contains("<reply_style name=\"Friendly Pro\">") == true)
        XCTAssertTrue(content[3].text?.contains("Keep pricing vague") == true)
        XCTAssertNotNil(content[3].cacheControl)
        XCTAssertNil(content[4].cacheControl)
        XCTAssertTrue(content[4].text?.contains("<target speaker=\"Them\">") == true)
        XCTAssertTrue(content[4].text?.contains("cost, roughly?") == true)
    }

    func testCachedPrefixIsByteIdenticalAcrossReplies() throws {
        let builder = ReplyPromptBuilder(model: .haiku55)
        let a = builder.request(meeting: meeting, ask: ask("Question one?"))
        let b = builder.request(meeting: meeting, ask: ask("A different question?", steer: "jangan sebut harga"))
        XCTAssertEqual(a.system, b.system)
        XCTAssertEqual(Array(a.messages[0].content.dropLast()), Array(b.messages[0].content.dropLast()))
        XCTAssertNotEqual(a.messages[0].content.last, b.messages[0].content.last)

        // The warmup shares the same cached blocks and settings.
        let warmup = builder.warmupRequest(meeting: meeting)
        XCTAssertEqual(warmup.system, a.system)
        XCTAssertEqual(Array(warmup.messages[0].content.dropLast()), Array(a.messages[0].content.dropLast()))
        XCTAssertEqual(warmup.thinking, a.thinking)
        XCTAssertEqual(warmup.outputConfig, a.outputConfig)
        XCTAssertEqual(warmup.maxTokens, 0)
        XCTAssertNil(warmup.stream)
    }

    func testEncodingIsDeterministic() throws {
        let builder = ReplyPromptBuilder(model: .haiku55)
        XCTAssertEqual(try builder.request(meeting: meeting, ask: ask()).encoded(), try builder.request(meeting: meeting, ask: ask()).encoded())
    }

    func testWireFormat() throws {
        let body = try json(ReplyPromptBuilder(model: .haiku55).request(meeting: meeting, ask: ask()))
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 2048)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["fallbacks"])
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual((system[1]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, Data([0x89, 0x50]).base64EncodedString())
    }

    func testModelSpecificThinking() throws {
        let opus = try json(ReplyPromptBuilder(model: .opus55).request(meeting: meeting, ask: ask()))
        XCTAssertNil(opus["thinking"], "Opus 5.5 can't disable thinking; leave it out")
        XCTAssertEqual((opus["output_config"] as? [String: Any])?["effort"] as? String, "low")

        let sonnet = try json(ReplyPromptBuilder(model: .sonnet55).request(meeting: meeting, ask: ask()))
        XCTAssertEqual((sonnet["thinking"] as? [String: Any])?["type"] as? String, "between_tools")

        let custom = try json(ReplyPromptBuilder(model: ClaudeModel.resolve("claude-something-new")).request(meeting: meeting, ask: ask()))
        XCTAssertNil(custom["thinking"])
        XCTAssertNil(custom["output_config"])
    }

    func testSteerIntentAndVariants() {
        var request = ask(steer: "tawarkan 2 revisi, jangan sebut harga dulu", intent: .pushBack)
        var text = ReplyPromptBuilder.askText(request, preset: .friendlyPro)
        XCTAssertTrue(text.contains("<steer>\ntawarkan 2 revisi, jangan sebut harga dulu\n</steer>"))
        XCTAssertTrue(text.contains(ReplyIntent.pushBack.instruction))
        XCTAssertTrue(text.hasSuffix("Write the script now."))

        request.variant = .shorter
        request.previousScript = "One. Two. Three. Four."
        text = ReplyPromptBuilder.askText(request, preset: .friendlyPro)
        XCTAssertTrue(text.contains("<previous_script>\nOne. Two. Three. Four.\n</previous_script>"))
        XCTAssertTrue(text.contains("at most 2 sentences"))

        request.variant = .regenerate
        text = ReplyPromptBuilder.askText(request, preset: .friendlyPro)
        XCTAssertTrue(text.contains("different angle"))
    }

    func testShorterLimitNeverBelowOne() {
        XCTAssertEqual(ReplyPromptBuilder.shorterSentenceLimit(previous: "Just one.", preset: .friendlyPro), 1)
        XCTAssertEqual(ReplyPromptBuilder.shorterSentenceLimit(previous: "A. B. C. D. E.", preset: StylePreset.builtIns[1]), 3)
    }

    func testLiveTargetAndYouTarget() {
        let turn = TranscriptTurn(speaker: .you, volatileText: "so the thing is", startedAt: Date())
        let liveAsk = ReplyAsk(target: ReplyTarget(turnIDs: [turn.id], speaker: .you, text: turn.text, isLive: true), recentTurns: [turn])
        let text = ReplyPromptBuilder.askText(liveAsk, preset: .friendlyPro)
        XCTAssertTrue(text.contains("You: so the thing is …"))
        XCTAssertTrue(text.contains("They may still be talking"))
        XCTAssertTrue(text.contains("The target is the user's own line"))
    }

    func testEmptyContextAndProfileStillCache() {
        let empty = MeetingPromptContext(aboutMe: " ", context: [], preset: .friendlyPro, meetingInstructions: "")
        let request = ReplyPromptBuilder(model: .haiku55).request(meeting: empty, ask: ask())
        XCTAssertEqual(request.cacheBreakpointCount, 3)
        XCTAssertTrue(request.system[1].text?.contains(Prompts.emptyAboutMe) == true)
        XCTAssertTrue(request.messages[0].content[0].text?.contains(Prompts.emptyContext) == true)
        XCTAssertFalse(request.messages[0].content[1].text?.contains("meeting_instructions") == true)
    }

    func testAttributeEscaping() {
        XCTAssertEqual(ReplyPromptBuilder.escapeAttribute("a \"b\" & c"), "a &quot;b&quot; &amp; c")
    }

    func testContextBudget() {
        XCTAssertEqual(ContextBudget.status(forTokens: 1_000), .ok)
        XCTAssertEqual(ContextBudget.status(forTokens: 50_000), .large)
        XCTAssertEqual(ContextBudget.status(forTokens: 100_000), .tooLarge)
        XCTAssertNil(ContextBudget.ok.warning)
        XCTAssertGreaterThan(TokenEstimator.tokens(forImageWidth: 3000, height: 2000), TokenEstimator.tokens(forImageWidth: 800, height: 600))
        XCTAssertLessThanOrEqual(TokenEstimator.tokens(forImageWidth: 10_000, height: 10_000), 3_300)
    }
}
