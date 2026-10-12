import Foundation

/// Removes the other side's voice that leaks from the speakers into the mic.
///
/// With speakers instead of headphones, "Them" plays from the speakers and the
/// mic hears it again, so the "You" transcript repeats the other side's words.
/// The call's audio is captured separately (the reference), so the gate knows
/// what the speakers are playing. It is a level-based echo suppressor: a
/// half-duplex gate with a double-talk detector. It never subtracts or filters
/// anything, so it works in any language and never colors the user's voice; it
/// only silences stretches of mic audio that carry nothing but the bleed.
///
/// Both streams are reduced to energy levels in short bins (10 ms) on the clock
/// they share, then:
/// 1. Coupling. Bleed reaches the mic with a fixed delay and a fixed loss, so
///    at the right delay the mic's level follows the reference's level dB for
///    dB. Every 0.1 s the gate searches the delays for the best correlation of
///    the levels over the last 1.5 s, counting only bins where the reference
///    is active. A window confirms a coupling only when that correlation is
///    strong, the mic tracks the reference with unit slope (mic minus reference
///    barely moves while the reference does), and the mic is quiet where the
///    reference has been quiet. Two voices can line up by chance for a second
///    or so; they don't keep doing it. So a new coupling arms the gate only
///    when a later window, on new data, finds it again at the same delay and
///    gain (about 2.5 s of the other side talking; 3 s or so with heavy
///    reverb). In simulation, a mic that only hears the user never coupled.
/// 2. Gate. While a coupling is fresh, a mic bin is bleed when the reference was
///    active at that delay and the mic is no louder than the predicted bleed
///    plus `doubleTalkMarginDB`. Anything louder is the user talking over the
///    other side and passes. When the other side stops, the predicted bleed
///    drops with the reference, so the user's first words pass too.
///
/// Conservative by design, since a false gate eats the user's words while a
/// missed gate only leaves a duplicate the text filter may still catch: missing
/// reference bins are unknown (never silence), silence in the reference never
/// gates, samples of bins that aren't bleed are never touched (the gain ramps
/// happen inside gated bins), and a coupling that the mic contradicts (much
/// quieter than the bleed it predicts: headphones plugged in, volume lowered)
/// is dropped at once. The flip side: the prediction follows the reference
/// within a bin, so room reverb that lingers after a syllable passes.
///
/// Thread safe: an `NSLock` guards all state, so the reference and the mic can
/// arrive on different threads. `process` does no allocation and no logging.
public final class EchoGate: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Length of the energy bins on the shared clock, in seconds.
        public var binDuration: Double
        /// Seconds of bins kept per stream.
        public var history: Double
        /// Smallest delay searched (mic time minus reference time; negative means the mic leads).
        public var minLag: Double
        /// Largest delay searched.
        public var maxLag: Double
        /// Seconds of mic bins used to find the coupling.
        public var correlationWindow: Double
        /// Correlation of the levels needed to confirm a coupling.
        public var minCorrelation: Double
        /// Mic louder than the predicted bleed by this much means the user is talking.
        public var doubleTalkMarginDB: Double
        /// A reference quieter than this (dBFS) has nothing to leak.
        public var activeFloorDB: Double
        /// A confirmed coupling stays valid this long without reconfirmation.
        public var couplingHold: Double
        /// Gain applied to gated samples (0 silences them).
        public var attenuation: Float

        public init(
            binDuration: Double = 0.01,
            history: Double = 4,
            minLag: Double = -0.05,
            maxLag: Double = 0.40,
            correlationWindow: Double = 1.5,
            minCorrelation: Double = 0.6,
            doubleTalkMarginDB: Double = 6,
            activeFloorDB: Double = -50,
            couplingHold: Double = 20,
            attenuation: Float = 0
        ) {
            self.binDuration = binDuration
            self.history = history
            self.minLag = minLag
            self.maxLag = maxLag
            self.correlationWindow = correlationWindow
            self.minCorrelation = minCorrelation
            self.doubleTalkMarginDB = doubleTalkMarginDB
            self.activeFloorDB = activeFloorDB
            self.couplingHold = couplingHold
            self.attenuation = attenuation
        }
    }

    public struct Stats: Equatable, Sendable {
        /// Seconds of mic audio processed.
        public var processedSeconds: Double
        /// Seconds of mic audio attenuated (any sample with a gain below 1).
        public var gatedSeconds: Double
        /// A confirmed coupling is fresh, so the gate is armed.
        public var isCoupled: Bool
        /// Delay of the last confirmed coupling (mic time minus reference time).
        public var lagSeconds: Double?
        /// Level of the bleed relative to the reference, from the last confirmed coupling.
        public var couplingGainDB: Double?
        /// Correlation of the levels when the coupling was last confirmed.
        public var correlation: Double?

        public init(
            processedSeconds: Double = 0,
            gatedSeconds: Double = 0,
            isCoupled: Bool = false,
            lagSeconds: Double? = nil,
            couplingGainDB: Double? = nil,
            correlation: Double? = nil
        ) {
            self.processedSeconds = processedSeconds
            self.gatedSeconds = gatedSeconds
            self.isCoupled = isCoupled
            self.lagSeconds = lagSeconds
            self.couplingGainDB = couplingGainDB
            self.correlation = correlation
        }
    }

    let configuration: Configuration

    // Tuning that isn't worth a public knob.
    /// The reference must vary at least this much (std, dB) over its active bins.
    static let minReferenceSpreadDB = 3.0
    /// Unit-slope check: the lower spread of mic minus reference (median minus
    /// 20th percentile) must stay below this share of the reference's own
    /// spread (median absolute deviation).
    static let maxResidualSpreadRatio = 0.5
    /// Share of the window that must have both levels, and share of those where
    /// the reference must be active.
    static let minKnownShare = 0.8
    static let minActiveShare = 0.3
    /// Quiet-bin check: bins where the reference has been silent this long, the
    /// margin the mic must sit below its active level there, how many such bins
    /// are needed and what share of them must pass.
    static let quietLeadBins = 10
    static let quietMarginDB = 6.0
    static let minQuietBins = 10
    static let minQuietShare = 0.8
    /// A new gain estimate within this many dB of the current one is smoothed in;
    /// a bigger change (volume moved) replaces it.
    static let gainJumpDB = 6.0
    static let gainSmoothing = 0.3
    /// A new coupling arms the gate only when seen again (delay within a bin,
    /// gain within `candidateGainToleranceDB`) in a window ending a full window
    /// later, so on new data, within `candidateExpiry` seconds of the last
    /// sighting. Chance alignments of two voices don't repeat; a room does.
    /// Two strong sightings (correlation and lower spread past the values
    /// below, which chance alignments in simulation never reached: their best
    /// correlation was 0.83) need only half a window, so a clear coupling arms
    /// sooner.
    static let candidateGainToleranceDB = 3.0
    static let candidateExpiry = 6.0
    static let maxCandidates = 4
    static let strongCorrelation = 0.9
    static let strongResidualSpreadRatio = 0.25
    /// Mic this far below the bleed it should carry contradicts the coupling.
    static let contradictionDB = 10.0
    /// Seconds between coupling searches.
    static let evaluationInterval = 0.1
    /// Gain ramp length in seconds, kept inside gated bins.
    static let rampDuration = 0.002
    /// A bin needs this share of its samples before its level is trusted.
    static let minBinFill = 0.25

    private struct Coupling {
        var lagBins: Int
        var gainDB: Double
        var correlation: Double
        /// Last mic bin of the window that confirmed it.
        var confirmedBin: Int
    }

    /// A coupling seen in one window, waiting to be seen again at the same
    /// delay and gain on new data before it arms the gate.
    private struct Candidate {
        var lagBins: Int
        var gainDB: Double
        var firstBin: Int
        var lastBin: Int
        /// First sighting that was strong evidence, if any.
        var firstStrongBin: Int?
    }

    /// What a window that passed every check says about the coupling.
    private struct Sighting {
        var lagBins: Int
        var gainDB: Double
        var correlation: Double
        var isStrong: Bool
    }

    private let lock = NSLock()

    private let binDuration: Double
    private let windowBins: Int
    private let minLagBins: Int
    private let maxLagBins: Int
    private let holdBins: Int
    private let evaluationBins: Int
    private let attenuation: Float

    private var reference: EnergyRing
    private var mic: EnergyRing
    private var referenceSamplesPerBin = 480.0
    private var micSamplesPerBin = 480.0

    private var coupling: Coupling?
    /// A few candidates at once: with reverb the best delay wanders by a bin or
    /// two, and one stray sighting must not erase the evidence gathered so far.
    private var candidates: [Candidate] = []
    private let candidateExpiryBins: Int
    private var lastEvaluatedBin: Int?
    private var newestMicBin: Int?
    private var rampGain: Float = 1
    private var processedSeconds = 0.0
    private var gatedSeconds = 0.0

    // Scratch for the coupling search, allocated once.
    private let micLevels: UnsafeMutablePointer<Double>
    private let referenceLevels: UnsafeMutablePointer<Double>
    private let scratchA: UnsafeMutablePointer<Double>
    private let scratchB: UnsafeMutablePointer<Double>
    private let referenceSpan: Int

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        func finite(_ value: Double, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        let bin = finite(configuration.binDuration, 0.01, 0.001...0.1)
        binDuration = bin
        let lagA = Int((finite(configuration.minLag, -0.05, -2...2) / bin).rounded())
        let lagB = Int((finite(configuration.maxLag, 0.40, -2...2) / bin).rounded())
        minLagBins = min(lagA, lagB)
        maxLagBins = max(lagA, lagB)
        windowBins = max(20, Int((finite(configuration.correlationWindow, 1.5, 0...30) / bin).rounded()))
        holdBins = Int((finite(configuration.couplingHold, 20, 0...86_400) / bin).rounded())
        evaluationBins = max(1, Int((Self.evaluationInterval / bin).rounded()))
        candidateExpiryBins = Int((Self.candidateExpiry / bin).rounded())
        let attenuation = configuration.attenuation
        self.attenuation = attenuation.isFinite ? min(max(attenuation, 0), 1) : 0

        referenceSpan = windowBins + maxLagBins - minLagBins
        let historyBins = Int((finite(configuration.history, 4, 0...120) / bin).rounded(.up))
        let capacity = max(historyBins, referenceSpan + 2) + 2
        reference = EnergyRing(capacity: capacity)
        mic = EnergyRing(capacity: capacity)

        micLevels = .allocate(capacity: windowBins)
        referenceLevels = .allocate(capacity: referenceSpan)
        scratchA = .allocate(capacity: windowBins)
        scratchB = .allocate(capacity: windowBins)
        candidates.reserveCapacity(Self.maxCandidates)
    }

    deinit {
        micLevels.deallocate()
        referenceLevels.deallocate()
        scratchA.deallocate()
        scratchB.deallocate()
    }

    // MARK: Public API

    /// Reference (call audio) mono samples; `startTime` is the capture time of
    /// the first sample in seconds on a clock shared with the mic.
    public func addReference(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, startTime: Double) {
        guard let base = samples.baseAddress,
              let geometry = BinGeometry(count: samples.count, sampleRate: sampleRate, startTime: startTime, binDuration: binDuration)
        else { return }
        lock.lock()
        defer { lock.unlock() }
        if reference.isFarBehind(geometry.firstBin) { reference.reset() }
        referenceSamplesPerBin = geometry.samplesPerBin
        geometry.forEachSegment { bin, lower, upper, _ in
            reference.add(bin: bin, sumOfSquares: Self.sumOfSquares(base, lower, upper), count: upper - lower)
        }
    }

    /// Mic mono samples, attenuated in place where they carry only bleed.
    /// Returns how many samples were attenuated.
    @discardableResult
    public func process(_ samples: UnsafeMutableBufferPointer<Float>, sampleRate: Double, startTime: Double) -> Int {
        guard let base = samples.baseAddress,
              let geometry = BinGeometry(count: samples.count, sampleRate: sampleRate, startTime: startTime, binDuration: binDuration)
        else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        if mic.isFarBehind(geometry.firstBin) {
            // The clock went back: start over rather than mix two timelines.
            mic.reset()
            coupling = nil
            candidates.removeAll(keepingCapacity: true)
            lastEvaluatedBin = nil
            newestMicBin = nil
            rampGain = 1
        }
        micSamplesPerBin = geometry.samplesPerBin

        // 1. Levels of the incoming audio (before any gating).
        var lastBin = geometry.firstBin
        geometry.forEachSegment { bin, lower, upper, _ in
            mic.add(bin: bin, sumOfSquares: Self.sumOfSquares(UnsafePointer(base), lower, upper), count: upper - lower)
            lastBin = bin
        }
        newestMicBin = max(newestMicBin ?? lastBin, lastBin)

        // 2. Coupling, over complete bins only.
        let windowEnd = lastBin - 1
        if let last = lastEvaluatedBin, windowEnd >= last, windowEnd - last < evaluationBins {
            // Searched recently enough.
        } else {
            lastEvaluatedBin = windowEnd
            evaluateCoupling(through: windowEnd)
        }

        // 3. Gate.
        var attenuated = 0
        if let coupling, isFresh(coupling, at: lastBin) {
            attenuated = gate(base, geometry, coupling)
        } else {
            rampGain = 1
        }

        processedSeconds += Double(samples.count) / sampleRate
        gatedSeconds += Double(attenuated) / sampleRate
        return attenuated
    }

    public var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        var stats = Stats(processedSeconds: processedSeconds, gatedSeconds: gatedSeconds)
        if let coupling {
            stats.isCoupled = newestMicBin.map { isFresh(coupling, at: $0) } ?? false
            stats.lagSeconds = Double(coupling.lagBins) * binDuration
            stats.couplingGainDB = coupling.gainDB
            stats.correlation = coupling.correlation
        }
        return stats
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        reference.reset()
        mic.reset()
        coupling = nil
        candidates.removeAll(keepingCapacity: true)
        lastEvaluatedBin = nil
        newestMicBin = nil
        rampGain = 1
        processedSeconds = 0
        gatedSeconds = 0
    }

    // MARK: Convenience

    public func addReference(_ samples: [Float], sampleRate: Double, startTime: Double) {
        samples.withUnsafeBufferPointer { addReference($0, sampleRate: sampleRate, startTime: startTime) }
    }

    @discardableResult
    public func process(_ samples: inout [Float], sampleRate: Double, startTime: Double) -> Int {
        samples.withUnsafeMutableBufferPointer { process($0, sampleRate: sampleRate, startTime: startTime) }
    }

    // MARK: Coupling

    private func isFresh(_ coupling: Coupling, at bin: Int) -> Bool {
        let age = bin - coupling.confirmedBin
        return age >= 0 && age <= holdBins
    }

    private var micMinCount: Int { max(1, Int(micSamplesPerBin * Self.minBinFill)) }
    private var referenceMinCount: Int { max(1, Int(referenceSamplesPerBin * Self.minBinFill)) }

    /// Searches the delays over the window ending at `end` (a mic bin) and
    /// confirms, refreshes or drops the coupling.
    private func evaluateCoupling(through end: Int) {
        let window = windowBins
        let first = end - window + 1
        let referenceFirst = first - maxLagBins
        let micMin = micMinCount
        let referenceMin = referenceMinCount
        var knownMic = 0
        for j in 0..<window {
            micLevels[j] = mic.level(first + j, minCount: micMin)
            if !micLevels[j].isNaN { knownMic += 1 }
        }
        let minKnown = Int((Double(window) * Self.minKnownShare).rounded(.up))
        guard knownMic >= minKnown else { return }
        for k in 0..<referenceSpan {
            referenceLevels[k] = reference.level(referenceFirst + k, minCount: referenceMin)
        }

        // Mic bin j pairs with reference index j + maxLagBins - lag.
        let floor = configuration.activeFloorDB
        let minSpread = Self.minReferenceSpreadDB * Self.minReferenceSpreadDB
        var bestCorrelation = -Double.infinity
        var bestLag = 0
        for lag in minLagBins...maxLagBins {
            let offset = maxLagBins - lag
            var known = 0
            var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            for j in 0..<window {
                let y = micLevels[j]
                let x = referenceLevels[j + offset]
                if y.isNaN || x.isNaN { continue }
                known += 1
                if x < floor { continue }
                n += 1
                sx += x
                sy += y
                sxx += x * x
                syy += y * y
                sxy += x * y
            }
            guard known >= minKnown,
                  n >= Double(known) * Self.minActiveShare,
                  n >= Double(window) * Self.minActiveShare
            else { continue }
            let mx = sx / n, my = sy / n
            let vx = sxx / n - mx * mx
            let vy = syy / n - my * my
            guard vx >= minSpread, vy > 1e-9 else { continue }
            let r = (sxy / n - mx * my) / (vx * vy).squareRoot()
            if r > bestCorrelation {
                bestCorrelation = r
                bestLag = lag
            }
        }

        var refreshed = false
        if bestCorrelation >= configuration.minCorrelation,
           let sighting = verify(lag: bestLag, correlation: bestCorrelation, window: window) {
            refreshed = accept(sighting, end: end)
        }
        if !refreshed, let current = coupling, isFresh(current, at: end), isContradicted(current, window: window) {
            coupling = nil
        }
    }

    /// Takes a window that passed every check. Returns whether it confirmed
    /// (refreshed or armed) the coupling in force.
    private func accept(_ sighting: Sighting, end: Int) -> Bool {
        let lag = sighting.lagBins, gain = sighting.gainDB
        // The coupling we know (even past its hold): refresh it.
        if let current = coupling, abs(lag - current.lagBins) <= 1, abs(gain - current.gainDB) <= Self.gainJumpDB {
            let smoothed = current.gainDB + Self.gainSmoothing * (gain - current.gainDB)
            coupling = Coupling(lagBins: lag, gainDB: smoothed, correlation: sighting.correlation, confirmedBin: end)
            candidates.removeAll(keepingCapacity: true)
            return true
        }
        // A new one must show up again on new data.
        candidates.removeAll { end - $0.lastBin > candidateExpiryBins || end < $0.lastBin }
        var matched = false
        for i in candidates.indices {
            let seen = candidates[i]
            guard abs(lag - seen.lagBins) <= 1, abs(gain - seen.gainDB) <= Self.candidateGainToleranceDB else { continue }
            matched = true
            let strongSpan = sighting.isStrong ? seen.firstStrongBin.map { end - $0 } ?? -1 : -1
            if end - seen.firstBin >= windowBins || strongSpan >= windowBins / 2 {
                coupling = Coupling(lagBins: lag, gainDB: gain, correlation: sighting.correlation, confirmedBin: end)
                candidates.removeAll(keepingCapacity: true)
                return true
            }
            candidates[i].lastBin = end
            if sighting.isStrong, seen.firstStrongBin == nil { candidates[i].firstStrongBin = end }
        }
        if !matched {
            if candidates.count >= Self.maxCandidates,
               let oldest = candidates.indices.min(by: { candidates[$0].lastBin < candidates[$1].lastBin }) {
                candidates.remove(at: oldest)
            }
            candidates.append(Candidate(
                lagBins: lag,
                gainDB: gain,
                firstBin: end,
                lastBin: end,
                firstStrongBin: sighting.isStrong ? end : nil
            ))
        }
        return false
    }

    /// Checks the coupling at `lag` beyond the correlation; nil when it fails:
    /// - Unit slope: the mic follows the reference dB for dB, so mic minus
    ///   reference stays put while the reference moves. Only the lower side of
    ///   its spread counts: reverb, the user talking over the bleed and the
    ///   mic's noise floor all add energy, but nothing makes the mic quieter
    ///   than the bleed it carries.
    /// - Quiet when the reference is quiet: where the reference has been silent
    ///   for a while, the mic sits well below its level in the active bins.
    ///   Speech that merely happens to line up with the reference fails this.
    /// The gain is the median of mic minus reference over active bins.
    private func verify(lag: Int, correlation: Double, window: Int) -> Sighting? {
        let offset = maxLagBins - lag
        let floor = configuration.activeFloorDB
        var n = 0
        for j in 0..<window {
            let y = micLevels[j]
            let x = referenceLevels[j + offset]
            if y.isNaN || x.isNaN || x < floor { continue }
            scratchA[n] = y - x
            scratchB[n] = x
            n += 1
        }
        guard n >= 3 else { return nil }
        let gain = Self.median(scratchA, n)
        let lowerSpread = gain - Self.select(scratchA, n, n / 5)
        let referenceSpread = Self.medianAbsoluteDeviation(scratchB, n, around: Self.median(scratchB, n))
        guard referenceSpread > 0 else { return nil }
        let spreadRatio = lowerSpread / referenceSpread
        guard spreadRatio <= Self.maxResidualSpreadRatio else { return nil }

        // The mic's level while the reference is active...
        var m = 0
        for j in 0..<window {
            let y = micLevels[j]
            let x = referenceLevels[j + offset]
            if y.isNaN || x.isNaN || x < floor { continue }
            scratchA[m] = y
            m += 1
        }
        let activeMic = Self.median(scratchA, m)
        // ...against its level where the reference has been silent a while.
        var quiet = 0, quieter = 0
        for j in 0..<window where !micLevels[j].isNaN {
            let k = j + offset
            guard k - Self.quietLeadBins >= 0, k + 1 < referenceSpan else { continue }
            var silent = true
            for i in (k - Self.quietLeadBins)...(k + 1) {
                let x = referenceLevels[i]
                if x.isNaN || x >= floor {
                    silent = false
                    break
                }
            }
            guard silent else { continue }
            quiet += 1
            if micLevels[j] <= activeMic - Self.quietMarginDB { quieter += 1 }
        }
        guard quiet >= Self.minQuietBins, Double(quieter) >= Self.minQuietShare * Double(quiet) else { return nil }
        let isStrong = correlation >= Self.strongCorrelation && spreadRatio <= Self.strongResidualSpreadRatio
        return Sighting(lagBins: lag, gainDB: gain, correlation: correlation, isStrong: isStrong)
    }

    /// The mic is much quieter than the bleed the coupling predicts, in most bins
    /// where that bleed would stand clear of the mic's noise floor.
    private func isContradicted(_ coupling: Coupling, window: Int) -> Bool {
        var n = 0
        for j in 0..<window where !micLevels[j].isNaN {
            scratchA[n] = micLevels[j]
            n += 1
        }
        guard n >= 3 else { return false }
        let micFloor = Self.select(scratchA, n, n / 10)
        let offset = maxLagBins - coupling.lagBins
        let floor = configuration.activeFloorDB
        var eligible = 0, under = 0
        for j in 0..<window {
            let y = micLevels[j]
            let x = referenceLevels[j + offset]
            if y.isNaN || x.isNaN || x < floor { continue }
            let predicted = x + coupling.gainDB
            guard predicted >= micFloor + Self.contradictionDB else { continue }
            eligible += 1
            if y < predicted - Self.contradictionDB { under += 1 }
        }
        return eligible >= 20 && under * 2 >= eligible
    }

    // MARK: Gate

    /// Mic `bin` carries only bleed: the reference is active around the delay
    /// and the mic is no louder than the predicted bleed (the loudest known
    /// reference bin within one bin of the delay, since the timestamps jitter,
    /// plus the coupling gain) plus the double-talk margin. Unknown levels
    /// never gate.
    private func isBleed(_ bin: Int, _ coupling: Coupling, micMin: Int, referenceMin: Int) -> Bool {
        let micLevel = mic.level(bin, minCount: micMin)
        if micLevel.isNaN { return false }
        var loudest = -Double.infinity
        for offset in -1...1 {
            let level = reference.level(bin - coupling.lagBins + offset, minCount: referenceMin)
            if !level.isNaN, level > loudest { loudest = level }
        }
        guard loudest >= configuration.activeFloorDB else { return false }
        return micLevel <= loudest + coupling.gainDB + configuration.doubleTalkMarginDB
    }

    /// Attenuates the bleed bins of the buffer. Gains ramp inside gated bins
    /// only: down from wherever the previous sample was, and back up to 1 by the
    /// end of the bin when the next bin passes (or isn't known yet).
    private func gate(_ base: UnsafeMutablePointer<Float>, _ geometry: BinGeometry, _ coupling: Coupling) -> Int {
        let count = geometry.count
        let floorGain = attenuation
        let rampLength = max(1, Int(Self.rampDuration * geometry.sampleRate))
        let step = (1 - floorGain) / Float(rampLength)
        let micMin = 1
        let referenceMin = referenceMinCount
        var gain = rampGain
        var attenuated = 0
        var lookaheadBin = Int.min
        var lookahead = false

        geometry.forEachSegment { bin, lower, upper, binEnd in
            let bleed = lookaheadBin == bin ? lookahead : isBleed(bin, coupling, micMin: micMin, referenceMin: referenceMin)
            guard bleed else {
                gain = 1
                return
            }
            var nextBleed = false
            if binEnd < count {
                nextBleed = isBleed(bin + 1, coupling, micMin: micMin, referenceMin: referenceMin)
                lookaheadBin = bin + 1
                lookahead = nextBleed
            }
            for i in lower..<upper {
                var g = gain - step
                if g < floorGain { g = floorGain }
                if !nextBleed {
                    let remaining = binEnd - i
                    if remaining <= rampLength {
                        let up = floorGain + (1 - floorGain) * (1 - Float(remaining) / Float(rampLength))
                        if up > g { g = up }
                    }
                }
                gain = g
                base[i] *= g
                if g < 1 { attenuated += 1 }
            }
        }
        rampGain = gain
        return attenuated
    }

    // MARK: Helpers

    @inline(__always)
    private static func sumOfSquares(_ base: UnsafePointer<Float>, _ lower: Int, _ upper: Int) -> Double {
        var sum: Float = 0
        var total = 0.0
        var i = lower
        while i < upper {
            // Accumulate in Float over short runs, in Double across them.
            let end = min(upper, i + 64)
            sum = 0
            while i < end {
                let v = base[i]
                sum += v.isFinite ? v * v : 0
                i += 1
            }
            total += Double(sum)
        }
        return total
    }

    static func median(_ values: UnsafeMutablePointer<Double>, _ count: Int) -> Double {
        select(values, count, count / 2)
    }

    /// Median of |value - center|; overwrites `values`.
    static func medianAbsoluteDeviation(_ values: UnsafeMutablePointer<Double>, _ count: Int, around center: Double) -> Double {
        for i in 0..<count { values[i] = abs(values[i] - center) }
        return select(values, count, count / 2)
    }

    /// The `k`-th smallest of `values[0..<count]` (Hoare quickselect, in place, no NaNs).
    static func select(_ values: UnsafeMutablePointer<Double>, _ count: Int, _ k: Int) -> Double {
        var lower = 0
        var upper = count - 1
        while upper > lower {
            let a = values[lower], b = values[lower + (upper - lower) / 2], c = values[upper]
            let pivot = max(min(a, b), min(max(a, b), c))
            var i = lower, j = upper
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    let t = values[i]
                    values[i] = values[j]
                    values[j] = t
                    i += 1
                    j -= 1
                }
            }
            if k <= j {
                upper = j
            } else if k >= i {
                lower = i
            } else {
                return values[k]
            }
        }
        return values[k]
    }
}

// MARK: - Bins

/// How a buffer's samples fall into bins on the absolute clock: sample `i` is
/// at `startTime + i / sampleRate` and belongs to bin `floor(time / binDuration)`.
struct BinGeometry {
    let count: Int
    let sampleRate: Double
    let samplesPerBin: Double
    let firstBin: Int
    /// Position of the first sample inside its bin, 0..<1.
    let phase: Double

    init?(count: Int, sampleRate: Double, startTime: Double, binDuration: Double) {
        guard count > 0, sampleRate.isFinite, startTime.isFinite, binDuration > 0 else { return nil }
        let samplesPerBin = sampleRate * binDuration
        guard samplesPerBin >= 1 else { return nil }
        let position = startTime / binDuration
        guard abs(position) < 1e15 else { return nil }
        let whole = position.rounded(.down)
        self.count = count
        self.sampleRate = sampleRate
        self.samplesPerBin = samplesPerBin
        self.firstBin = Int(whole)
        self.phase = position - whole
    }

    /// Calls `body(bin, lower, upper, binEnd)` for each bin the buffer touches,
    /// in order, where `lower..<upper` are the bin's samples in this buffer and
    /// `binEnd` is the index where the next bin starts (may lie past the buffer).
    @inline(__always)
    func forEachSegment(_ body: (Int, Int, Int, Int) -> Void) {
        var lower = 0
        var bin = firstBin
        var boundary = 1.0
        while lower < count {
            let binEnd = Int(((boundary - phase) * samplesPerBin).rounded(.up))
            let upper = min(binEnd, count)
            if upper > lower {
                body(bin, lower, upper, binEnd)
                lower = upper
            }
            bin += 1
            boundary += 1
        }
    }
}

/// Sum of squares and sample count per bin, in a ring keyed by bin index. Each
/// slot remembers its bin, so a stale slot reads as missing, never as silence.
struct EnergyRing {
    let capacity: Int
    private var bins: [Int]
    private var sums: [Double]
    private var counts: [Int]
    private(set) var newest: Int?

    init(capacity: Int) {
        self.capacity = capacity
        bins = Array(repeating: Int.min, count: capacity)
        sums = Array(repeating: 0, count: capacity)
        counts = Array(repeating: 0, count: capacity)
    }

    mutating func reset() {
        for i in 0..<capacity {
            bins[i] = Int.min
            sums[i] = 0
            counts[i] = 0
        }
        newest = nil
    }

    /// A bin this far behind the newest one can't be stored: the clock went back.
    func isFarBehind(_ bin: Int) -> Bool {
        guard let newest else { return false }
        return bin < newest - capacity
    }

    @inline(__always)
    private func slot(_ bin: Int) -> Int {
        let r = bin % capacity
        return r < 0 ? r + capacity : r
    }

    mutating func add(bin: Int, sumOfSquares: Double, count: Int) {
        let s = slot(bin)
        if bins[s] == bin {
            sums[s] += sumOfSquares
            counts[s] += count
        } else if bins[s] < bin {
            bins[s] = bin
            sums[s] = sumOfSquares
            counts[s] = count
        } else {
            return // older than the history
        }
        if newest == nil || bin > newest! { newest = bin }
    }

    /// Level in dBFS (floored at -100), or NaN when the bin is missing or has
    /// fewer than `minCount` samples.
    @inline(__always)
    func level(_ bin: Int, minCount: Int) -> Double {
        let s = slot(bin)
        guard bins[s] == bin, counts[s] >= minCount, counts[s] > 0 else { return .nan }
        let level = 10 * log10(sums[s] / Double(counts[s]) + 1e-12)
        return max(level, -100)
    }
}
