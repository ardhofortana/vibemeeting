import XCTest
@testable import VibeCore

/// Saved data, prompts and app logic use stable identifiers, never display text,
/// so labels can be reworded or translated without breaking anything.
final class StableIdentifierTests: XCTestCase {
    func testSpeakerKeepsRawValueAndHasFixedPromptToken() {
        XCTAssertEqual(Speaker.them.rawValue, "them")
        XCTAssertEqual(Speaker.you.rawValue, "you")
        XCTAssertEqual(Speaker.them.promptToken, "Them")
        XCTAssertEqual(Speaker.you.promptToken, "You")

        XCTAssertEqual(Speaker(token: "you"), .you)
        XCTAssertEqual(Speaker(token: "You"), .you)
        XCTAssertEqual(Speaker(token: " YOU "), .you)
        XCTAssertEqual(Speaker(token: "Them"), .them)
        XCTAssertEqual(Speaker(token: "them"), .them)
        XCTAssertNil(Speaker(token: "Client"))
        XCTAssertNil(Speaker(token: ""))
    }

    func testPromptsAndRecapSchemaUsePromptTokens() throws {
        let start = Date(timeIntervalSince1970: 0)
        let them = TranscriptTurn(speaker: .them, finalText: "Hi", startedAt: start)
        let you = TranscriptTurn(speaker: .you, finalText: "Hello", startedAt: start.addingTimeInterval(2))
        XCTAssertEqual(ReplyPromptBuilder.transcriptLine(them), "\(Speaker.them.promptToken): Hi")
        XCTAssertEqual(ReplyPromptBuilder.transcriptLine(you), "\(Speaker.you.promptToken): Hello")

        let ask = ReplyAsk(target: ReplyTarget(turnIDs: [them.id], speaker: .them, text: "Hi", isLive: false), recentTurns: [them, you])
        XCTAssertTrue(ReplyPromptBuilder.askText(ask, preset: .friendlyPro).contains("<target speaker=\"\(Speaker.them.promptToken)\">"))

        let record = MeetingRecord(name: "x", startedAt: start, presetID: "p", presetName: "P", turns: [them, you], replyModel: "m")
        XCTAssertEqual(record.promptTranscriptText(), "[00:00] Them: Hi\n[00:02] You: Hello")
        let recapRequest = RecapPromptBuilder(model: .opus55).recapRequest(record: record, aboutMe: "")
        XCTAssertTrue(recapRequest.messages[0].content.last?.text?.contains(record.promptTranscriptText()) == true)

        // The fixed instructions name the speakers by the same tokens.
        let youToken = Speaker.you.promptToken
        let themToken = Speaker.them.promptToken
        XCTAssertTrue(Prompts.replyRules.contains("\"\(themToken)\" is everyone on the other side"))
        XCTAssertTrue(Prompts.replyRules.contains("(\"\(youToken)\")"))
        XCTAssertTrue(Prompts.recapRules.contains("\"\(youToken)\" is the user and \"\(themToken)\" is everyone on the other side"))
        XCTAssertTrue(Prompts.recapRules.contains("(\(youToken) or \(themToken))"))
        XCTAssertTrue(Prompts.recapChunkInstruction.contains("(\(youToken) or \(themToken))"))

        let owner = Recap.jsonSchema["properties"]?["action_items"]?["items"]?["properties"]?["owner"]
        XCTAssertEqual(owner?["enum"], .array([.string(youToken), .string(themToken)]))
    }

    func testActionItemOwnerIsSavedByRawValue() throws {
        let item = Recap.ActionItem(task: "Send the plan", owner: .you, due: "Friday")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        XCTAssertEqual(json["owner"] as? String, "you")
        XCTAssertEqual(try JSONDecoder().decode(Recap.ActionItem.self, from: JSONEncoder().encode(item)), item)
    }

    func testActionItemOwnerReadsLegacyLabelsAndModelOutput() throws {
        func owner(_ value: String) throws -> Speaker {
            let json = #"{"task":"t","owner":"\#(value)","due":""}"#
            return try JSONDecoder().decode(Recap.ActionItem.self, from: Data(json.utf8)).owner
        }
        // Saved before schema version 2 (the label), or written by the model (the token).
        XCTAssertEqual(try owner("You"), .you)
        XCTAssertEqual(try owner("YOU"), .you)
        XCTAssertEqual(try owner("you"), .you)
        XCTAssertEqual(try owner("Them"), .them)
        XCTAssertEqual(try owner("them"), .them)
        // Anything else was always read as the other side; a recap never fails over it.
        XCTAssertEqual(try owner("Both"), .them)
    }

    func testUnknownIntentAndVariantStillLoad() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(ReplyIntent.self, from: Data(#""summarize""#.utf8)), .auto)
        XCTAssertEqual(try decoder.decode(ReplyIntent.self, from: Data(#""pushBack""#.utf8)), .pushBack)
        XCTAssertEqual(try decoder.decode(ReplyIntent.self, from: Data(#""questions""#.utf8)), .questions)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(ReplyIntent.pushBack), as: UTF8.self), #""pushBack""#)
        XCTAssertEqual(try decoder.decode(ReplyVariant.self, from: Data(#""expand""#.utf8)), .fresh)
        XCTAssertEqual(try decoder.decode(ReplyVariant.self, from: Data(#""shorter""#.utf8)), .shorter)

        // A meeting whose script uses a move from a newer version still opens.
        let script = ReplyScript(targetTurnIDs: [], targetText: "t", intent: .add, steer: "", variant: .regenerate, presetName: "P", model: "m", text: "Sure.")
        let record = MeetingRecord(name: "x", presetID: "p", presetName: "P", scripts: [script], replyModel: "m")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        var scripts = try XCTUnwrap(json["scripts"] as? [[String: Any]])
        scripts[0]["intent"] = "summarize"
        scripts[0]["variant"] = "expand"
        json["scripts"] = scripts
        let decoded = try decoder.decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.scripts.first?.intent, .auto)
        XCTAssertEqual(decoded.scripts.first?.variant, .fresh)
        XCTAssertEqual(decoded.scripts.first?.text, "Sure.")
    }

    func testReplyFailureIsAnEnumNotAMessage() {
        XCTAssertEqual(ReplyFailure(error: ClaudeError.refusal(category: nil)), .declined)
        XCTAssertEqual(ReplyFailure(error: ClaudeError.transport("offline")), .requestFailed)
        XCTAssertEqual(ReplyFailure(error: ClaudeError.http(status: 401, body: "")), .requestFailed)
        XCTAssertEqual(ReplyFailure(error: CancellationError()), .requestFailed)

        // Try again is offered for everything except "nothing to reply to".
        XCTAssertFalse(ReplyFailure.nothingToReplyTo.canRetry)
        XCTAssertTrue(ReplyFailure.noQuestions.canRetry)
        XCTAssertTrue(ReplyFailure.declined.canRetry)
        XCTAssertTrue(ReplyFailure.requestFailed.canRetry)

        let all: [ReplyFailure] = [.nothingToReplyTo, .noQuestions, .declined, .requestFailed]
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
        XCTAssertTrue(all.allSatisfy { !$0.message.isEmpty })
    }

    func testCaptureStateChecksCasesNotText() {
        XCTAssertTrue(CaptureState.running(detail: nil).isRunning)
        XCTAssertTrue(CaptureState.running(detail: "42 IO cycles since last start").isRunning)
        XCTAssertEqual(CaptureState.running(detail: nil).label, "Running")
        XCTAssertEqual(CaptureState.running(detail: "echo cancellation on").label, "Running (echo cancellation on)")

        let notRunning: [CaptureState] = [.notStarted, .starting, .failedToStart, .failed, .noAudio, .deviceKeepsChanging]
        XCTAssertTrue(notRunning.allSatisfy { !$0.isRunning })
        XCTAssertEqual(notRunning.filter(\.hasFailed), [.failedToStart, .failed])
        XCTAssertFalse(CaptureState.running(detail: nil).hasFailed)
        XCTAssertEqual(Set(notRunning.map(\.label)).count, notRunning.count)
    }

    func testTranscriberStateChecksCasesNotText() {
        let running = TranscriberState.running(locale: "en-US", engine: "SpeechTranscriber")
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.label, "Running (en-US, SpeechTranscriber)")
        let dictation = TranscriberState.running(locale: "id-ID", engine: "DictationTranscriber")
        XCTAssertTrue(dictation.isRunning)
        XCTAssertEqual(dictation.label, "Running (id-ID, DictationTranscriber)")

        let others: [TranscriberState] = [.notStarted, .checkingModel, .preparingModel, .startingAnalyzer, .failedToStart, .stoppedWithError, .endedUnexpectedly, .stopped]
        XCTAssertTrue(others.allSatisfy { !$0.isRunning })
        XCTAssertEqual(Set(others.map(\.label) + [running.label]).count, others.count + 1)
    }
}
