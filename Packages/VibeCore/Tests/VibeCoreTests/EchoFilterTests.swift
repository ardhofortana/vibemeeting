import XCTest
@testable import VibeCore

/// Real bleed from a call: what "Them" said, and what the mic recognizer made of it.
enum Bleed {
    static let them = "The recent Saudi attacks involve Yemen's Halbies, who claimed strikes on Rayad's Airport, and the latest reporting says the weekend attacks killed 14 people and injured hundreds."
    /// What they said next, reconstructed from the echo's tail.
    static let themNext = "The politics are tied to overlapping conflicts, the Saudi-backed Yemeni government against the Houthis, and how these ties are drawn, and whether the US goes to war."
    static let echo = "The recent Saudi effects involve women's healthies, the plane, strikes, and the latest reporter says that we get a tax for ultimate people"
    static let echoTail = "and major offenders, " + echoNext
    static let echoNext = "the politics, the time is overlapping conflicts, Saudi back in Guinness, government, against the houses, and how these ties are wrong, and the water, the US are on war."
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

    // MARK: - Garbled echo

    func testMishearingsByLetterSoundAndStem() {
        for (heard, said) in [("women's", "Yemen's"), ("healthies", "halbies"), ("tax", "attacks"), ("weaks", "weeks")] {
            XCTAssertEqual(EchoFilter.relation(heard, said.lowercased()), .similar, "\(heard) / \(said)")
        }
        for (heard, said) in [("reporter", "reporting"), ("back", "backing"), ("subscription", "subscriptions"), ("fails", "failing")] {
            XCTAssertEqual(EchoFilter.relation(heard, said), .inflected, "\(heard) / \(said)")
        }
        for (heard, said) in [("plane", "claimed"), ("the", "who"), ("14", "40"), ("effects", "attacks"), ("major", "injured")] {
            XCTAssertEqual(EchoFilter.relation(heard, said), .different, "\(heard) / \(said)")
        }
        XCTAssertEqual(EchoFilter.relation("yemen's", "yemens"), .same)
    }

    func testGarbledBleedIsRemoved() {
        XCTAssertEqual(EchoFilter.removingEcho(from: Bleed.echo, reference: Bleed.them), "")
        XCTAssertEqual(EchoFilter.removingEcho(from: Bleed.echo + " " + Bleed.echoTail, reference: Bleed.them + " " + Bleed.themNext), "")
    }

    func testGarbledVariantsAreRemoved() {
        let variants = [
            "the decent saudi attack involves yemen holies who claim strike on the riyadh airport and latest reports say the weekend attack kill fourteen people",
            // Words dropped.
            "recent saudi attacks involve yemen's who claimed strikes airport and the latest reportings says weekend attacks killed people",
            // Neighbors swapped.
            "the recent attacks saudi involve women's halbies who strikes claimed on rayad's airport and latest the reporting says the weekend killed attacks 14 people",
        ]
        for variant in variants {
            XCTAssertEqual(EchoFilter.removingEcho(from: variant, reference: Bleed.them), "", variant)
        }
        XCTAssertEqual(EchoFilter.removingEcho(
            from: "we could watch the new store in two weaks if the payment provider approves the check out and the shipping rules before friday",
            reference: "We could launch the new store in two weeks if the payment provider approves the checkout and the shipping rules before Friday."
        ), "")
    }

    func testOnlyTheEchoedPartIsRemoved() {
        XCTAssertEqual(EchoFilter.removingEcho(from: "Yeah okay. " + Bleed.echo, reference: Bleed.them), "Yeah okay.")
        XCTAssertEqual(
            EchoFilter.removingEcho(from: Bleed.echo + ". So anyway, I think we should start with the landing page next week.", reference: Bleed.them),
            "So anyway, I think we should start with the landing page next week."
        )
        XCTAssertEqual(
            EchoFilter.removingEcho(from: Bleed.echo + ", hold on, let me just mute this thing for a second, " + Bleed.echoNext, reference: Bleed.them + " " + Bleed.themNext),
            "hold on, let me just mute this thing for a second"
        )
        // What they haven't said yet (as far as the reference knows) stays for now.
        let kept = EchoFilter.removingEcho(from: Bleed.echo + " " + Bleed.echoTail, reference: Bleed.them)
        XCTAssertEqual(kept.map { $0.hasPrefix("major offenders, the politics") }, true, kept ?? "nil")
    }

    func testShortGarbledEchoIsHeldBackWhileLive() {
        let start = "The recent Saudi effects involve women's"
        XCTAssertNil(EchoFilter.removingEcho(from: start, reference: Bleed.them), "too short to judge for good")
        XCTAssertEqual(EchoFilter.removingEcho(from: start, reference: Bleed.them, live: true), "")
        XCTAssertEqual(EchoFilter.removingEcho(from: "Yeah okay. The recent Saudi effects", reference: Bleed.them, live: true), "Yeah okay.")
        XCTAssertNil(EchoFilter.removingEcho(from: "Yes, I can do it, no problem.", reference: "Can you do it in two weeks?", live: true))
    }

    func testEchoCanRunAheadOfTheReference() {
        XCTAssertEqual(EchoFilter.removingEcho(
            from: "we could watch the new store in two weaks if the payment provider approves the check out and the shipping rules",
            reference: "We could launch the new store in two weeks if the payment provider approves"
        ), "the check out and the shipping rules")
    }

    func testAnswersOnTheSameTopicAreKept() {
        let cases = [
            ("Yes, I can do it in two weeks, no problem.", "Can you do it in two weeks?"),
            ("The recent Saudi attacks? I haven't read about them yet, sorry.", "Have you seen the recent Saudi attacks involving Yemen's Houthis on Riyadh's airport? What do you make of it?"),
            ("The recent Saudi attacks? I haven't read about them yet, sorry.", Bleed.them),
            // Reuses four to six of their words in a sentence of its own.
            ("Recurring payments for members are easy, we did subscriptions with a checkout like that last year.", "We need the checkout to support subscriptions and recurring payments for our members by next month."),
            ("Honestly the shipping rules are the hard part, the payment provider review is usually quick.", "We could launch the new store in two weeks if the payment provider approves the checkout and the shipping rules before Friday."),
            // Same topic, own wording.
            ("From what I read, the Houthis have been hitting Saudi targets for years, and the airport strike is just the latest escalation.", Bleed.them),
            ("I think the main thing with the Saudi situation is that the strikes on the airport show the Houthis can reach further than people expected, and the reporting on casualties keeps changing.", Bleed.them),
            ("So the Houthis claimed the airport strikes and the weekend attacks killed fourteen people, that's awful, I saw some reporting on it.", Bleed.them),
            // Restating their question, word for word or nearly.
            ("For the WooCommerce migration and the new checkout flow we're looking at about four weeks, maybe five.", "What's your timeline for the WooCommerce migration and the new checkout flow?"),
            ("Building the new store with the subscription features and the custom checkout would take about six weeks.", "How long would it take to build the new store with the subscription features and a custom checkout?"),
            ("I can definitely do the new store in two weeks, and then we can look at the subscription setup and the loyalty program after that.", "Could you do the new store in two weeks and then the subscription setup and the loyalty program after that?"),
            ("Yeah, we can build the new store in two weeks and then we'd set up subscriptions right after that.", "Could you build the new store in two weeks and then set up the subscriptions after that?"),
            ("We can launch the new store in two weeks.", "Can we launch the new store in two weeks?"),
            // Reuses the question with other forms of its words.
            ("I could build the new store in about three weeks, and then the subscription setup after that.", "Could you build the new store in two weeks and then set up the subscriptions after that?"),
            ("So the main thing is that checkout fails for international customers when they're paying with PayPal, right?", "So the main thing is the checkout keeps failing for international customers when they pay with PayPal."),
            ("Yeah so building the new store takes two weeks and then setting up subscriptions comes after that.", "Could you build the new store in two weeks and then set up the subscriptions after that?"),
            // Back and forth.
            ("Sure, we usually start with a discovery call, then a design phase of two weeks, and then the build.", "What does your process look like for a new store, and how long does the design phase take? We want to start soon."),
            ("That makes sense. For the subscriptions we would use the WooCommerce Subscriptions plugin and set up the renewals in Stripe.", "Okay, and for the subscriptions, would you use a plugin or build something custom? We also use Stripe for renewals at the moment."),
            ("Yeah I think that we can work with the price if we get the first year at a discount.", "I think that the price is a bit high for what we get in the first year."),
            ("So I think that we should and the way we do it is that we just go with the plan and then see how it goes in the next week or so.", "And then the thing is that we have to see how the plan goes and then we can do the rest of it in the next week."),
        ]
        for (answer, question) in cases {
            XCTAssertNil(EchoFilter.removingEcho(from: answer, reference: question), answer)
        }
    }

    func testEchoAfterARestatementIsStillFound() {
        let restated = "So the weekend attacks killed 14 people and injured hundreds, that is awful."
        XCTAssertEqual(EchoFilter.removingEcho(from: restated + " " + Bleed.echo, reference: Bleed.them), restated)
    }

    func testWorkIsBounded() {
        let reference = Array(repeating: Bleed.them, count: 40).joined(separator: " ")
        let candidate = Array(repeating: Bleed.echo, count: 20).joined(separator: " ")
        let start = Date()
        XCTAssertEqual(EchoFilter.removingEcho(from: candidate, reference: reference)?.isEmpty, false, "words past the cap are kept")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
