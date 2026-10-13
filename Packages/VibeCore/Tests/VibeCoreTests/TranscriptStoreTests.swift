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

    func testGarbledEchoNeverShows() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .volatile, text: Bleed.them), at: at(0))
        store.apply(.init(speaker: .you, kind: .volatile, text: "The recent Saudi effects involve women's healthies, the plane, strikes, and the latest"), at: at(1))
        XCTAssertEqual(store.turns.map(\.speaker), [.them])
        store.apply(.init(speaker: .them, kind: .final, text: Bleed.them), at: at(2))
        store.apply(.init(speaker: .you, kind: .final, text: Bleed.echo), at: at(2.5))
        XCTAssertEqual(store.turns.map(\.speaker), [.them])
        XCTAssertEqual(store.droppedEchoSegments, 1)
    }

    func testGarbledLiveEchoNeverShowsWhileTheyTalk() {
        var store = TranscriptStore()
        let them = Bleed.them.split(separator: " ")
        let echo = Bleed.echo.split(separator: " ")
        for count in 3...echo.count {
            let time = Double(count) * 0.3
            store.apply(.init(speaker: .them, kind: .volatile, text: them.prefix(count + 2).joined(separator: " ")), at: at(time))
            store.apply(.init(speaker: .you, kind: .volatile, text: echo.prefix(count).joined(separator: " ")), at: at(time + 0.1))
            XCTAssertEqual(store.turns.map(\.speaker), [.them], store.turns.last?.text ?? "")
        }
    }

    func testPartialEchoKeepsTheUsersWords() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: Bleed.them), at: at(0))
        store.apply(.init(speaker: .you, kind: .volatile, text: "Yeah okay. The recent Saudi effects involve women's healthies, the plane, strikes"), at: at(1))
        XCTAssertEqual(store.turns.last?.text, "Yeah okay.")
        store.apply(.init(speaker: .you, kind: .final, text: "Yeah okay. " + Bleed.echo), at: at(2))
        XCTAssertEqual(store.turns.map(\.speaker), [.them, .you])
        XCTAssertEqual(store.turns[1].text, "Yeah okay.")
        XCTAssertEqual(store.droppedEchoSegments, 1)
    }

    func testEchoOfWhatTheySayNextIsRemovedWhenTheirTextArrives() throws {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: Bleed.them), at: at(0))
        store.apply(.init(speaker: .them, kind: .volatile, text: "The politics are"), at: at(1))
        store.apply(.init(speaker: .you, kind: .final, text: Bleed.echo + " " + Bleed.echoTail), at: at(2))
        // Their next sentence isn't transcribed yet, so most of its echo shows for now.
        let you = try XCTUnwrap(store.turns.last)
        XCTAssertEqual(you.speaker, .you)
        XCTAssertTrue(you.text.hasSuffix("overlapping conflicts, Saudi back in Guinness, government, against the houses, and how these ties are wrong, and the water, the US are on war."), you.text)
        XCTAssertFalse(you.text.contains("effects"), you.text)

        // Past the window for near-verbatim copies, within the one for garbled echo.
        store.apply(.init(speaker: .them, kind: .final, text: Bleed.themNext), at: at(7))
        XCTAssertEqual(store.turns.map(\.speaker), [.them])
        XCTAssertEqual(store.droppedEchoSegments, 1, "one segment, counted once")
    }

    func testThemRepeatingTheUsersLongLineKeepsIt() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .you, kind: .final, text: "We'll need the product photos and the shipping rates for the new store by Friday, ideally."), at: at(0))
        store.apply(.init(speaker: .them, kind: .final, text: "Okay, so you'll need the product photo and the shipping rate for the new store by Friday."), at: at(4))
        XCTAssertEqual(store.turns.map(\.speaker), [.you, .them])
        XCTAssertEqual(store.droppedEchoSegments, 0)
    }

    func testReadingBackTheirWordsAfterwardsIsKept() {
        var store = TranscriptStore()
        let request = "We're looking for someone to rebuild our WooCommerce store, migrate the products, and set up subscriptions for our coffee club."
        let readBack = "Got it, so a rebuild of the WooCommerce store, product migration, and subscriptions for the coffee club. We've done that a lot."
        store.apply(.init(speaker: .them, kind: .final, text: request), at: at(0))
        store.apply(.init(speaker: .you, kind: .final, text: readBack), at: at(7))
        XCTAssertEqual(store.turns.map(\.text), [request, readBack])
    }

    func testQuickAnswerReusingTheQuestionIsKept() {
        var store = TranscriptStore()
        let question = "Could you build the new store in two weeks and then set up the subscriptions after that?"
        let answer = "I could build the new store in about three weeks, and then the subscription setup after that."
        store.apply(.init(speaker: .them, kind: .final, text: question), at: at(4))
        store.apply(.init(speaker: .you, kind: .final, text: answer), at: at(6.4))
        XCTAssertEqual(store.turns.map(\.text), [question, answer])
        XCTAssertEqual(store.droppedEchoSegments, 0)
    }

    func testThemRepeatingAQuickAnswerKeepsIt() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "What do you need from us to get started?"), at: at(0))
        store.apply(.init(speaker: .you, kind: .final, text: "We'll need the product photos and the shipping rates for the new store by Friday, ideally."), at: at(2))
        store.apply(.init(speaker: .them, kind: .final, text: "Okay, so you'll need the product photo and the shipping rate for the new store by Friday."), at: at(5))
        XCTAssertEqual(store.turns.map(\.speaker), [.them, .you, .them])
        XCTAssertEqual(store.droppedEchoSegments, 0)
    }

    func testThemStartingToRepeatTheUsersLineKeepsIt() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .you, kind: .final, text: "We can launch in two weeks."), at: at(0))
        store.apply(.init(speaker: .them, kind: .volatile, text: "Okay so you can launch in two weeks"), at: at(1.8))
        store.apply(.init(speaker: .them, kind: .final, text: "Okay so you can launch in two weeks."), at: at(3.2))
        XCTAssertEqual(store.turns.map(\.speaker), [.you, .them])
        XCTAssertEqual(store.droppedEchoSegments, 0)
    }

    func testOwnWordsHeldBackLiveShowOnceFinal() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .volatile, text: "So can you do it in two weeks"), at: at(0))
        store.apply(.init(speaker: .you, kind: .volatile, text: "Yes, I can do it in two weeks"), at: at(1))
        store.apply(.init(speaker: .you, kind: .final, text: "Yes, I can do it in two weeks, no problem."), at: at(2))
        XCTAssertEqual(store.turns.last?.text, "Yes, I can do it in two weeks, no problem.")

        // When they aren't talking, live text shows as it comes.
        store.apply(.init(speaker: .them, kind: .final, text: "So can you do it in two weeks?"), at: at(3))
        store.apply(.init(speaker: .you, kind: .volatile, text: "I can do it in two weeks"), at: at(10))
        XCTAssertEqual(store.turns.last?.text, "I can do it in two weeks")
    }

    func testAnswerReusingTheirWordsIsKept() {
        var store = TranscriptStore()
        store.apply(.init(speaker: .them, kind: .final, text: "Can you do it in two weeks?"), at: at(0))
        store.apply(.init(speaker: .you, kind: .final, text: "Yes, I can do it in two weeks, no problem."), at: at(2))
        store.apply(.init(speaker: .them, kind: .volatile, text: "Great, so in two weeks"), at: at(3))
        store.apply(.init(speaker: .them, kind: .final, text: "Great, so in two weeks we can launch."), at: at(4))
        store.apply(.init(speaker: .you, kind: .final, text: "The recent Saudi attacks? I haven't read about them yet, sorry."), at: at(20))
        XCTAssertEqual(store.turns.map(\.speaker), [.them, .you, .them, .you])
        XCTAssertEqual(store.droppedEchoSegments, 0)
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
