import XCTest
@testable import VibeCore

final class ScriptTextTests: XCTestCase {
    func testSplitFirstSentence() {
        let (first, rest) = ScriptText.splitFirstSentence("It usually lands around $2.5k. That covers design and build. Happy to break it down.")
        XCTAssertEqual(first, "It usually lands around $2.5k.")
        XCTAssertEqual(rest, "That covers design and build. Happy to break it down.")
    }

    func testSplitWhileStreamingWithoutTerminator() {
        let (first, rest) = ScriptText.splitFirstSentence("It usually lands around")
        XCTAssertEqual(first, "It usually lands around")
        XCTAssertEqual(rest, "")
    }

    func testConfirmMarkerStaysWithItsSentence() {
        let text = "Let me confirm the exact figure and send it today. [confirm number] First, can we lock the scope?"
        let (first, rest) = ScriptText.splitFirstSentence(text)
        XCTAssertEqual(first, "Let me confirm the exact figure and send it today. [confirm number]")
        XCTAssertEqual(rest, "First, can we lock the scope?")
        XCTAssertEqual(ScriptText.sentences(in: text).count, 2)
    }

    func testQuestionAndQuotes() {
        XCTAssertEqual(ScriptText.sentences(in: "Really?! I didn't know. \"Okay.\" Sure").count, 4)
    }

    func testSanitizeRemovesForbiddenFormatting() {
        let raw = "\"**Sure** — we can do that.\n- It takes two weeks – roughly.\"\n"
        XCTAssertEqual(ScriptText.sanitize(raw), "Sure, we can do that. It takes two weeks, roughly.")
    }

    func testSanitizeKeepsRanges() {
        XCTAssertEqual(ScriptText.sanitize("It's 2–4 weeks."), "It's 2–4 weeks.")
    }

    func testNeedsNumberConfirmation() {
        var script = ReplyScript(targetTurnIDs: [], targetText: "", intent: .auto, steer: "", variant: .fresh, presetName: "", model: "")
        script.text = "I'll confirm that today. [confirm number]"
        XCTAssertTrue(script.needsNumberConfirmation)
    }
}
