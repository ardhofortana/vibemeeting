import Foundation
import XCTest
@testable import VibeCore

/// The gate against field-like calls (see EchoGateFieldSimulation.swift): a
/// voice assistant talking for 10-30 s at a time through loud speakers into a
/// plain USB mic, the user answering in its pauses, delivered the way the app
/// delivers the streams and with the app's configuration.
final class EchoGateFieldTests: XCTestCase {
    // MARK: Bleed is found

    /// The field report: loud speakers on the headphone jack, a hot USB
    /// condenser mic, the assistant's long monologues. The speakers limit their
    /// loudest sounds and color others, and the room adds a tail as loud as
    /// the direct sound, so the mic falls short of a unit-slope prediction on
    /// the loudest bins. Before the fix nearly every window failed the slope
    /// check and the gate never armed ("no speaker bleed found").
    func testLoudSpeakersIntoAHotMicCouple() {
        for seed in UInt64(0)..<2 {
            var scene = FieldScene(conversation: Conversation(seed: 11 + seed, duration: 40, plan: .loud))
            scene.path = .loudSpeakers
            let run = scene.measure(seed: 21 + seed)
            XCTAssertLessThan(run.firstCoupled ?? .infinity, 10, "seed \(seed): \(run.stats.searches.summary)")
            XCTAssertTrue(run.stats.isCoupled, "seed \(seed)")
            XCTAssertEqual(run.stats.lagSeconds ?? .nan, scene.path.delay, accuracy: 0.0301, "seed \(seed)")
            let bleed = run.result.gated { $0 > (run.firstCoupled ?? 0) + 1 && scene.isBleedOnly(at: $0) }
            XCTAssertGreaterThanOrEqual(bleed.value, 0.6, "seed \(seed) bleed gated: \(bleed)")
            let user = run.result.gated { scene.isUserAlone(at: $0) }
            XCTAssertLessThanOrEqual(user.value, 0.001, "seed \(seed) user's own words gated: \(user)")
        }
    }

    /// One cause at a time: a speaker limiter at 6:1 and nothing else.
    func testLimitedSpeakersCouple() {
        var scene = FieldScene(conversation: Conversation(seed: 31, duration: 30))
        scene.path.limiterDB = -26
        scene.path.limiterRatio = 6
        scene.path.reverbDB = -8
        let run = scene.measure(seed: 32)
        XCTAssertLessThan(run.firstCoupled ?? .infinity, 10, run.stats.searches.summary)
        let bleed = run.result.gated { $0 > (run.firstCoupled ?? 0) + 1 && scene.isBleedOnly(at: $0) }
        XCTAssertGreaterThanOrEqual(bleed.value, 0.7, "bleed gated: \(bleed)")
    }

    /// Bluetooth or HDMI speakers: half a second from the call audio to the
    /// mic, past the 0.4 s searched before.
    func testHalfASecondOfDelayCouples() {
        var scene = FieldScene(conversation: Conversation(seed: 41, duration: 30))
        scene.path.delay = 0.5
        scene.path.gainDB = -12
        let run = scene.measure(seed: 42)
        XCTAssertLessThan(run.firstCoupled ?? .infinity, 10, run.stats.searches.summary)
        XCTAssertEqual(run.stats.lagSeconds ?? .nan, 0.5, accuracy: 0.0201)
        let bleed = run.result.gated { $0 > (run.firstCoupled ?? 0) + 1 && scene.isBleedOnly(at: $0) }
        XCTAssertGreaterThanOrEqual(bleed.value, 0.7, "bleed gated: \(bleed)")
    }

    /// Call audio arriving half a second after the mic it overlaps: the search
    /// runs over the bins whose reference is there, so the bleed is still
    /// found (before, no short delay had enough known bins and nothing was).
    /// That mic audio was processed before its reference arrived, so none of
    /// it can be gated; the stats show why.
    func testLateReferenceStillFindsTheBleed() {
        var scene = FieldScene(conversation: Conversation(seed: 51, duration: 30))
        scene.path = .loudSpeakers
        scene.feed.lateness = 0.5
        scene.feed.latenessJitter = 0.1
        let run = scene.measure(seed: 52)
        XCTAssertLessThan(run.firstCoupled ?? .infinity, 12, run.stats.searches.summary)
        XCTAssertTrue(run.stats.isCoupled)
        XCTAssertEqual(run.stats.lagSeconds ?? .nan, scene.path.delay, accuracy: 0.0301)
        XCTAssertEqual(run.result.gated { _ in true }.hits, 0)
        XCTAssertGreaterThan(run.stats.unknownReferenceSeconds, 5)
        XCTAssertEqual(run.stats.referenceTrailSeconds, 0.55, accuracy: 0.06)
        XCTAssertGreaterThanOrEqual(run.stats.maxReferenceTrailSeconds, 0.55)
    }

    // MARK: Nothing else is

    /// Headphones: the call is loud, the mic hears only the user, who answers
    /// in the other side's pauses, starts before it ends, drops short words
    /// into its monologues, or talks over it for long stretches. Nothing may
    /// confirm a coupling, and nothing may be gated.
    func testHeadphonesNeverCouple() {
        var plans: [Conversation.Plan] = [.init()]
        var eager = Conversation.Plan()
        eager.overlapChance = 0.8
        eager.backchannelsPerMinute = 12
        eager.gap = 0.1...0.4
        plans.append(eager)
        var overTalk = Conversation.Plan()
        overTalk.answer = 10...25
        overTalk.overlapChance = 1
        overTalk.gap = 0.1...0.3
        plans.append(overTalk)
        var quick = Conversation.Plan()
        quick.monologue = 3...8
        quick.answer = 3...8
        quick.overlapChance = 0.5
        quick.gap = 0.05...0.3
        plans.append(quick)
        for (i, plan) in plans.enumerated() {
            var scene = FieldScene(conversation: Conversation(seed: 61 + UInt64(i), duration: 40, plan: plan))
            scene.path.gainDB = nil
            let run = scene.measure(seed: 71 + UInt64(i))
            XCTAssertEqual(run.stats.searches.confirmed, 0, "plan \(i): \(run.stats.searches.summary)")
            XCTAssertEqual(run.result.gated { _ in true }.hits, 0, "plan \(i)")
            XCTAssertFalse(run.stats.isCoupled, "plan \(i)")
        }
    }

    /// The other side silent all along: the mic hears only the user.
    func testUserAloneNeverCouples() {
        var plan = Conversation.Plan()
        plan.them.levelDB = -200
        var scene = FieldScene(conversation: Conversation(seed: 81, duration: 20, plan: plan))
        scene.path = .loudSpeakers
        let run = scene.measure(seed: 82)
        XCTAssertEqual(run.result.gated { _ in true }.hits, 0)
        XCTAssertEqual(run.stats.searches.confirmed + run.stats.searches.pending, 0, run.stats.searches.summary)
        XCTAssertEqual(run.stats.searches.referenceQuiet, run.stats.searches.total - run.stats.searches.micGaps)
        XCTAssertNil(run.stats.bestRecent)
    }

    // MARK: Diagnostics

    /// Every search is counted once, under its outcome, and the best recent
    /// match describes the coupling.
    func testStatsExplainTheSearches() {
        var scene = FieldScene(conversation: Conversation(seed: 91, duration: 20))
        scene.path = .loudSpeakers
        let run = scene.measure(seed: 92)
        let s = run.stats.searches
        let outcomes = s.micGaps + s.referenceUnknown + s.referenceQuiet + s.referenceFlat + s.micLeads
            + s.weakCorrelation + s.slope + s.fewQuietBins + s.notQuiet + s.pending + s.confirmed
        XCTAssertEqual(outcomes, s.total)
        // One search per 0.1 s of mic audio, less the first window.
        XCTAssertEqual(Double(s.total), scene.duration * 10, accuracy: 20)
        XCTAssertGreaterThan(s.confirmed, 0)
        let best = run.stats.bestRecent
        XCTAssertNotNil(best)
        XCTAssertEqual(best?.lagSeconds ?? .nan, scene.path.delay, accuracy: 0.0301)
        XCTAssertGreaterThanOrEqual(best?.correlation ?? 0, 0.6)
        XCTAssertEqual(best?.knownShare ?? 0, 1, accuracy: 0.05)
        XCTAssertLessThanOrEqual(best?.age ?? .infinity, 10)
        XCTAssertTrue(run.stats.searches.summary.hasPrefix("\(s.total) searches: "), run.stats.searches.summary)
        XCTAssertTrue(best?.summary.contains("lag ") ?? false)
        // On time, the reference doesn't trail the mic.
        XCTAssertLessThan(run.stats.maxReferenceTrailSeconds, 0.03)
        XCTAssertLessThan(run.stats.unknownReferenceSeconds, 0.5)
    }

    /// A delay at the end of the search shows in `atMaxLag`.
    func testDelayAtTheEndOfTheSearchIsFlagged() {
        var scene = FieldScene(conversation: Conversation(seed: 101, duration: 20))
        scene.path.delay = 0.6
        let run = scene.measure(seed: 102)
        XCTAssertGreaterThan(run.stats.searches.atMaxLag, run.stats.searches.total / 3, run.stats.searches.summary)
    }

    // MARK: Sweep

    /// Random field-like setups (delay 10-600 ms, loss 2-20 dB, RT60 0.2-0.8 s,
    /// limiters, AGC, coloring, mic noise, call audio up to 0.5 s late) and
    /// scenes without bleed, printed as a table. Slow; runs only with
    /// ECHOGATE_SWEEP set (COUNT setups, NEGATIVES seeds per plan), best in
    /// release: `swift test -c release -Xswiftc -enable-testing --filter testSweep`.
    func testSweep() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ECHOGATE_SWEEP"] != nil else { throw XCTSkip("set ECHOGATE_SWEEP to run") }
        let count = env["COUNT"].flatMap(Int.init) ?? 40
        let negatives = env["NEGATIVES"].flatMap(UInt64.init) ?? 6
        var rng = LCG(seed: 4242)
        var coupled = 0, times: [Double] = [], bleedShares: [Double] = [], userWorst = 0.0
        for i in 0..<count {
            var path = FieldPath()
            path.delay = rng.uniform(0.01...0.6)
            path.gainDB = rng.uniform(-20...(-2))
            path.rt60 = rng.uniform(0.2...0.8)
            path.reverbDB = rng.uniform(-8...3)
            path.colorDB = rng.uniform(0...5)
            if rng.unit() < 0.6 {
                path.limiterDB = rng.uniform(-30...(-22))
                path.limiterRatio = rng.uniform(2...6)
            }
            if rng.unit() < 0.3 { path.agcTargetDB = rng.uniform(-30...(-20)) }
            path.micNoiseDB = rng.uniform(-72...(-55))
            var feed = FieldFeed()
            if rng.unit() < 0.4 {
                feed.lateness = rng.uniform(0.05...0.5)
                feed.latenessJitter = rng.uniform(0...0.1)
            }
            feed.jitter = rng.uniform(0...0.003)
            var plan = Conversation.Plan()
            plan.them = .assistant(levelDB: rng.uniform(-28...(-14)))
            plan.user = .human(levelDB: rng.uniform(-30...(-14)))
            var scene = FieldScene(conversation: Conversation(seed: 3000 + UInt64(i), duration: 60, plan: plan))
            scene.path = path
            scene.feed = feed
            let run = scene.measure(seed: 5000 + UInt64(i))
            let user = run.result.gated { scene.isUserAlone(at: $0) }.value
            userWorst = max(userWorst, user.isNaN ? 0 : user)
            var line = String(
                format: "delay %.2f gain %.0f rt60 %.1f reverb %.0f color %.0f limiter %@ agc %@ late %.2f",
                path.delay, path.gainDB ?? 0, path.rt60, path.reverbDB, path.colorDB,
                path.limiterDB.map { String(format: "%.0f/%.0f", $0, path.limiterRatio) } ?? "-",
                path.agcTargetDB.map { String(format: "%.0f", $0) } ?? "-", feed.lateness
            )
            if let first = run.firstCoupled {
                coupled += 1
                times.append(first)
                line += String(format: " | coupled at %.1f s", first)
                if feed.lateness == 0 {
                    let bleed = run.result.gated { $0 > first + 1 && scene.isBleedOnly(at: $0) }.value
                    bleedShares.append(bleed)
                    line += String(format: ", bleed gated %.2f", bleed)
                }
            } else {
                line += " | NOT COUPLED: \(run.stats.searches.summary)"
            }
            print(line + String(format: ", user gated %.4f", user))
        }
        times.sort()
        bleedShares.sort()
        func at(_ values: [Double], _ q: Double) -> String {
            values.isEmpty ? "-" : String(format: "%.2f", values[min(values.count - 1, Int(Double(values.count) * q))])
        }
        print("BLEED: coupled \(coupled) of \(count); time to couple p50 \(at(times, 0.5)) p90 \(at(times, 0.9)) "
            + "max \(at(times, 1)); bleed gated after coupling p10 \(at(bleedShares, 0.1)) p50 \(at(bleedShares, 0.5)); "
            + "user's own words gated at most \(String(format: "%.4f", userWorst))")

        // Without bleed: headphones with the four plans of
        // `testHeadphonesNeverCouple`, and the user talking over the other side
        // with the same speech model (the hardest chance alignments).
        var runs = 0, minutes = 0.0, confirmed = 0, pending = 0, gated = 0
        for seed in 0..<negatives {
            for variant in 0..<5 {
                let gate = EchoGate(configuration: .init(minLag: -0.05))
                if variant < 4 {
                    var plan = Conversation.Plan()
                    if variant == 1 { plan.overlapChance = 0.8; plan.backchannelsPerMinute = 12; plan.gap = 0.1...0.4 }
                    if variant == 2 { plan.answer = 10...25; plan.overlapChance = 1; plan.gap = 0.1...0.3 }
                    if variant == 3 { plan.monologue = 3...8; plan.answer = 3...8; plan.overlapChance = 0.5; plan.gap = 0.05...0.3 }
                    var scene = FieldScene(conversation: Conversation(seed: 950 + seed * 7 + UInt64(variant), duration: 90, plan: plan))
                    scene.path.gainDB = nil
                    gated += scene.run(seed: 800 + seed, gate: gate).gated { _ in true }.hits
                    minutes += 1.5
                } else {
                    var scene = Scene(
                        them: .speech(seed: 31 + seed, from: 0.1, to: 40),
                        user: .speech(seed: 41 + seed, from: 0.3, to: 40, levelDB: -25),
                        bleedGainDB: nil,
                        duration: 40
                    )
                    scene.micRate = 48_000
                    gated += scene.run(seed: 3 + seed, gate: gate).attenuatedCount
                    minutes += 40.0 / 60
                }
                let stats = gate.stats
                runs += 1
                confirmed += stats.searches.confirmed > 0 ? 1 : 0
                pending += stats.searches.pending
            }
        }
        print("NO BLEED: \(runs) runs, \(Int(minutes)) min: \(confirmed) confirmed, \(gated) samples gated, "
            + "\(pending) windows passed every check without a repeat")
    }
}

// MARK: - Helpers

extension Conversation.Plan {
    /// The field report's levels: the call audio peaks around -13 dBFS and
    /// the user is about as loud at the mic.
    static var loud: Conversation.Plan {
        var plan = Conversation.Plan()
        plan.them = .assistant(levelDB: -15)
        plan.user = .human(levelDB: -14)
        return plan
    }
}

extension FieldPath {
    /// Loud speakers into a hot mic in a lively room: the bleed as loud as the
    /// call audio, a 4:1 limiter, ±4 dB of coloring, a tail as loud as the
    /// direct sound.
    static var loudSpeakers: FieldPath {
        var path = FieldPath()
        path.gainDB = 0
        path.delay = 0.05
        path.rt60 = 0.6
        path.reverbDB = 0
        path.colorDB = 4
        path.limiterDB = -24
        path.limiterRatio = 4
        path.micNoiseDB = -60
        return path
    }
}

extension FieldScene {
    struct Run {
        var result: Result
        var stats: EchoGate.Stats
        /// Scene time of the first search that confirmed a coupling.
        var firstCoupled: Double?
    }

    /// Runs the scene through a gate configured like the app's.
    func measure(seed: UInt64) -> Run {
        let gate = EchoGate(configuration: .init(minLag: -0.05))
        var firstCoupled: Double?
        let result = run(seed: seed, gate: gate) { time in
            if firstCoupled == nil, gate.stats.searches.confirmed > 0 { firstCoupled = time }
        }
        return Run(result: result, stats: result.stats, firstCoupled: firstCoupled)
    }
}
