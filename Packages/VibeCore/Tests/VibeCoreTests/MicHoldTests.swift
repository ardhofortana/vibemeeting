import XCTest
@testable import VibeCore

final class MicHoldTests: XCTestCase {
    // MARK: The hold on its own

    func testNothingWaitsWhileTheReferenceIsOnTime() {
        let hold = MicHold<Int>()
        var released: [Int] = []
        hold.referenceArrived(through: 10.2)
        hold.push(1, end: 10.1, referenceNeeded: 10.1) { released.append($0) }
        hold.push(2, end: 10.2, referenceNeeded: 10.2) { released.append($0) }
        XCTAssertEqual(released, [1, 2])
        XCTAssertEqual(hold.stats.heldBuffers, 0)
        XCTAssertEqual(hold.stats.releasedBuffers, 2)
    }

    func testBuffersWaitForTheirReferenceAndLeaveInOrder() {
        let hold = MicHold<Int>()
        var released: [Int] = []
        hold.referenceArrived(through: 10.05)
        hold.push(1, end: 10.1, referenceNeeded: 10.1) { released.append($0) }
        XCTAssertEqual(released, [])
        hold.referenceArrived(through: 10.15)
        // Buffer 2's own reference isn't in yet, but buffer 1's is.
        hold.push(2, end: 10.2, referenceNeeded: 10.2) { released.append($0) }
        XCTAssertEqual(released, [1])
        hold.referenceArrived(through: 10.3)
        hold.push(3, end: 10.3, referenceNeeded: 10.3) { released.append($0) }
        XCTAssertEqual(released, [1, 2, 3])
        let stats = hold.stats
        XCTAssertEqual(stats.heldBuffers, 2)
        XCTAssertEqual(stats.timedOutBuffers, 0)
        XCTAssertEqual(stats.maxHeldSeconds, 0.1, accuracy: 1e-9)
    }

    func testABufferLeavesAfterMaxHoldWithoutItsReference() {
        let hold = MicHold<Int>(configuration: .init(maxHold: 0.3))
        var released: [Int] = []
        hold.referenceArrived(through: 10.0)
        for i in 1...4 {
            hold.push(i, end: 10 + 0.1 * Double(i), referenceNeeded: 10 + 0.1 * Double(i)) { released.append($0) }
        }
        // Buffer 1 has newer mic audio 0.3 s past its end: it goes, unjudged.
        XCTAssertEqual(released, [1])
        XCTAssertEqual(hold.stats.timedOutBuffers, 1)
        XCTAssertEqual(hold.stats.maxHeldSeconds, 0.3, accuracy: 1e-9)
    }

    func testNothingWaitsForAReferenceThatStoppedComing() {
        let hold = MicHold<Int>(configuration: .init(maxHold: 0.3, staleAfter: 1))
        var released: [Int] = []
        // Never any reference (system audio failed to start).
        hold.push(1, end: 10.1, referenceNeeded: 10.1) { released.append($0) }
        XCTAssertEqual(released, [1])
        // A reference that stopped more than a second ago.
        hold.referenceArrived(through: 10.5)
        hold.push(2, end: 11.6, referenceNeeded: 11.6) { released.append($0) }
        XCTAssertEqual(released, [1, 2])
        XCTAssertEqual(hold.stats.heldBuffers, 0)
    }

    func testFlushHandsOnEverythingInOrder() {
        let hold = MicHold<Int>()
        var released: [Int] = []
        hold.referenceArrived(through: 10.0)
        hold.push(1, end: 10.1, referenceNeeded: 10.1) { released.append($0) }
        hold.push(2, end: 10.2, referenceNeeded: 10.2) { released.append($0) }
        XCTAssertEqual(released, [])
        hold.flush { released.append($0) }
        XCTAssertEqual(released, [1, 2])
        XCTAssertEqual(hold.stats.releasedBuffers, 2)
        // A mic callback still in flight after the flush isn't stranded.
        hold.push(3, end: 10.3, referenceNeeded: 10.3) { released.append($0) }
        XCTAssertEqual(released, [1, 2, 3])
        // A new capture holds again.
        hold.reset()
        XCTAssertEqual(hold.stats, MicHold<Int>.Stats())
        hold.referenceArrived(through: 20.0)
        hold.push(4, end: 20.1, referenceNeeded: 20.1) { released.append($0) }
        XCTAssertEqual(released, [1, 2, 3])
    }

    func testUnusableTimesNeverStrandABuffer() {
        let hold = MicHold<Int>()
        var released: [Int] = []
        hold.referenceArrived(through: 10.0)
        hold.push(1, end: 10.1, referenceNeeded: 10.1) { released.append($0) }
        hold.push(2, end: .nan, referenceNeeded: 10.2) { released.append($0) }
        XCTAssertEqual(released, [1, 2])
    }

    func testReferenceNeededFollowsTheCoupling() {
        // While searching, all but the last 0.15 s: the search uses only bins whose reference is in.
        XCTAssertEqual(MicHold<Int>.referenceNeeded(forMicEndingAt: 100, coupledLag: nil), 99.85, accuracy: 1e-9)
        XCTAssertEqual(MicHold<Int>.referenceNeeded(forMicEndingAt: 100, coupledLag: 0.04), 99.98, accuracy: 1e-9)
        XCTAssertEqual(MicHold<Int>.referenceNeeded(forMicEndingAt: 100, coupledLag: -0.03), 100.05, accuracy: 1e-9)
    }

    // MARK: With the gate, on the app's timing

    /// The call audio reaches the gate 150 ms after the mic audio it overlaps.
    /// Fed in arrival order, the gate learns the coupling but can't use it:
    /// every bin it would gate is unknown. Held, the bleed is gated again.
    func testLateReferenceIsGatedWhenTheMicWaits() {
        var scene = TimedScene(them: .speech(seed: 11, from: 0.2, to: 20), user: nil)
        scene.referenceDelay = 0.15

        let plain = scene.run(seed: 1, hold: nil)
        XCTAssertTrue(plain.everCoupled)
        let plainBleed = plain.fraction(attenuated: true) { t in t >= 5 && scene.isBleedOnly(at: t) }
        XCTAssertLessThan(plainBleed.value, 0.05, "\(plainBleed)")
        XCTAssertGreaterThan(plain.unknownReferenceSeconds, 5)

        let held = scene.run(seed: 1, hold: MicHold())
        XCTAssertTrue(held.everCoupled)
        let heldBleed = held.fraction(attenuated: true) { t in t >= 5 && scene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(heldBleed.value, 0.8, "\(heldBleed)")
        XCTAssertLessThan(held.unknownReferenceSeconds, 0.5)
        XCTAssertLessThanOrEqual(held.hold.maxHeldSeconds, 0.3 + 1e-6)
    }

    /// With the reference on time the hold adds no latency at all.
    func testOnTimeReferenceAddsNoLatency() {
        var scene = TimedScene(them: .speech(seed: 11, from: 0.2, to: 20), user: nil)
        scene.referenceDelay = -0.02
        let result = scene.run(seed: 1, hold: MicHold())
        XCTAssertEqual(result.hold.heldBuffers, 0)
        let bleed = result.fraction(attenuated: true) { t in t >= 5 && scene.isBleedOnly(at: t) }
        XCTAssertGreaterThanOrEqual(bleed.value, 0.8, "\(bleed)")
    }

    /// Holding only changes when the gate sees the mic, not what it decides:
    /// a mic that only hears the user still never couples, with or without a
    /// late reference, and whether the other side talks (headphones) or not.
    func testHeldUserOnlyMicNeverCouples() {
        for seed in UInt64(0)..<4 {
            for delay in [0.0, 0.15, 0.4] {
                var headphones = TimedScene(
                    them: .speech(seed: 31 + seed, from: 0.1, to: 20),
                    user: .speech(seed: 41 + seed, from: 0.3, to: 20, levelDB: -25),
                    bleedGainDB: nil
                )
                headphones.referenceDelay = delay
                let result = headphones.run(seed: 3 + seed, hold: MicHold())
                XCTAssertFalse(result.everCoupled, "seed \(seed), delay \(delay)")
                XCTAssertEqual(result.attenuatedCount, 0, "seed \(seed), delay \(delay)")
            }
        }
        var silent = TimedScene(them: nil, user: .speech(seed: 21, from: 0.1, to: 20, levelDB: -25))
        silent.referenceDelay = 0.15
        let result = silent.run(seed: 2, hold: MicHold())
        XCTAssertFalse(result.everCoupled)
        XCTAssertEqual(result.attenuatedCount, 0)
    }

    /// With headphones (no bleed) and the call audio a little late, the mic never waits.
    func testHeadphonesWithSlightlyLateCallAudioNeverWait() {
        var scene = TimedScene(
            them: .speech(seed: 91, from: 0.1, to: 20),
            user: .speech(seed: 92, from: 0.3, to: 20, levelDB: -25),
            bleedGainDB: nil
        )
        scene.referenceDelay = 0.05
        let result = scene.run(seed: 9, hold: MicHold())
        XCTAssertEqual(result.hold.heldBuffers, 0)
        XCTAssertFalse(result.everCoupled)
    }

    /// The user answering right after the other side stops still passes when
    /// the mic waits for a late reference.
    func testHeldHandoverPassesTheUsersFirstWords() {
        var them = Talk.speech(seed: 71, from: 0.05, to: 3)
        them.end(at: 3)
        var scene = TimedScene(
            them: them,
            user: Talk(bursts: [.init(start: 3.1, end: 3.6, amplitude: Talk.amplitude(dB: -40), phase: 0.3)]),
            duration: 4
        )
        scene.referenceDelay = 0.15
        let result = scene.run(seed: 5, hold: MicHold())
        XCTAssertLessThan(result.firstAttenuatedTime ?? .infinity, 3, "coupling learned before the handover")
        let firstWords = result.fraction(attenuated: false) { t in t >= 3.1 && t < 3.4 }
        XCTAssertGreaterThanOrEqual(firstWords.value, 0.9, "first 300 ms untouched: \(firstWords)")
    }
}

// MARK: - A scene on the app's timing

/// Renders a call and a mic like `Scene`, then feeds them the way the app
/// does: call audio in 512-frame IO cycles, mic audio in 4800-frame buffers,
/// each at its own arrival time, through an optional `MicHold`, into a gate
/// configured as the app configures it.
struct TimedScene {
    var them: Talk?
    var user: Talk?
    var duration: Double = 20
    /// Mic time minus call-audio time of the bleed (the coupling delay the
    /// gate should find), in the streams' own timestamps.
    var lag = 0.03
    var bleedGainDB: Double? = -20
    var rate = 48_000.0
    var referenceFrames = 512
    var micFrames = 4_800
    /// How much later than the mic the call audio reaches the gate, each
    /// counted from the end of its buffer.
    var referenceDelay = 0.0
    var micNoiseDB = -70.0
    var referenceNoiseDB = -90.0
    var origin = 5_000.0037
    var gateConfiguration = EchoGate.Configuration()

    init(them: Talk?, user: Talk?, bleedGainDB: Double? = -20, duration: Double = 20) {
        self.them = them
        self.user = user
        self.bleedGainDB = bleedGainDB
        self.duration = duration
    }

    func isBleedOnly(at t: Double) -> Bool {
        guard bleedGainDB != nil, let them, them.isActive(at: t - lag) else { return false }
        return !(user?.isActive(at: t) ?? false)
    }

    struct Outcome {
        var input: [Float]
        var output: [Float]
        var rate: Double
        var attenuatedCount: Int
        var everCoupled: Bool
        var unknownReferenceSeconds: Double
        var stats: EchoGate.Stats
        var hold: MicHold<Int>.Stats

        func fraction(attenuated: Bool, where select: (Double) -> Bool) -> Scene.Result.Fraction {
            var hits = 0, total = 0
            for i in input.indices where select(Double(i) / rate) {
                total += 1
                if (output[i] != input[i]) == attenuated { hits += 1 }
            }
            return Scene.Result.Fraction(hits: hits, total: total)
        }

        var firstAttenuatedTime: Double? {
            input.indices.first { output[$0] != input[$0] }.map { Double($0) / rate }
        }
    }

    func run(seed: UInt64, hold: MicHold<Int>?) -> Outcome {
        var rng = LCG(seed: seed)
        let count = Int(duration * rate)
        let referenceFloor = Float(Talk.amplitude(dB: referenceNoiseDB))
        var voice = Voice()
        let reference: [Float] = (0..<count).map { i in
            Float(them?.amplitude(at: Double(i) / rate) ?? 0) * voice.next(&rng) + referenceFloor * rng.noise()
        }
        let micFloor = Float(Talk.amplitude(dB: micNoiseDB))
        let gain = bleedGainDB.map { Float(Talk.amplitude(dB: $0)) } ?? 0
        let shift = Int((lag * rate).rounded())
        var userVoice = Voice()
        let input: [Float] = (0..<count).map { i in
            var sample = micFloor * rng.noise()
            if let user { sample += Float(user.amplitude(at: Double(i) / rate)) * userVoice.next(&rng) }
            let j = i - shift
            if gain > 0, j >= 0, j < count { sample += gain * reference[j] }
            return sample
        }

        let gate = EchoGate(configuration: gateConfiguration)
        var output = input
        var attenuated = 0
        var everCoupled = false
        func process(_ start: Int) {
            let frames = min(micFrames, count - start)
            attenuated += output.withUnsafeMutableBufferPointer { buffer in
                gate.process(
                    UnsafeMutableBufferPointer(rebasing: buffer[start..<(start + frames)]),
                    sampleRate: rate,
                    startTime: origin + Double(start) / rate
                )
            }
            if gate.stats.isCoupled { everCoupled = true }
        }

        var r = 0, m = 0
        while m < count {
            let referenceArrival = Double(min(r + referenceFrames, count)) / rate + referenceDelay
            let micArrival = Double(min(m + micFrames, count)) / rate
            if r < count, referenceArrival <= micArrival {
                let frames = min(referenceFrames, count - r)
                let start = origin + Double(r) / rate
                reference.withUnsafeBufferPointer { buffer in
                    gate.addReference(UnsafeBufferPointer(rebasing: buffer[r..<(r + frames)]), sampleRate: rate, startTime: start)
                }
                hold?.referenceArrived(through: start + Double(frames) / rate)
                r += frames
            } else {
                let frames = min(micFrames, count - m)
                if let hold {
                    let end = origin + Double(m + frames) / rate
                    let stats = gate.stats
                    let needed = MicHold<Int>.referenceNeeded(forMicEndingAt: end, coupledLag: stats.isCoupled ? stats.lagSeconds : nil)
                    hold.push(m, end: end, referenceNeeded: needed) { process($0) }
                } else {
                    process(m)
                }
                m += frames
            }
        }
        hold?.flush { process($0) }
        return Outcome(
            input: input,
            output: output,
            rate: rate,
            attenuatedCount: attenuated,
            everCoupled: everCoupled,
            unknownReferenceSeconds: gate.stats.unknownReferenceSeconds,
            stats: gate.stats,
            hold: hold?.stats ?? MicHold<Int>.Stats()
        )
    }
}
