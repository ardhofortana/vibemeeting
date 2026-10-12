import XCTest
@testable import VibeCore

final class EchoGateTests: XCTestCase {
    // MARK: Cases

    /// Speakers only: the mic hears the call 40 ms late and 20 dB down.
    func testBleedOnlyIsGatedOnceCouplingIsLearned() {
        let scene = Scene(them: .speech(seed: 11, from: 0.2, to: 20), user: nil)
        let result = scene.run(seed: 1)
        let bleed = result.fraction(attenuated: true) { t in t >= 2 && scene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(bleed.value, 0.8, "bleed attenuated: \(bleed)")
        // Gated bleed must actually be quiet, not just touched.
        XCTAssertLessThanOrEqual(result.residualDB { t in t >= 2 && scene.isBleedOnly(at: t) }, -10)
    }

    /// No call audio: the mic carries only the user, so nothing may be touched.
    func testUserOnlyWithSilentReferenceIsNeverGated() {
        let scene = Scene(them: nil, user: .speech(seed: 21, from: 0.1, to: 20, levelDB: -25))
        let result = scene.run(seed: 2)
        XCTAssertEqual(result.attenuatedCount, 0)
        XCTAssertFalse(result.stats.isCoupled)
    }

    /// Headphones: the call is loud but the mic never hears it; the user talks
    /// over it with an unrelated rhythm. Chance correlation must not couple.
    func testUncoupledMicIsNotGated() {
        for seed in UInt64(0)..<4 {
            let scene = Scene(
                them: .speech(seed: 31 + seed, from: 0.1, to: 20),
                user: .speech(seed: 41 + seed, from: 0.3, to: 20, levelDB: -25),
                bleedGainDB: nil
            )
            let result = scene.run(seed: 3 + seed)
            let all = result.fraction(attenuated: true) { _ in true }
            XCTAssertLessThan(all.value, 0.02, "seed \(seed): \(all)")
            XCTAssertFalse(result.stats.isCoupled, "seed \(seed)")
        }
    }

    /// Both talk at once for 17 s: the user is 15 dB louder than the bleed,
    /// with the same speech model as the other side (bursts ±6 dB, syllable
    /// dips of 12 dB), and must pass, dips included, while the bleed around
    /// them is still gated.
    func testDoubleTalkPassesTheUser() {
        for seed in UInt64(0)..<4 {
            let scene = Scene(
                them: .speech(seed: 51 + seed, from: 0.2, to: 20),
                user: .speech(seed: 61 + seed, from: 3, to: 20, levelDB: -25)
            )
            let result = scene.run(seed: 4 + seed)
            let user = result.fraction(attenuated: false) { t in scene.user!.isActive(at: t) }
            XCTAssertGreaterThanOrEqual(user.value, 0.95, "seed \(seed) user untouched: \(user)")
            // Learned by 4 s even when the other side's first 3 s are sparse.
            let bleed = result.fraction(attenuated: true) { t in t >= 4 && scene.isBleedOnly(at: t) }
            XCTAssertGreaterThanOrEqual(bleed.value, 0.9, "seed \(seed) bleed attenuated: \(bleed)")
            XCTAssertTrue(result.stats.isCoupled, "seed \(seed)")
        }
    }

    /// The other side talks for 3 s and stops; the user answers 100 ms later
    /// at the same level as the bleed. The predicted bleed drops with the
    /// reference, so the first words pass.
    func testHandoverPassesTheUsersFirstWords() {
        var them = Talk.speech(seed: 71, from: 0.05, to: 3)
        them.end(at: 3)
        let scene = Scene(
            them: them,
            user: Talk(bursts: [.init(start: 3.1, end: 3.6, amplitude: Talk.amplitude(dB: -40), phase: 0.3)]),
            duration: 4
        )
        let result = scene.run(seed: 5)
        // The gate must be armed before the handover, or the test proves nothing.
        XCTAssertLessThan(result.firstAttenuatedTime ?? .infinity, 3, "coupling learned before the handover")
        XCTAssertTrue(result.stats.isCoupled)
        let firstWords = result.fraction(attenuated: false) { t in t >= 3.1 && t < 3.4 }
        XCTAssertGreaterThanOrEqual(firstWords.value, 0.9, "first 300 ms untouched: \(firstWords)")
    }

    /// Random buffer sizes and ±3 ms timestamp jitter on both streams.
    func testJitterAndOddBufferSizes() {
        let feed = Feed(referenceSizes: 64...1_500, micSizes: 256...8_000, jitter: 0.003)

        let bleedScene = Scene(them: .speech(seed: 81, from: 0.2, to: 20), user: nil)
        let bleedResult = bleedScene.run(seed: 6, feed: feed)
        let bleed = bleedResult.fraction(attenuated: true) { t in t >= 2 && bleedScene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(bleed.value, 0.8, "bleed attenuated: \(bleed)")

        let userScene = Scene(them: nil, user: .speech(seed: 91, from: 0.1, to: 20, levelDB: -25))
        let userResult = userScene.run(seed: 7, feed: feed)
        XCTAssertEqual(userResult.attenuatedCount, 0)
    }

    func testStatsReportTheCoupling() {
        let scene = Scene(them: .speech(seed: 11, from: 0.2, to: 20), user: nil)
        let result = scene.run(seed: 1)
        let stats = result.stats
        XCTAssertTrue(stats.isCoupled)
        XCTAssertEqual(stats.lagSeconds ?? .nan, 0.04, accuracy: 0.0101)
        XCTAssertEqual(stats.couplingGainDB ?? .nan, -20, accuracy: 4)
        XCTAssertGreaterThanOrEqual(stats.correlation ?? 0, 0.6)
        XCTAssertEqual(stats.processedSeconds, scene.duration, accuracy: 0.001)
        XCTAssertEqual(stats.gatedSeconds, Double(result.attenuatedCount) / scene.micRate, accuracy: 1e-6)
        XCTAssertGreaterThan(stats.gatedSeconds, 5)
    }

    /// A real room smears the bleed with reverb: the coupling must still be
    /// found and most of the bleed gated (the lingering tails pass).
    func testReverberantRoomStillCouples() {
        var scene = Scene(them: .speech(seed: 131, from: 0.2, to: 20), user: nil)
        scene.room = Room(rt60: 0.4, reverbDB: -3)
        let result = scene.run(seed: 10)
        XCTAssertTrue(result.stats.isCoupled)
        XCTAssertLessThan(result.firstAttenuatedTime ?? .infinity, 5)
        XCTAssertEqual(result.stats.lagSeconds ?? .nan, 0.04, accuracy: 0.0201)
        let bleed = result.fraction(attenuated: true) { t in t >= 5 && scene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(bleed.value, 0.7, "bleed attenuated: \(bleed)")
    }

    // MARK: Safety

    /// Missing reference audio is unknown, not silence: once the reference stops
    /// arriving, nothing is gated even though the mic still carries bleed.
    func testMissingReferenceNeverGates() {
        let scene = Scene(them: .speech(seed: 101, from: 0.2, to: 12), user: nil, duration: 12)
        let result = scene.run(seed: 8, feed: Feed(referenceUntil: 6))
        let before = result.fraction(attenuated: true) { t in t >= 2 && t < 6 && scene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(before.value, 0.8, "\(before)")
        let after = result.fraction(attenuated: true) { t in t >= 6.1 }
        XCTAssertEqual(after.value, 0, "\(after)")
    }

    /// Headphones plugged in mid-call: the mic stops carrying the bleed the
    /// coupling predicts, so the coupling is dropped instead of held for 20 s,
    /// and a quiet user talking over the call is not gated.
    func testCouplingDropsWhenTheBleedDisappears() {
        var scene = Scene(
            them: .speech(seed: 111, from: 0.2, to: 16),
            user: .speech(seed: 121, from: 8, to: 16, levelDB: -38, spreadDB: 1),
            duration: 16
        )
        scene.bleedUntil = 6
        let result = scene.run(seed: 9)
        XCTAssertFalse(result.stats.isCoupled)
        let user = result.fraction(attenuated: false) { t in scene.user!.isActive(at: t) }
        XCTAssertGreaterThanOrEqual(user.value, 0.98, "quiet user untouched: \(user)")
    }

    /// Headphones plugged in while the user is already talking over the other
    /// side: the user fills the bins that would show the bleed is gone, so the
    /// coupling must be dropped from the bins in their pauses.
    func testCouplingDropsWhenHeadphonesGoInWhileTheUserTalks() {
        for level in [-38.0, -34.0] {
            var scene = Scene(
                them: .speech(seed: 111, from: 0.2, to: 16),
                user: .speech(seed: 121, from: 5.5, to: 16, levelDB: level, spreadDB: 1),
                duration: 16
            )
            scene.bleedUntil = 6
            let result = scene.run(seed: 9)
            XCTAssertFalse(result.stats.isCoupled, "user \(level)")
            let user = result.fraction(attenuated: false) { t in t >= 6 && scene.user!.isActive(at: t) }
            XCTAssertGreaterThanOrEqual(user.value, 0.9, "user \(level) untouched: \(user)")
            let late = result.fraction(attenuated: true) { t in t >= 8.5 }
            XCTAssertEqual(late.value, 0, "user \(level) still gated: \(late)")
        }
    }

    /// Speaker volume turned down 8 dB while the user talks over the other
    /// side: the gain follows the bleed down, so the user, 12 dB above the new
    /// bleed, mostly passes.
    func testVolumeTurnedDownDuringDoubleTalk() {
        var scene = Scene(
            them: .speech(seed: 401, from: 0.2, to: 16),
            user: .speech(seed: 402, from: 8, to: 16, levelDB: -36),
            duration: 16
        )
        scene.bleedStep = (time: 8, gainDB: -28)
        let result = scene.run(seed: 5)
        let user = result.fraction(attenuated: false) { t in t >= 8 && t < 10 && scene.user!.isActive(at: t) }
        XCTAssertGreaterThanOrEqual(user.value, 0.7, "user untouched in 8-10 s: \(user)")
        XCTAssertLessThan(result.stats.couplingGainDB ?? 0, -23)
    }

    /// Speaker volume turned up 10 dB: the louder gain is taken at the delay
    /// already known, without the full repeat a new coupling needs.
    func testVolumeTurnedUpIsFollowedQuickly() {
        var scene = Scene(them: .speech(seed: 40, from: 0.2, to: 20), user: nil)
        scene.bleedStep = (time: 10, gainDB: -10)
        let result = scene.run(seed: 40)
        let soon = result.fraction(attenuated: true) { t in t >= 10 && t < 13 && scene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(soon.value, 0.45, "bleed attenuated in 10-13 s: \(soon)")
        let later = result.fraction(attenuated: true) { t in t >= 13 && scene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(later.value, 0.95, "bleed attenuated after 13 s: \(later)")
        XCTAssertEqual(result.stats.couplingGainDB ?? .nan, -10, accuracy: 3)
    }

    /// The call audio carries the user's own voice a little late (monitoring,
    /// a meeting app's mic test, the all-system tap): the mic leads the
    /// reference, which bleed never does, so nothing couples.
    func testOwnVoiceInTheCallAudioNeverCouples() {
        for delay in [0.01, 0.02, 0.05] {
            var scene = Scene(them: nil, user: .speech(seed: 141, from: 0.3, to: 20, levelDB: -25), bleedGainDB: nil)
            scene.userInReference = (delay: delay, gainDB: -6)
            let result = scene.run(seed: 14)
            XCTAssertEqual(result.attenuatedCount, 0, "delay \(delay)")
            XCTAssertFalse(result.stats.isCoupled, "delay \(delay)")
        }
    }

    /// A steady noise bed in the call audio (an open mic on the other side)
    /// sits well above -50 dBFS: activity is judged against the reference's own
    /// noise floor, so the coupling is still learned, and still only from the
    /// other side's voice.
    func testNoiseBedInTheCallAudio() {
        var scene = Scene(them: .speech(seed: 11, from: 0.2, to: 20), user: nil)
        scene.referenceNoiseDB = -45
        let result = scene.run(seed: 1)
        XCTAssertTrue(result.stats.isCoupled)
        let bleed = result.fraction(attenuated: true) { t in t >= 4 && scene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(bleed.value, 0.8, "bleed attenuated: \(bleed)")

        for seed in UInt64(0)..<2 {
            var headphones = Scene(
                them: .speech(seed: 31 + seed, from: 0.1, to: 20),
                user: .speech(seed: 41 + seed, from: 0.3, to: 20, levelDB: -25),
                bleedGainDB: nil
            )
            headphones.referenceNoiseDB = -45
            let result = headphones.run(seed: 3 + seed)
            XCTAssertFalse(result.stats.isCoupled, "seed \(seed)")
            XCTAssertEqual(result.attenuatedCount, 0, "seed \(seed)")
        }
    }

    /// Call audio added after the mic it overlaps can't be used: those mic
    /// bins pass untouched, and the gate counts them.
    func testLateReferenceIsNeverGatedButCounted() {
        let scene = Scene(them: .speech(seed: 11, from: 0.2, to: 20), user: nil)
        let onTime = EchoGate()
        _ = scene.run(seed: 1, gate: onTime)
        XCTAssertLessThan(onTime.unknownReferenceSeconds, 0.1)

        let late = EchoGate()
        let result = scene.run(seed: 1, feed: Feed(referenceLateness: 0.2), gate: late)
        XCTAssertTrue(result.stats.isCoupled)
        XCTAssertEqual(result.attenuatedCount, 0)
        XCTAssertGreaterThan(late.unknownReferenceSeconds, 10)
    }

    /// The mic's clock steps back 2 s: the delay learned no longer holds, so
    /// the coupling is forgotten instead of applied to the wrong call audio.
    func testClockStepBackStartsOver() {
        let scene = Scene(them: .speech(seed: 11, from: 0.2, to: 16), user: nil, duration: 16)
        var feed = Feed()
        feed.micClockStep = (time: 8, seconds: -2)
        let result = scene.run(seed: 1, feed: feed)
        let before = result.fraction(attenuated: true) { t in t >= 3 && t < 8 && scene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(before.value, 0.8, "\(before)")
        let after = result.fraction(attenuated: true) { t in t >= 8 }
        XCTAssertEqual(after.value, 0, "\(after)")
        XCTAssertFalse(result.stats.isCoupled)
    }

    /// Gains ramp inside gated bins: no sample jumps from untouched to silent.
    func testGateRampsWithoutClicks() {
        let scene = Scene(them: .speech(seed: 11, from: 0.2, to: 10), user: nil, duration: 10)
        let result = scene.run(seed: 1)
        XCTAssertGreaterThan(result.attenuatedCount, 100_000)
        // A 2 ms ramp at 44.1 kHz moves the gain about 0.011 per sample. Allow
        // the rare jump where a bin's decision flips between two buffers.
        var jumps = 0
        var previous: Float = 1
        for i in result.input.indices where result.input[i] != 0 {
            let gain = result.output[i] / result.input[i]
            if abs(gain - previous) > 0.1 { jumps += 1 }
            previous = gain
        }
        XCTAssertLessThan(jumps, 10)
    }

    func testIgnoresUnusableInput() {
        let gate = EchoGate()
        var samples = [Float](repeating: 0.1, count: 480)
        gate.addReference([], sampleRate: 48_000, startTime: 1)
        gate.addReference(samples, sampleRate: 0, startTime: 1)
        gate.addReference(samples, sampleRate: 48_000, startTime: .nan)
        XCTAssertEqual(gate.process(&samples, sampleRate: .infinity, startTime: 1), 0)
        XCTAssertEqual(gate.process(&samples, sampleRate: 48_000, startTime: .infinity), 0)
        var empty: [Float] = []
        XCTAssertEqual(gate.process(&empty, sampleRate: 48_000, startTime: 1), 0)
        XCTAssertEqual(samples, [Float](repeating: 0.1, count: 480))
        XCTAssertEqual(gate.stats, EchoGate.Stats())
    }

    func testResetForgetsEverything() {
        let scene = Scene(them: .speech(seed: 11, from: 0.2, to: 6), user: nil, duration: 6)
        let gate = EchoGate()
        _ = scene.run(seed: 1, gate: gate)
        XCTAssertTrue(gate.stats.isCoupled)
        gate.reset()
        XCTAssertEqual(gate.stats, EchoGate.Stats())
        var samples = [Float](repeating: 0.01, count: 4_410)
        XCTAssertEqual(gate.process(&samples, sampleRate: 44_100, startTime: 2_000), 0)
    }

    func testBinsFollowTheAbsoluteClock() {
        // 10 ms at 48 kHz starting 2.5 ms into a bin touches two bins.
        let geometry = BinGeometry(count: 480, sampleRate: 48_000, startTime: 100.0025, binDuration: 0.01)!
        var segments: [(Int, Int, Int)] = []
        geometry.forEachSegment { bin, lower, upper, _ in segments.append((bin, lower, upper)) }
        XCTAssertEqual(segments.map(\.0), [10_000, 10_001])
        XCTAssertEqual(segments.map(\.1), [0, 360])
        XCTAssertEqual(segments.map(\.2), [360, 480])
    }

    func testQuickselectFindsOrderStatistics() {
        var rng = LCG(seed: 5)
        for count in [1, 2, 3, 10, 151] {
            let values = (0..<count).map { _ in rng.uniform(-50...50).rounded() }
            let sorted = values.sorted()
            for k in [0, count / 2, count - 1] {
                var copy = values
                let found = copy.withUnsafeMutableBufferPointer { EchoGate.select($0.baseAddress!, count, k) }
                XCTAssertEqual(found, sorted[k])
            }
        }
    }
}

// MARK: - Signals

/// Seeded linear congruential generator, so every run is identical.
struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x2545_F491_4F6C_DD1D
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    /// Zero mean, unit variance.
    mutating func noise() -> Float {
        Float((unit() * 2 - 1) * 1.732_050_8)
    }
}

/// Speech-like activity: bursts with gaps, a level per burst, and a
/// syllable-rate dip inside each burst.
struct Talk {
    struct Burst {
        var start: Double
        var end: Double
        /// RMS at the syllable peaks.
        var amplitude: Double
        var phase: Double
        /// Syllables per second.
        var rate: Double = 4
        /// How far the level dips between syllables, as a share of the amplitude.
        var depth: Double = 0.5
    }

    var bursts: [Burst]

    static func amplitude(dB: Double) -> Double { pow(10, dB / 20) }

    /// Bursts of 150-600 ms with 100-400 ms gaps, levels spread ±`spreadDB`
    /// around `levelDB` (dBFS at the syllable peaks), 3-6 syllables per second
    /// dipping `dipDB` between syllables.
    static func speech(
        seed: UInt64,
        from start: Double,
        to end: Double,
        levelDB: Double = -20,
        spreadDB: Double = 6,
        dipDB: Double = 12
    ) -> Talk {
        let depth = 1 - amplitude(dB: -dipDB)
        var rng = LCG(seed: seed)
        var bursts: [Burst] = []
        var t = start
        while t < end {
            let length = rng.uniform(0.15...0.6)
            let level = levelDB + rng.uniform(-spreadDB...spreadDB)
            bursts.append(Burst(
                start: t,
                end: min(t + length, end),
                amplitude: amplitude(dB: level),
                phase: rng.uniform(0...Double.pi),
                rate: rng.uniform(3...6),
                depth: depth
            ))
            t += length + rng.uniform(0.1...0.4)
        }
        return Talk(bursts: bursts)
    }

    /// Cuts the talk off at `time`.
    mutating func end(at time: Double) {
        bursts = bursts.filter { $0.start < time - 0.05 }
        if !bursts.isEmpty { bursts[bursts.count - 1].end = time }
    }

    private func burst(at t: Double) -> Burst? {
        var lower = 0, upper = bursts.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if bursts[mid].end <= t { lower = mid + 1 } else { upper = mid }
        }
        guard lower < bursts.count, bursts[lower].start <= t else { return nil }
        return bursts[lower]
    }

    func isActive(at t: Double) -> Bool { burst(at: t) != nil }

    /// RMS amplitude at `t`: 0 between bursts, 10 ms fades at the edges, and a
    /// dip between syllables.
    func amplitude(at t: Double) -> Double {
        guard let burst = burst(at: t) else { return 0 }
        let fade = min(1, (t - burst.start) / 0.01, (burst.end - t) / 0.01)
        let s = sin(Double.pi * burst.rate * (t - burst.start) + burst.phase)
        return burst.amplitude * fade * (1 - burst.depth * s * s)
    }
}

/// How the streams are fed to the gate: reference in ~10 ms calls, mic in
/// ~100 ms calls, timestamps on a shared clock with optional jitter.
struct Feed {
    var referenceSizes: ClosedRange<Int> = 480...480
    var micSizes: ClosedRange<Int> = 4_410...4_410
    var jitter: Double = 0
    /// Scene time after which no more reference audio arrives.
    var referenceUntil: Double = .infinity
    /// Reference audio arrives only up to this long before the end of each mic buffer.
    var referenceLateness = 0.0
    /// From scene `time` on, the mic's timestamps are off by `seconds`.
    var micClockStep: (time: Double, seconds: Double)?
}

struct Scene {
    var them: Talk?
    var user: Talk?
    var duration: Double = 20
    var bleedDelay = 0.04
    /// Level of the bleed relative to the reference; nil for headphones.
    var bleedGainDB: Double? = -20
    /// Scene time after which the speakers stop bleeding (headphones plugged in).
    var bleedUntil: Double = .infinity
    /// From scene `time` on, the bleed has this level instead (volume changed).
    var bleedStep: (time: Double, gainDB: Double)?
    /// The call audio also carries the user's own voice, this late and at this level.
    var userInReference: (delay: Double, gainDB: Double)?
    /// Reverb the room adds to the bleed; nil for the direct sound only.
    var room: Room?
    var micNoiseDB = -70.0
    var referenceNoiseDB = -90.0
    var referenceRate = 48_000.0
    var micRate = 44_100.0
    /// Shared clock time of scene time 0, deliberately off the bin grid.
    var origin = 1_000.0037

    init(them: Talk?, user: Talk?, bleedGainDB: Double? = -20, duration: Double = 20) {
        self.them = them
        self.user = user
        self.bleedGainDB = bleedGainDB
        self.duration = duration
    }

    func isBleedOnly(at t: Double) -> Bool {
        guard bleedGainDB != nil, t < bleedUntil, let them, them.isActive(at: t - bleedDelay) else { return false }
        return !(user?.isActive(at: t) ?? false)
    }

    struct Result {
        var input: [Float]
        var output: [Float]
        var micRate: Double
        var attenuatedCount: Int
        var stats: EchoGate.Stats

        struct Fraction: CustomStringConvertible {
            var hits: Int
            var total: Int
            var value: Double { total == 0 ? .nan : Double(hits) / Double(total) }
            var description: String { String(format: "%.3f (%d of %d)", value, hits, total) }
        }

        /// Share of the mic samples selected by `where` that were attenuated
        /// (or, with `attenuated: false`, left untouched).
        func fraction(attenuated: Bool, where select: (Double) -> Bool) -> Fraction {
            var hits = 0, total = 0
            for i in input.indices where select(Double(i) / micRate) {
                total += 1
                if (output[i] != input[i]) == attenuated { hits += 1 }
            }
            return Fraction(hits: hits, total: total)
        }

        /// Scene time of the first attenuated sample.
        var firstAttenuatedTime: Double? {
            input.indices.first { output[$0] != input[$0] }.map { Double($0) / micRate }
        }

        /// Energy left in the selected samples, in dB relative to the input.
        func residualDB(where select: (Double) -> Bool) -> Double {
            var before = 0.0, after = 0.0
            for i in input.indices where select(Double(i) / micRate) {
                before += Double(input[i] * input[i])
                after += Double(output[i] * output[i])
            }
            return 10 * log10(after / before)
        }
    }

    /// Renders both streams, feeds them to `gate` and returns the gated mic.
    func run(seed: UInt64, feed: Feed = Feed(), gate: EchoGate = EchoGate()) -> Result {
        var rng = LCG(seed: seed)
        let reference = renderReference(&rng)
        let input = renderMic(reference: reference, &rng)
        var output = input
        var attenuated = 0
        var r = 0, m = 0
        while m < output.count {
            let micCount = min(Int(rng.uniform(Double(feed.micSizes.lowerBound)...Double(feed.micSizes.upperBound) + 0.999)), output.count - m)
            let micEnd = Double(m + micCount) / micRate
            while r < reference.count, Double(r) / referenceRate < micEnd - feed.referenceLateness, Double(r) / referenceRate < feed.referenceUntil {
                let count = min(Int(rng.uniform(Double(feed.referenceSizes.lowerBound)...Double(feed.referenceSizes.upperBound) + 0.999)), reference.count - r)
                let start = origin + Double(r) / referenceRate + rng.uniform(-feed.jitter...feed.jitter)
                reference.withUnsafeBufferPointer { buffer in
                    gate.addReference(UnsafeBufferPointer(rebasing: buffer[r..<(r + count)]), sampleRate: referenceRate, startTime: start)
                }
                r += count
            }
            var start = origin + Double(m) / micRate + rng.uniform(-feed.jitter...feed.jitter)
            if let step = feed.micClockStep, Double(m) / micRate >= step.time { start += step.seconds }
            attenuated += output.withUnsafeMutableBufferPointer { buffer in
                gate.process(UnsafeMutableBufferPointer(rebasing: buffer[m..<(m + micCount)]), sampleRate: micRate, startTime: start)
            }
            m += micCount
        }
        return Result(input: input, output: output, micRate: micRate, attenuatedCount: attenuated, stats: gate.stats)
    }

    private func renderReference(_ rng: inout LCG) -> [Float] {
        let count = Int(duration * referenceRate)
        let floor = Float(Talk.amplitude(dB: referenceNoiseDB))
        var voice = Voice()
        var ownVoice = Voice()
        return (0..<count).map { i in
            let t = Double(i) / referenceRate
            let amplitude = Float(them?.amplitude(at: t) ?? 0)
            var sample = amplitude * voice.next(&rng) + floor * rng.noise()
            if let own = userInReference, let user {
                sample += Float(Talk.amplitude(dB: own.gainDB) * user.amplitude(at: t - own.delay)) * ownVoice.next(&rng)
            }
            return sample
        }
    }

    private func renderMic(reference: [Float], _ rng: inout LCG) -> [Float] {
        let count = Int(duration * micRate)
        let noise = Float(Talk.amplitude(dB: micNoiseDB))
        let bleedGain = bleedGainDB.map { Float(Talk.amplitude(dB: $0)) } ?? 0
        let step = bleedStep.map { (time: $0.time, gain: Float(Talk.amplitude(dB: $0.gainDB))) }
        var voice = Voice()
        var reverb = room.map { Reverb(room: $0, sampleRate: micRate) }
        return (0..<count).map { i in
            let t = Double(i) / micRate
            var sample = noise * rng.noise()
            if let user {
                sample += Float(user.amplitude(at: t)) * voice.next(&rng)
            }
            if bleedGain > 0, t < bleedUntil {
                // The reference delayed and resampled (linear interpolation).
                var bleed: Float = 0
                let position = (t - bleedDelay) * referenceRate
                let index = Int(position.rounded(.down))
                if index >= 0, index + 1 < reference.count {
                    let fraction = Float(position - Double(index))
                    let gain = step.map { t >= $0.time ? $0.gain : bleedGain } ?? bleedGain
                    bleed = gain * (reference[index] * (1 - fraction) + reference[index + 1] * fraction)
                }
                sample += bleed + (reverb?.process(bleed) ?? 0)
            }
            return sample
        }
    }
}

/// How the room colors the bleed on its way to the mic.
struct Room {
    /// Seconds for the tail to decay by 60 dB.
    var rt60 = 0.4
    /// Level of the reverberant sound relative to the direct sound.
    var reverbDB = -3.0
}

/// Schroeder reverberator (four combs, two allpasses), scaled so the tail
/// carries `Room.reverbDB` relative to a steady input.
struct Reverb {
    private struct Line {
        var buffer: [Float]
        var index = 0
        var gain: Float

        init(length: Int, gain: Float) {
            buffer = Array(repeating: 0, count: max(1, length))
            self.gain = gain
        }

        mutating func comb(_ x: Float) -> Float {
            let out = buffer[index]
            buffer[index] = x + gain * out
            index = (index + 1) % buffer.count
            return out
        }

        mutating func allpass(_ x: Float) -> Float {
            let delayed = buffer[index]
            let v = x + gain * delayed
            buffer[index] = v
            index = (index + 1) % buffer.count
            return delayed - gain * v
        }
    }

    private var combs: [Line]
    private var allpasses: [Line]
    private let scale: Float

    init(room: Room, sampleRate: Double) {
        var power = 0.0
        combs = [0.0297, 0.0371, 0.0411, 0.0437].map { delay in
            let gain = pow(10, -3 * delay / room.rt60)
            power += 1 / (1 - gain * gain)
            return Line(length: Int(delay * sampleRate), gain: Float(gain))
        }
        allpasses = [0.005, 0.0017].map { Line(length: Int($0 * sampleRate), gain: 0.7) }
        scale = Float(Talk.amplitude(dB: room.reverbDB) / power.squareRoot())
    }

    mutating func process(_ x: Float) -> Float {
        var y: Float = 0
        for i in combs.indices { y += combs[i].comb(x) }
        for i in allpasses.indices { y = allpasses[i].allpass(y) }
        return y * scale
    }
}

/// Low-passed noise with unit variance, a rough stand-in for a voice's spectrum.
struct Voice {
    private var state: Float = 0
    private let coefficient: Float = 0.3

    mutating func next(_ rng: inout LCG) -> Float {
        state += coefficient * (rng.noise() - state)
        return state * ((2 - coefficient) / coefficient).squareRoot()
    }
}
