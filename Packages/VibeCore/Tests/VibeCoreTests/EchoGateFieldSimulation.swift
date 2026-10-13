import Foundation
@testable import VibeCore

// A field-like simulation of a call heard through speakers:
// - Speech: syllables of 120-250 ms built from stop closures and bursts,
//   fricatives, nasals and vowel nuclei, run together into words, words into
//   sentences with 0.3-0.8 s pauses; the other side (a voice assistant) talks
//   for 10-30 s at a time, the user answers in its pauses, sometimes starts
//   before it ends or drops short words into its monologue.
// - Room and devices: delay, loss, a reverberant tail (RT60, level against
//   the direct sound), speaker coloring per sound, a loudspeaker limiter, a
//   slow AGC, mic self-noise and clipping.
// - Delivery as in the app: call audio in 512-sample IO cycles, the mic in
//   100 ms buffers, both at 48 kHz on the host clock with timestamp jitter,
//   the call audio optionally arriving late.

// MARK: - Speech

/// A talker's level over time: an RMS envelope and the speakers' coloring of
/// each sound at 1 ms resolution, and the spans of the words.
struct SpeechTrack {
    static let resolution = 0.001

    private(set) var envelope: [Float]
    /// -1...1: how the speakers color each sound (scaled by `FieldPath.colorDB`).
    private(set) var color: [Float]
    private(set) var words: [(start: Double, end: Double)] = []

    init(duration: Double) {
        let count = Int(duration / Self.resolution) + 2
        envelope = Array(repeating: 0, count: count)
        color = Array(repeating: 0, count: count)
    }

    func amplitude(at t: Double) -> Float {
        let position = t / Self.resolution
        guard position >= 0 else { return 0 }
        let i = Int(position)
        guard i + 1 < envelope.count else { return 0 }
        let f = Float(position - Double(i))
        return envelope[i] * (1 - f) + envelope[i + 1] * f
    }

    /// Linear gains for `color` scaled to ± `dB`.
    func colorGains(dB: Double) -> [Float] {
        color.map { Float(pow(10, dB * Double($0) / 20)) }
    }

    /// Inside a word (closures between its sounds included).
    func isActive(at t: Double) -> Bool {
        isActive(from: t, to: t)
    }

    /// Any word overlaps `from...to`.
    func isActive(from: Double, to: Double) -> Bool {
        var lower = 0, upper = words.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if words[mid].end < from { lower = mid + 1 } else { upper = mid }
        }
        return lower < words.count && words[lower].start <= to
    }

    // MARK: Writing

    /// Sets `t0..<t1` to `dB` relative to `peak` (louder sounds win where
    /// writes overlap), with `color`. `shape` maps 0...1 across the span to a
    /// dB offset.
    fileprivate mutating func write(
        _ t0: Double, _ t1: Double, peak: Double, dB: Double, color c: Float,
        shape: ((Double) -> Double)? = nil
    ) {
        let i0 = max(0, Int((t0 / Self.resolution).rounded()))
        let i1 = min(envelope.count - 1, Int((t1 / Self.resolution).rounded()))
        guard i1 > i0 else { return }
        for i in i0..<i1 {
            let x = Double(i - i0) / Double(max(1, i1 - i0 - 1))
            let level = peak + dB + (shape?(x) ?? 0)
            let a = Float(pow(10, level / 20))
            if a > envelope[i] {
                envelope[i] = a
                color[i] = c
            }
        }
    }

    fileprivate mutating func addWord(_ start: Double, _ end: Double) {
        words.append((start, end))
    }

    /// Sorts the words and smooths the envelope's steps (3 ms).
    fileprivate mutating func finish() {
        words.sort { $0.start < $1.start }
        let k: Float = 1 - Float(exp(-1.0 / 3.0))
        var state: Float = 0
        for i in envelope.indices {
            state += k * (envelope[i] - state)
            envelope[i] = state
        }
    }
}

/// How someone talks.
struct SpeechStyle {
    /// Vowel level (dBFS RMS) at the start of a sentence.
    var levelDB: Double
    var syllable: ClosedRange<Double> = 0.12...0.25
    /// Words per sentence and the pause after one.
    var words: ClosedRange<Int> = 6...18
    var sentencePause: ClosedRange<Double> = 0.3...0.8
    /// Chance of a short gap between words (otherwise they run together).
    var wordGapChance = 0.35
    var wordGap: ClosedRange<Double> = 0.02...0.09
    /// Chance of a comma pause after a word.
    var commaChance = 0.07
    var commaPause: ClosedRange<Double> = 0.12...0.3
    /// Chance of a hesitation ("um") before a word, and its length.
    var hesitationChance = 0.0
    var hesitation: ClosedRange<Double> = 0.2...0.5
    /// Level spread per syllable (±) and drop over a sentence.
    var stressDB = 4.0
    var declinationDB = 5.0

    /// A voice assistant: fluent, long sentences, few gaps.
    static func assistant(levelDB: Double = -20) -> SpeechStyle {
        SpeechStyle(levelDB: levelDB)
    }

    /// A person answering: shorter sentences, more gaps and hesitations.
    static func human(levelDB: Double = -24) -> SpeechStyle {
        var style = SpeechStyle(levelDB: levelDB)
        style.syllable = 0.12...0.28
        style.words = 3...12
        style.sentencePause = 0.25...0.9
        style.wordGapChance = 0.5
        style.wordGap = 0.03...0.15
        style.commaChance = 0.1
        style.hesitationChance = 0.05
        style.stressDB = 5
        return style
    }
}

extension SpeechTrack {
    /// Writes sentences from `start` until about `end`; returns when the last
    /// word ends.
    @discardableResult
    mutating func speak(from start: Double, until end: Double, style: SpeechStyle, rng: inout LCG) -> Double {
        var t = start
        var last = start
        sentences: while t < end - 0.3 {
            let count = Int(rng.uniform(Double(style.words.lowerBound)...Double(style.words.upperBound) + 0.999))
            for w in 0..<count {
                if rng.unit() < style.hesitationChance {
                    let length = rng.uniform(style.hesitation)
                    guard t + length < end else { break sentences }
                    write(t, t + length, peak: style.levelDB, dB: -8 + rng.uniform(-2...2), color: 0.3) { x in
                        -6 * pow(2 * x - 1, 8)
                    }
                    addWord(t, t + length)
                    t += length + rng.uniform(0.1...0.3)
                }
                let declination = style.declinationDB * (Double(w) / Double(max(1, count - 1)) - 0.4)
                let wordEnd = word(at: t, peak: style.levelDB - declination, style: style, isLast: w == count - 1, rng: &rng)
                guard wordEnd < end + 0.2 else {
                    // Erase the word that ran past the turn.
                    clear(t, wordEnd)
                    break sentences
                }
                addWord(t, wordEnd)
                last = wordEnd
                t = wordEnd
                if w < count - 1 {
                    if rng.unit() < style.commaChance {
                        t += rng.uniform(style.commaPause)
                    } else if rng.unit() < style.wordGapChance {
                        t += rng.uniform(style.wordGap)
                    }
                }
            }
            t += rng.uniform(style.sentencePause)
        }
        return last
    }

    /// A short word ("yeah", "mm-hm") at `start`.
    mutating func backchannel(at start: Double, style: SpeechStyle, rng: inout LCG) {
        var short = style
        short.syllable = 0.12...0.2
        let end = word(at: start, peak: style.levelDB - 3, style: short, isLast: true, syllables: 1 + Int(rng.unit() * 2), rng: &rng)
        addWord(start, end)
    }

    private mutating func clear(_ t0: Double, _ t1: Double) {
        let i0 = max(0, Int((t0 / Self.resolution).rounded()))
        let i1 = min(envelope.count - 1, Int((t1 / Self.resolution).rounded()) + 1)
        guard i1 > i0 else { return }
        for i in i0..<i1 {
            envelope[i] = 0
            color[i] = 0
        }
    }

    /// One word of 1-4 syllables: consonants (stop closures and bursts,
    /// fricatives, sonorants) around vowel nuclei. Returns its end.
    private mutating func word(
        at start: Double, peak: Double, style: SpeechStyle, isLast: Bool, syllables: Int? = nil, rng: inout LCG
    ) -> Double {
        let count: Int
        if let syllables {
            count = syllables
        } else {
            let u = rng.unit()
            count = u < 0.45 ? 1 : u < 0.75 ? 2 : u < 0.92 ? 3 : 4
        }
        var t = start
        for s in 0..<count {
            var length = rng.uniform(style.syllable)
            if isLast, s == count - 1 { length *= 1.3 }
            let stress = (s == 0 && rng.unit() < 0.5) ? 3 : rng.uniform(-style.stressDB...1)
            let level = peak + stress
            var cursor = t
            let end = t + length
            // Onset.
            if rng.unit() < 0.7 {
                cursor = consonant(at: cursor, maxLength: length * 0.35, level: level, rng: &rng)
            }
            // Coda, maybe.
            var codaStart = end
            if rng.unit() < 0.4 {
                codaStart = end - min(length * 0.25, rng.uniform(0.025...0.06))
            }
            // Nucleus: rises from -12 dB, a gentle accent, falls back to -12 dB.
            let nucleusColor = Float(rng.uniform(-0.5...0.5))
            let accent = rng.uniform(-1.5...1.5)
            let span = codaStart - cursor
            let rise = min(0.015, span / 3), fall = min(0.03, span / 3)
            write(cursor, codaStart, peak: level, dB: 0, color: nucleusColor) { x in
                let time = x * span
                var dB = accent * sin(Double.pi * x)
                if time < rise { dB -= 12 * (1 - time / rise) }
                if span - time < fall { dB -= 12 * (1 - (span - time) / fall) }
                return dB
            }
            if codaStart < end {
                _ = consonant(at: codaStart, maxLength: end - codaStart, level: level, rng: &rng)
            }
            t = end
        }
        return t
    }

    /// A consonant starting at `start`, at most `maxLength`; returns its end.
    private mutating func consonant(at start: Double, maxLength: Double, level: Double, rng: inout LCG) -> Double {
        let u = rng.unit()
        if u < 0.35 {
            // Stop: a closure (silence), then a short burst.
            let closure = min(maxLength * 0.7, rng.uniform(0.02...0.05))
            let burst = min(maxLength - closure, rng.uniform(0.008...0.015))
            write(start + closure, start + closure + burst, peak: level, dB: rng.uniform(-14...(-8)), color: 0.6)
            return start + closure + burst
        } else if u < 0.7 {
            // Fricative: noisy and faint.
            let length = min(maxLength, rng.uniform(0.04...0.09))
            write(start, start + length, peak: level, dB: rng.uniform(-28...(-16)), color: -1)
            return start + length
        } else {
            // Nasal or liquid: voiced, a little under the vowel.
            let length = min(maxLength, rng.uniform(0.025...0.06))
            write(start, start + length, peak: level, dB: rng.uniform(-12...(-6)), color: 0.3)
            return start + length
        }
    }
}

/// Two talkers taking turns: the other side (a voice assistant) talks for
/// 10-30 s, the user answers for a few seconds in its pause, sometimes
/// starting before it ends or dropping a short word into its monologue.
struct Conversation {
    struct Plan {
        var monologue: ClosedRange<Double> = 10...30
        var answer: ClosedRange<Double> = 2...8
        var gap: ClosedRange<Double> = 0.5...1.5
        var them = SpeechStyle.assistant()
        var user = SpeechStyle.human()
        /// Chance the user starts 0.3-1 s before the other side stops.
        var overlapChance = 0.25
        /// Short words from the user while the other side talks.
        var backchannelsPerMinute = 3.0
    }

    var them: SpeechTrack
    var user: SpeechTrack
    var duration: Double

    init(seed: UInt64, duration: Double, plan: Plan = Plan()) {
        var rng = LCG(seed: seed)
        var them = SpeechTrack(duration: duration)
        var user = SpeechTrack(duration: duration)
        var t = 0.3 + rng.uniform(0...0.5)
        while t < duration - 1 {
            let length = rng.uniform(plan.monologue)
            let start = t
            let themEnd = them.speak(from: start, until: min(start + length, duration), style: plan.them, rng: &rng)
            let backchannels = Int((themEnd - start) / 60 * plan.backchannelsPerMinute + rng.unit())
            for _ in 0..<backchannels where themEnd - start > 3 {
                user.backchannel(at: rng.uniform((start + 1)...(themEnd - 1.5)), style: plan.user, rng: &rng)
            }
            var answer = themEnd + rng.uniform(plan.gap)
            if rng.unit() < plan.overlapChance { answer = themEnd - rng.uniform(0.3...1.0) }
            guard answer < duration - 1 else { break }
            let userEnd = user.speak(from: answer, until: min(answer + rng.uniform(plan.answer), duration), style: plan.user, rng: &rng)
            t = max(userEnd, themEnd) + rng.uniform(plan.gap)
        }
        them.finish()
        user.finish()
        self.them = them
        self.user = user
        self.duration = duration
    }
}

// MARK: - Room, mic and delivery

/// From the speakers to the mic, and the mic itself.
struct FieldPath {
    /// Level of the direct bleed in the mic against the call audio; nil for
    /// headphones (the mic never hears the call).
    var gainDB: Double? = -6
    /// Seconds from the call audio's timestamps to the bleed in the mic's.
    var delay = 0.05
    /// Reverb: decay time and the reverberant level against the direct sound.
    var rt60 = 0.5
    var reverbDB = -3.0
    /// The speakers color each sound by up to ± this much.
    var colorDB = 2.0
    /// Loudspeaker limiter: above this level (dBFS of the call audio) the
    /// speakers compress by `limiterRatio`.
    var limiterDB: Double?
    var limiterRatio = 3.0
    /// Slow automatic gain control in the mic (or the driver), aiming at this
    /// level (dBFS), within ± `agcRangeDB`.
    var agcTargetDB: Double?
    var agcRangeDB = 10.0
    /// Mic self-noise and the room.
    var micNoiseDB = -66.0
}

/// How the app delivers the streams.
struct FieldFeed {
    var micBuffer = 4_800
    var referenceBuffer = 512
    /// Call audio arrives only up to this long before the end of each mic
    /// buffer, plus up to `latenessJitter` more per buffer.
    var lateness = 0.0
    var latenessJitter = 0.0
    /// Timestamp jitter (±) on both streams.
    var jitter = 0.0005
}

struct FieldScene {
    var conversation: Conversation
    var path = FieldPath()
    var feed = FieldFeed()
    var rate = 48_000.0
    /// Host clock time of scene time 0, off the bin grid.
    var origin = 52_731.004_3

    var duration: Double { conversation.duration }
    var them: SpeechTrack { conversation.them }
    var user: SpeechTrack { conversation.user }

    /// The mic carries the other side's voice (direct sound) and not the user.
    func isBleedOnly(at t: Double) -> Bool {
        path.gainDB != nil && them.isActive(at: t - path.delay) && !user.isActive(from: t - 0.05, to: t + 0.05)
    }

    /// The user talks and the mic carries no bleed (nor its reverb tail) there.
    func isUserAlone(at t: Double) -> Bool {
        user.isActive(at: t) && !them.isActive(from: t - path.delay - 0.4, to: t - path.delay + 0.05)
    }

    struct Result {
        var input: [Float]
        var output: [Float]
        var rate: Double
        var stats: EchoGate.Stats

        /// Share of the samples selected by `select` that were attenuated.
        func gated(where select: (Double) -> Bool) -> Scene.Result.Fraction {
            var hits = 0, total = 0
            for i in input.indices where select(Double(i) / rate) {
                total += 1
                if output[i] != input[i] { hits += 1 }
            }
            return .init(hits: hits, total: total)
        }
    }

    /// Renders both streams and feeds them to `gate` the way the app does
    /// (with the app's configuration by default). `afterEachBuffer` gets the
    /// scene time at the end of each mic buffer, to poll `gate.stats`.
    func run(
        seed: UInt64,
        gate: EchoGate = EchoGate(configuration: .init(minLag: -0.05)),
        afterEachBuffer: ((Double) -> Void)? = nil
    ) -> Result {
        var rng = LCG(seed: seed)
        let reference = renderReference(&rng)
        let input = renderMic(reference: reference, &rng)
        var output = input
        var r = 0, m = 0
        while m < output.count {
            let micCount = min(feed.micBuffer, output.count - m)
            let micEnd = Double(m + micCount) / rate
            let lateness = feed.lateness + rng.uniform(0...feed.latenessJitter)
            while r < reference.count, Double(r) / rate < micEnd - lateness {
                let count = min(feed.referenceBuffer, reference.count - r)
                let start = origin + Double(r) / rate + rng.uniform(-feed.jitter...feed.jitter)
                reference.withUnsafeBufferPointer { buffer in
                    gate.addReference(UnsafeBufferPointer(rebasing: buffer[r..<(r + count)]), sampleRate: rate, startTime: start)
                }
                r += count
            }
            let start = origin + Double(m) / rate + rng.uniform(-feed.jitter...feed.jitter)
            output.withUnsafeMutableBufferPointer { buffer in
                _ = gate.process(UnsafeMutableBufferPointer(rebasing: buffer[m..<(m + micCount)]), sampleRate: rate, startTime: start)
            }
            m += micCount
            afterEachBuffer?(micEnd)
        }
        return Result(input: input, output: output, rate: rate, stats: gate.stats)
    }

    private func renderReference(_ rng: inout LCG) -> [Float] {
        let count = Int(duration * rate)
        let floor = Float(Talk.amplitude(dB: -90))
        var voice = Voice()
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = them.amplitude(at: Double(i) / rate) * voice.next(&rng) + floor * rng.noise()
        }
        return samples
    }

    private func renderMic(reference: [Float], _ rng: inout LCG) -> [Float] {
        let count = Int(duration * rate)
        let noise = Float(Talk.amplitude(dB: path.micNoiseDB))
        var voice = Voice()
        var reverb = Reverb(room: Room(rt60: path.rt60, reverbDB: path.reverbDB), sampleRate: rate)
        let gain = path.gainDB.map { Float(Talk.amplitude(dB: $0)) }
        let delaySamples = path.delay * rate
        let colorGains = them.colorGains(dB: path.colorDB)
        // Limiter: power follower, 3 ms attack, 60 ms release.
        let attack = Float(1 - exp(-1 / (0.003 * rate)))
        let release = Float(1 - exp(-1 / (0.06 * rate)))
        var limiterPower: Float = 0
        let limiterThreshold = path.limiterDB.map { Float(pow(10, $0 / 10)) }
        let limiterExponent = Float(1 / path.limiterRatio - 1) / 2
        // AGC: power over ~0.5 s, gain eased in over ~1 s.
        let agcPowerRate = Float(1 - exp(-1 / (0.5 * rate)))
        let agcGainRate = Float(1 - exp(-1 / (1.0 * rate)))
        var agcPower: Float = 1e-6
        var agcGain: Float = 1
        let agcTarget = path.agcTargetDB.map { Float(pow(10, $0 / 10)) }
        let agcRange = Float(pow(10, path.agcRangeDB / 20))
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            var sample = noise * rng.noise() + user.amplitude(at: t) * voice.next(&rng)
            if let gain {
                let position = Double(i) - delaySamples
                let index = Int(position.rounded(.down))
                var bleed: Float = 0
                if index >= 0, index + 1 < reference.count {
                    let fraction = Float(position - Double(index))
                    bleed = reference[index] * (1 - fraction) + reference[index + 1] * fraction
                    let c = Int(((t - path.delay) / SpeechTrack.resolution).rounded())
                    if c >= 0, c < colorGains.count { bleed *= colorGains[c] }
                }
                if let threshold = limiterThreshold {
                    let power = bleed * bleed
                    limiterPower += (power > limiterPower ? attack : release) * (power - limiterPower)
                    if limiterPower > threshold { bleed *= pow(limiterPower / threshold, limiterExponent) }
                }
                bleed *= gain
                sample += bleed + reverb.process(bleed)
            }
            if let target = agcTarget {
                agcPower += agcPowerRate * (sample * sample - agcPower)
                let wanted = min(agcRange, max(1 / agcRange, (target / max(agcPower, 1e-12)).squareRoot()))
                agcGain += agcGainRate * (wanted - agcGain)
                sample *= agcGain
            }
            samples[i] = min(1, max(-1, sample))
        }
        return samples
    }
}
