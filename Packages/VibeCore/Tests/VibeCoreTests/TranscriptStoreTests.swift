import XCTest
@testable import VibeCore

final class TranscriptStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testVolatileThenFinalBuildsOneTurn() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .volatile, text: "What would"), at: at(0))
        store.apply(.init(speaker: .them, kind: .volatile, text: "What would something like this"), at: at(0.5))
        XCTAssertEqual(store.turns.count, 1)
        XCTAssertTrue(store.turns[0].isLive)
        XCTAssertEqual(store.turns[0].text, "What would something like this")

        store.apply(.init(speaker: .them, kind: .final, text: "What would something like this cost,"), at: at(1))
        store.apply(.init(speaker: .them, kind: .volatile, text: "roughly"), at: at(1.2))
        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].text, "What would something like this cost, roughly")

        store.apply(.init(speaker: .them, kind: .final, text: "roughly?"), at: at(1.5))
        XCTAssertEqual(store.turns[0].text, "What would something like this cost, roughly?")
        XCTAssertFalse(store.turns[0].isLive)
    }

    func testOtherSpeakerStartsNewTurnAndOrderIsChronological() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "Can you do WooCommerce?"), at: at(0))
        store.apply(.init(speaker: .you, kind: .final, text: "Yes, we build a lot of WooCommerce stores."), at: at(2))
        store.apply(.init(speaker: .them, kind: .final, text: "Great, and subscriptions?"), at: at(5))
        XCTAssertEqual(store.turns.map(\.speaker), [.them, .you, .them])
    }

    func testOverlappingSpeechKeepsGrowingTheLiveTurn() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .volatile, text: "So the plan is"), at: at(0))
        store.apply(.init(speaker: .you, kind: .final, text: "mm-hmm"), at: at(0.5))
        store.apply(.init(speaker: .them, kind: .volatile, text: "So the plan is to launch in two weeks"), at: at(1))
        XCTAssertEqual(store.turns.count, 2)
        XCTAssertEqual(store.turns[0].speaker, .them)
        XCTAssertEqual(store.turns[0].text, "So the plan is to launch in two weeks")
    }

    func testLongPauseStartsNewTurnForSameSpeaker() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "First thought."), at: at(0))
        store.apply(.init(speaker: .them, kind: .final, text: "Second thought."), at: at(3))
        XCTAssertEqual(store.turns.count, 1)
        store.apply(.init(speaker: .them, kind: .final, text: "After a long pause."), at: at(20))
        XCTAssertEqual(store.turns.count, 2)
    }

    func testEmptyVolatileRemovesEmptyTurn() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .you, kind: .volatile, text: "uh"), at: at(0))
        XCTAssertEqual(store.turns.count, 1)
        store.apply(.init(speaker: .you, kind: .volatile, text: ""), at: at(0.3))
        XCTAssertTrue(store.turns.isEmpty)
    }

    func testEchoOfThemIsDroppedFromYou() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "Another agency quoted us half that price."), at: at(0))
        store.apply(.init(speaker: .you, kind: .volatile, text: "agency quoted us half"), at: at(0.4))
        store.apply(.init(speaker: .you, kind: .final, text: "agency quoted us half that price"), at: at(0.8))
        XCTAssertEqual(store.turns.map(\.speaker), [.them])
        XCTAssertEqual(store.droppedEchoSegments, 1)

        // Real speech from You still comes through.
        store.apply(.init(speaker: .you, kind: .final, text: "I understand, let me explain what's included."), at: at(3))
        XCTAssertEqual(store.turns.map(\.speaker), [.them, .you])
    }

    func testEchoWindowExpires() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "we can launch in two weeks"), at: at(0))
        store.apply(.init(speaker: .you, kind: .final, text: "we can launch in two weeks"), at: at(60))
        XCTAssertEqual(store.turns.map(\.speaker), [.them, .you])
    }

    func testReplyTargetMergesThemTurnsAcrossBackchannels() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .you, kind: .final, text: "So that's our process for new stores."), at: at(0))
        store.apply(.init(speaker: .them, kind: .final, text: "What would something like this"), at: at(4))
        store.apply(.init(speaker: .you, kind: .final, text: "Mm-hmm."), at: at(5))
        store.apply(.init(speaker: .them, kind: .final, text: "cost, roughly?"), at: at(6))

        let target = store.replyTarget()
        XCTAssertEqual(target?.text, "What would something like this cost, roughly?")
        XCTAssertEqual(target?.turnIDs.count, 2)
        XCTAssertEqual(target?.speaker, .them)
    }

    func testReplyTargetIgnoresLaterYouTurn() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "I think we can launch in two weeks."), at: at(0))
        store.apply(.init(speaker: .you, kind: .final, text: "Okay so let me think about the scope for a second."), at: at(3))
        XCTAssertEqual(store.replyTarget()?.text, "I think we can launch in two weeks.")
    }

    func testReplyTargetUsesLiveTextWhileTheyAreTalking() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .volatile, text: "Will this work with our WooCommerce"), at: at(0))
        let target = store.replyTarget()
        XCTAssertEqual(target?.text, "Will this work with our WooCommerce")
        XCTAssertEqual(target?.isLive, true)
    }

    func testSelectedTurnWinsAndEditsApply() throws {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "Will this work with our wu commerce subscriptions?"), at: at(0))
        store.apply(.init(speaker: .them, kind: .final, text: "Also, timeline?"), at: at(30))
        let first = store.turns[0].id

        store.edit(turnID: first, text: "Will this work with our WooCommerce subscriptions?")
        let target = try XCTUnwrap(store.replyTarget(selectedTurnID: first))
        XCTAssertEqual(target.text, "Will this work with our WooCommerce subscriptions?")
        XCTAssertEqual(target.turnIDs, [first])
    }

    func testEditingOpenTurnClosesIt() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .volatile, text: "Can you do wu commerce"), at: at(0))
        store.edit(turnID: store.turns[0].id, text: "Can you do WooCommerce")
        store.apply(.init(speaker: .them, kind: .final, text: "and subscriptions?"), at: at(1))
        XCTAssertEqual(store.turns.count, 2)
        XCTAssertEqual(store.turns[0].text, "Can you do WooCommerce")
        XCTAssertEqual(store.turns[1].text, "and subscriptions?")
    }

    func testEditBackToRecognizedClearsEdit() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "Hello there"), at: at(0))
        store.edit(turnID: store.turns[0].id, text: "Hello there")
        XCTAssertNil(store.turns[0].editedText)
    }

    func testRecentTurnsRespectsBudget() {
        var store = TranscriptStore()
        for index in 0..<30 {
            let speaker: Speaker = index.isMultiple(of: 2) ? .them : .you
            store.apply(.init(speaker: speaker, kind: .final, text: "Turn number \(index) with some words."), at: at(Double(index) * 10))
        }
        let window = store.recentTurns(maxTurns: 5, maxCharacters: 10_000)
        XCTAssertEqual(window.count, 5)
        XCTAssertEqual(window.last?.text, "Turn number 29 with some words.")

        let tight = store.recentTurns(maxTurns: 50, maxCharacters: 80)
        XCTAssertLessThanOrEqual(tight.map(\.text.count).reduce(0, +), 80)
        XCTAssertEqual(tight.last?.text, "Turn number 29 with some words.")
    }

    func testRecentTurnsClipsOneHugeTurn() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: String(repeating: "word ", count: 2_000)), at: at(0))
        let window = store.recentTurns(maxTurns: 5, maxCharacters: 100)
        XCTAssertEqual(window.count, 1)
        XCTAssertTrue(window[0].text.hasPrefix("…"))
        XCTAssertEqual(window[0].text.count, 101)
    }

    func testLiveEchoIsNeverShown() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .volatile, text: "We could launch the new store in two weeks"), at: at(0))
        store.apply(.init(speaker: .you, kind: .volatile, text: "launch the new store in"), at: at(0.3))
        XCTAssertEqual(store.turns.map(\.speaker), [.them])
        XCTAssertEqual(store.droppedEchoSegments, 0, "live text isn't counted, only finals")
    }

    func testMisheardEchoIsDropped() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "We can launch in two weeks."), at: at(0))
        store.apply(.init(speaker: .you, kind: .final, text: "we can lunch in two weaks"), at: at(0.5))
        XCTAssertEqual(store.turns.map(\.speaker), [.them])
    }

    func testEchoFinishedBeforeTheirTextIsRemovedLater() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .you, kind: .final, text: "So we can launch in two weeks"), at: at(0))
        XCTAssertEqual(store.turns.map(\.speaker), [.you])
        store.apply(.init(speaker: .them, kind: .final, text: "So we can launch in two weeks, right?"), at: at(1.2))
        XCTAssertEqual(store.turns.map(\.speaker), [.them])
        XCTAssertEqual(store.droppedEchoSegments, 1)
    }

    func testLateEchoRemovesOnlyTheEchoedSegment() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .you, kind: .final, text: "Sure, that works for me."), at: at(0))
        store.apply(.init(speaker: .you, kind: .final, text: "the budget is twelve hundred"), at: at(3))
        store.apply(.init(speaker: .them, kind: .final, text: "And the budget is twelve hundred dollars."), at: at(4))
        XCTAssertEqual(store.turns.map(\.speaker), [.you, .them])
        XCTAssertEqual(store.turns[0].text, "Sure, that works for me.")
    }

    func testThemRepeatingTheUserLaterKeepsTheUsersLine() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .you, kind: .final, text: "We can launch in two weeks."), at: at(0))
        store.apply(.init(speaker: .them, kind: .final, text: "Okay, so you can launch in two weeks."), at: at(5))
        XCTAssertEqual(store.turns.map(\.speaker), [.you, .them])
    }

    func turns(_ count: Int, liveAt live: Int? = nil) -> [TranscriptTurn] {
        (0..<count).map { index in
            let speaker: Speaker = index.isMultiple(of: 2) ? .them : .you
            let text = "Turn \(index) says something."
            return index == live
                ? TranscriptTurn(speaker: speaker, volatileText: text, startedAt: at(Double(index)))
                : TranscriptTurn(speaker: speaker, finalText: text, startedAt: at(Double(index)))
        }
    }

    func testReplyTranscriptHasEverythingInStableChunks() {
        let small = TranscriptStore(turns: turns(30)).replyTranscript(chunkSize: 12, keepRecent: 8)
        XCTAssertEqual(small.earlierChunks.map(\.count), [12])
        XCTAssertEqual(small.recentTurns.count, 18)
        XCTAssertEqual((small.earlierChunks.flatMap { $0 } + small.recentTurns).map(\.text), (0..<30).map { "Turn \($0) says something." })

        // Two more turns complete a second chunk; the first one is unchanged.
        let store = TranscriptStore(turns: turns(30) + turns(32).suffix(2))
        let grown = store.replyTranscript(chunkSize: 12, keepRecent: 8)
        XCTAssertEqual(grown.earlierChunks.count, 2)
        XCTAssertEqual(grown.earlierChunks[0].map(\.text), small.earlierChunks[0].map(\.text))
        XCTAssertEqual(grown.recentTurns.count, 8)
    }

    func testReplyTranscriptKeepsALiveTurnRecent() {
        let window = TranscriptStore(turns: turns(40, liveAt: 15)).replyTranscript(chunkSize: 12, keepRecent: 8)
        XCTAssertEqual(window.earlierChunks.count, 1)
        XCTAssertTrue(window.earlierChunks.joined().allSatisfy { !$0.isLive })
        XCTAssertEqual(window.recentTurns.first?.text, "Turn 12 says something.")
    }

    func testReplyTranscriptDropsOldestChunksPastBudget() {
        let window = TranscriptStore(turns: turns(60)).replyTranscript(chunkSize: 10, keepRecent: 5, maxEarlierCharacters: 470)
        XCTAssertEqual(window.earlierChunks.count, 2)
        XCTAssertEqual(window.earlierChunks[0].first?.text, "Turn 30 says something.")
        XCTAssertEqual(window.recentTurns.last?.text, "Turn 59 says something.")
    }

    func testFinalizeAllLocksVolatileText() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "Thanks."), at: at(0))
        store.apply(.init(speaker: .them, kind: .volatile, text: "Talk soon"), at: at(1))
        store.finalizeAll(at: at(2))
        XCTAssertEqual(store.turns[0].text, "Thanks. Talk soon")
        XCTAssertFalse(store.turns[0].isLive)
    }
}

final class EchoFilterTests: XCTestCase {
    func testDetectsBleed() {
        XCTAssertTrue(EchoFilter.isLikelyEcho("we can launch in two weeks", reference: "I think we can launch in two weeks, right?"))
    }

    func testIgnoresShortAndDifferentText() {
        XCTAssertFalse(EchoFilter.isLikelyEcho("yeah", reference: "yeah sure"))
        XCTAssertFalse(EchoFilter.isLikelyEcho("two weeks is too tight for this scope", reference: "we can launch in two weeks"))
    }

    func testAnswerThatReusesTheirPhraseIsNotEcho() {
        XCTAssertFalse(EchoFilter.isLikelyEcho("I can do it in two weeks", reference: "Can you do it in two weeks?"))
        XCTAssertFalse(EchoFilter.isLikelyEcho("Turn number 29 with some words.", reference: "Turn number 28 with some words."))
    }

    func testMisheardWordsStillMatch() {
        XCTAssertTrue(EchoFilter.isLikelyEcho("we can lunch in two weaks", reference: "We can launch in two weeks."))
        XCTAssertTrue(EchoFilter.similar("integration", "integrations"))
        XCTAssertFalse(EchoFilter.similar("1200", "1300"), "numbers must match exactly")
        XCTAssertFalse(EchoFilter.similar("the", "she"), "short words must match exactly")
    }

    func testThreeWordEchoNeedsExactRun() {
        XCTAssertTrue(EchoFilter.isLikelyEcho("half that price", reference: "they quoted half that price"))
        XCTAssertFalse(EchoFilter.isLikelyEcho("half the price", reference: "they quoted half that price"))
    }
}
