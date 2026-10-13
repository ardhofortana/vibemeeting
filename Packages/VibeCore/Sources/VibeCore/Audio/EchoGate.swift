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
///    dB. Every 0.1 s the gate searches the delays (up to 0.6 s) for the best
///    correlation of the levels over the last 1.5 s whose reference has
///    arrived, counting only bins where the reference is active (above
///    `activeFloorDB` and well above its own noise floor). A window confirms a
///    coupling only when that correlation is strong, the mic tracks the
///    reference close to dB for dB (mic minus reference barely moves while the
///    reference does; loud speakers and a hot mic flatten the loudest sounds a
///    little, which is allowed), and the mic is quiet where the reference has
///    been quiet. Two voices can line up by chance for a second or so; they
///    don't keep doing it. So a new coupling arms the gate only when a later
///    window, on new data, finds it again at the same delay and gain (about
///    2.5 s of the other side talking; 3 s or so with heavy reverb). In
///    simulation (headphones with turn-taking, the user talking over the other
///    side, short words in its monologues: 4.4 hours), a mic that only hears
///    the user never coupled: chance matches passed every check of a window
///    now and then, but were never found again on new data. The mic can't hear the speakers before the call audio
///    is captured, so a best match with the mic ahead of the reference (the
///    call audio carrying the mic's own sound) confirms nothing.
/// 2. Gate. While a coupling is fresh, a mic bin is bleed when the reference was
///    active at that delay and the mic is no louder than the predicted bleed
///    plus `doubleTalkMarginDB`. Anything louder is the user talking over the
///    other side and passes. Within 0.12 s after (and 0.03 s before) a bin
///    where the user stands far above the bleed, only bins at most 1 dB above
///    the predicted bleed are gated, so the dips between the user's syllables
///    pass too. When the other side stops, the predicted bleed drops with the
///    reference, so the user's first words pass.
///
/// Conservative by design, since a false gate eats the user's words while a
/// missed gate only leaves a duplicate the text filter may still catch:
/// - Missing reference bins are unknown (never silence), and silence in the
///   reference never gates. Samples of bins that aren't bleed are never touched
///   (the gain ramps happen inside gated bins).
/// - A coupling that goes unconfirmed is checked against the mic every 0.1 s.
///   It is dropped when, where its bleed should stand clear of the mic's
///   floor, the mic is more than 10 dB below that bleed in half of the bins,
///   or more than 20 dB below it in a quarter of them (headphones plugged in or
///   speakers muted, even while the user keeps talking). The user only adds
///   energy, so while they talk over the other side, the quiet end of mic
///   minus reference still bounds the coupling gain: when it sits below the
///   gain, the gain is lowered to match (speaker volume turned down), and a
///   lowered coupling stops gating after `maxUnconfirmedActive` seconds of the
///   other side talking unless a window confirms it.
/// - A clock that steps back starts the coupling over.
/// The flip side: the prediction follows the reference within a bin, so room
/// reverb that lingers after a syllable passes, and so does some bleed right
/// next to the user's syllables while both talk.
///
/// Feed the reference before the mic audio it overlaps: see `process`.
/// `stats` says why the search found nothing (`Stats.searches`), shows the
/// best match of the last 10 s or so (`Stats.bestRecent`) and how far the
/// reference trails the mic, so a report from the field shows which check
/// held the gate back.
///
/// Thread safe: an `NSLock` guards all state, so the reference and the mic can
/// arrive on different threads. `process` does no allocation and no logging.
public final class EchoGate: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Length of the energy bins on the shared clock, in seconds.
        public var binDuration: Double
        /// Seconds of bins kept per stream.
        public var history: Double
        /// Smallest delay accepted (mic time minus reference time). Delays down
        /// to 0.15 s below it are searched as well, and a best match there
        /// confirms nothing: a mic ahead of the reference means the call audio
        /// carries the mic's own sound (monitoring, a mic test), not bleed.
        public var minLag: Double
        /// Largest delay searched. Bluetooth and HDMI outputs, or a speaker
        /// with its own processing, add a few hundred milliseconds.
        public var maxLag: Double
        /// Seconds of mic bins used to find the coupling.
        public var correlationWindow: Double
        /// Correlation of the levels needed to confirm a coupling.
        public var minCorrelation: Double
        /// Mic louder than the predicted bleed by this much means the user is talking.
        public var doubleTalkMarginDB: Double
        /// A reference quieter than this (dBFS) has nothing to leak. The gate
        /// also tracks the reference's noise floor and needs a bin 10 dB above
        /// it, whichever is higher, so a steady noise bed doesn't count as the
        /// other side talking.
        public var activeFloorDB: Double
        /// A confirmed coupling stays valid this long without reconfirmation.
        public var couplingHold: Double
        /// Gain applied to gated samples (0 silences them).
        public var attenuation: Float

        public init(
            binDuration: Double = 0.01,
            history: Double = 4,
            minLag: Double = 0,
            maxLag: Double = 0.60,
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
        /// Level of the bleed relative to the reference: from the last confirmed
        /// coupling, or lower when the mic has since shown the bleed got quieter.
        public var couplingGainDB: Double?
        /// Correlation of the levels when the coupling was last confirmed.
        public var correlation: Double?
        /// Seconds of mic audio processed while the gate was armed whose
        /// reference at the coupling delay hadn't arrived, so it couldn't be
        /// gated. Grows steadily when the reference is fed too late.
        public var unknownReferenceSeconds: Double
        /// How far the newest reference trailed the end of each mic buffer when
        /// that buffer was processed, in seconds (negative: ahead): recent
        /// average and largest. More than the coupling delay means the mic is
        /// processed before its reference arrives, so the bleed can be found
        /// but not gated.
        public var referenceTrailSeconds: Double
        public var maxReferenceTrailSeconds: Double
        /// What came of the coupling searches (one per 0.1 s of mic audio):
        /// which check stopped them, or how many confirmed a coupling.
        public var searches: Searches
        /// The search with the highest correlation in the last 5 to 10 s of
        /// mic audio, whatever became of it.
        public var bestRecent: Probe?

        public init(
            processedSeconds: Double = 0,
            gatedSeconds: Double = 0,
            isCoupled: Bool = false,
            lagSeconds: Double? = nil,
            couplingGainDB: Double? = nil,
            correlation: Double? = nil,
            unknownReferenceSeconds: Double = 0,
            referenceTrailSeconds: Double = 0,
            maxReferenceTrailSeconds: Double = 0,
            searches: Searches = Searches(),
            bestRecent: Probe? = nil
        ) {
            self.processedSeconds = processedSeconds
            self.gatedSeconds = gatedSeconds
            self.isCoupled = isCoupled
            self.lagSeconds = lagSeconds
            self.couplingGainDB = couplingGainDB
            self.correlation = correlation
            self.unknownReferenceSeconds = unknownReferenceSeconds
            self.referenceTrailSeconds = referenceTrailSeconds
            self.maxReferenceTrailSeconds = maxReferenceTrailSeconds
            self.searches = searches
            self.bestRecent = bestRecent
        }
    }

    /// Coupling searches by outcome. Each search counts once, under the first
    /// check its best delay failed (or `pending` / `confirmed`).
    public struct Searches: Equatable, Sendable {
        public var total = 0
        /// The mic window had gaps.
        public var micGaps = 0
        /// No delay had enough reference bins known (call audio late or missing).
        public var referenceUnknown = 0
        /// The other side talked too little in the window.
        public var referenceQuiet = 0
        /// The other side's level (or the mic's) was too steady to match.
        public var referenceFlat = 0
        /// The best match had the mic ahead of the reference.
        public var micLeads = 0
        /// The best correlation stayed below `minCorrelation`.
        public var weakCorrelation = 0
        /// The mic didn't follow the reference dB for dB.
        public var slope = 0
        /// Too few bins where the reference had been silent to check the mic there.
        public var fewQuietBins = 0
        /// The mic wasn't quiet where the reference had been silent.
        public var notQuiet = 0
        /// Passed every check, waiting to be seen again on new data.
        public var pending = 0
        /// Confirmed a coupling (armed or refreshed it).
        public var confirmed = 0
        /// Not an outcome: searches whose best delay was the longest searched,
        /// so the real delay may lie beyond `maxLag`.
        public var atMaxLag = 0

        public init() {}

        /// "120 searches: confirmed 40, few quiet bins 50, slope 30": the
        /// outcomes that occurred, most frequent first.
        public var summary: String {
            let outcomes = [
                ("confirmed", confirmed), ("pending", pending), ("slope", slope),
                ("few quiet bins", fewQuietBins), ("not quiet", notQuiet), ("weak correlation", weakCorrelation),
                ("mic leads", micLeads), ("reference quiet", referenceQuiet), ("reference flat", referenceFlat),
                ("reference unknown", referenceUnknown), ("mic gaps", micGaps),
            ]
            var parts = outcomes.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map { "\($0.0) \($0.1)" }
            if atMaxLag > 0 { parts.append("best at the longest delay \(atMaxLag)") }
            return "\(total) searches" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", "))
        }
    }

    /// One search's best delay and what the checks made of it.
    public struct Probe: Equatable, Sendable {
        public enum Outcome: String, Equatable, Sendable {
            case micLeads, weakCorrelation, slope, fewQuietBins, notQuiet, pending, confirmed
        }

        public var lagSeconds: Double
        public var correlation: Double
        /// Median of mic minus reference over the active bins.
        public var gainDB: Double
        /// Unit-slope check: lower spread of mic minus reference over the
        /// reference's own spread (passes up to 0.8).
        public var slopeRatio: Double
        /// Quiet-bin check: bins where the reference had been silent, and the
        /// share of them where the mic was quiet enough (passes from 0.8).
        public var quietBins: Int
        public var quietShare: Double
        /// Share of the window with both levels known at this delay.
        public var knownShare: Double
        /// Share of the window where the reference was active at this delay.
        public var activeShare: Double
        public var outcome: Outcome
        /// Seconds of mic audio since the window ended.
        public var age: Double

        public init(
            lagSeconds: Double, correlation: Double, gainDB: Double, slopeRatio: Double,
            quietBins: Int, quietShare: Double, knownShare: Double, activeShare: Double,
            outcome: Outcome, age: Double
        ) {
            self.lagSeconds = lagSeconds
            self.correlation = correlation
            self.gainDB = gainDB
            self.slopeRatio = slopeRatio
            self.quietBins = quietBins
            self.quietShare = quietShare
            self.knownShare = knownShare
            self.activeShare = activeShare
            self.outcome = outcome
            self.age = age
        }

        /// "lag 50 ms, r 0.92, -6.7 dB, slope 0.63, quiet bins 0, known 100%,
        /// active 97%: fewQuietBins, 3.3 s ago".
        public var summary: String {
            func number(_ value: Double, _ format: String) -> String {
                value.isFinite ? String(format: format, value) : "–"
            }
            return "lag \(number(lagSeconds * 1000, "%.0f")) ms, r \(number(correlation, "%.2f")), "
                + "\(number(gainDB, "%.1f")) dB, slope \(number(slopeRatio, "%.2f")), "
                + "quiet bins \(quietBins)" + (quietShare.isFinite ? " (\(number(quietShare * 100, "%.0f"))% quiet)" : "")
                + ", known \(number(knownShare * 100, "%.0f"))%, active \(number(activeShare * 100, "%.0f"))%"
                + ": \(outcome.rawValue), \(number(age, "%.1f")) s ago"
        }
    }

    let configuration: Configuration

    // Tuning that isn't worth a public knob.
    /// The reference must vary at least this much (std, dB) over its active bins.
    static let minReferenceSpreadDB = 3.0
    /// Unit-slope check: the lower spread of mic minus reference (median minus
    /// 20th percentile) must stay below this share of the reference's own
    /// spread (median absolute deviation). Loud speakers limit their loudest
    /// sounds, a hot mic clips them and the speakers color some sounds more
    /// than others, so real bleed falls a few dB short of a unit slope on
    /// some bins: in simulation (limiters of 2:1 to 6:1, ±3 to 5 dB of
    /// coloring, a reverberant tail as loud as the direct sound) it measured
    /// 0.5 to 0.9, median 0.65, and 0.5 rejected nearly every window. Chance
    /// matches of two voices (correlation 0.6 or more) measured 0.8 to 10,
    /// median 2.5 to 3; the few that pass every check are never found again
    /// on new data, which a coupling needs.
    static let maxResidualSpreadRatio = 0.8
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
    /// A new gain estimate within this many dB of the current one is smoothed in.
    /// A bigger change at the delay already known is the volume control: a
    /// quieter bleed replaces the gain at once (it only gates less), a louder
    /// one needs a strong sighting or a second one half a window later.
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
    /// Searched below `minLag` to catch a mic that leads the reference.
    static let leadGuard = 0.15
    /// Reference noise floor: this percentile of its bin levels over the
    /// history, plus the margin, is the least an active bin needs; trusted
    /// once this many bins are known.
    static let noiseFloorPercentile = 0.1
    static let noiseFloorMarginDB = 10.0
    static let minNoiseFloorBins = 100
    /// Review of an unconfirmed coupling, over bins where its bleed would stand
    /// at least `contradictionDB` above the mic's floor: dropped when the mic
    /// is more than `contradictionDB` below that bleed in `contradictionShare`
    /// of them, or, over bins where it would stand `deepContradictionDB`
    /// clear, more than that below it in `deepContradictionShare` of them (the
    /// user talking fills the other bins). Needs this many bins either way.
    static let contradictionDB = 10.0
    static let contradictionShare = 0.5
    static let deepContradictionDB = 20.0
    static let deepContradictionShare = 0.25
    static let minContradictionBins = 20
    /// While the user talks over the other side (the mic beats the confirmed
    /// bleed by the double-talk margin in this share of the bins), the gain is
    /// lowered when this percentile of mic minus reference sits more than the
    /// trigger below it: to that percentile plus the headroom, but never more
    /// than `contradictionDB` below the confirmed gain. Without the user the
    /// next window confirms the new gain anyway, and a mic quieter than the
    /// bleed in some bins only (speakers coloring some sounds more than
    /// others) must not lower it.
    static let lowerGainUserShare = 0.1
    static let lowerGainPercentile = 0.2
    static let lowerGainTriggerDB = 4.0
    static let lowerGainHeadroomDB = 2.0
    /// A lowered coupling stops gating after this many seconds of active
    /// reference without a window confirming it. One confirming window
    /// re-arms it.
    static let maxUnconfirmedActive = 4.0
    /// A stream whose clock steps back further than this starts the coupling over.
    static let maxClockStepBack = 0.5
    /// Double talk: a mic bin this far above the predicted bleed is the user
    /// for sure. Up to `hangoverAfter` after it and `hangoverBefore` before it,
    /// a bin is gated only when the mic is no more than `hangoverMarginDB`
    /// above the predicted bleed: the dips between the user's syllables and
    /// their onsets pass, the bleed in their pauses is still gated.
    static let userEvidenceDB = 12.0
    static let hangoverBefore = 0.03
    static let hangoverAfter = 0.12
    static let hangoverMarginDB = 1.0
    /// Seconds between coupling searches.
    static let evaluationInterval = 0.1
    /// Diagnostics: `Stats.bestRecent` is the best probe of the current and
    /// the previous block of this many seconds; the reference trail is
    /// smoothed with this weight per mic buffer.
    static let probeBlock = 5.0
    static let trailSmoothing = 0.05
    /// Gain ramp length in seconds, kept inside gated bins.
    static let rampDuration = 0.002
    /// A bin needs this share of its samples before its level is trusted.
    static let minBinFill = 0.25

    private struct Coupling {
        var lagBins: Int
        /// Gain used to predict the bleed: the confirmed gain, or lower when the
        /// mic has since shown the bleed got quieter.
        var gainDB: Double
        var confirmedGainDB: Double
        var correlation: Double
        /// Last mic bin of the window that confirmed it.
        var confirmedBin: Int
        /// Mic bins since then where the reference was active at the delay.
        var unconfirmedActiveBins = 0
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

    /// The checks beyond the correlation, measured at one delay.
    private struct Measurement {
        var gainDB: Double
        var slopeRatio: Double
        var quietBins: Int
        var quietShare: Double
        /// The first check that failed, nil when all passed.
        var failure: Probe.Outcome?
    }

    /// A probe and the mic bin its window ended at.
    private struct ProbeRecord {
        var probe: Probe
        var endBin: Int
    }

    private enum Review {
        case consistent
        case lowered(Double)
        case contradicted
    }

    /// How the gate sees a mic bin.
    private enum Decision {
        /// No louder than the predicted bleed plus the margin; `excessDB` is
        /// mic minus predicted bleed.
        case bleed(excessDB: Double)
        /// The reference at the delay hasn't arrived (or never will).
        case unknown
        /// Silent reference, or louder than the bleed: not gated.
        case pass
        /// Far louder than the bleed: the user, for sure.
        case user
    }

    private let lock = NSLock()

    private let binDuration: Double
    private let windowBins: Int
    private let minLagBins: Int
    private let searchMinLagBins: Int
    private let maxLagBins: Int
    private let holdBins: Int
    private let maxUnconfirmedBins: Int
    private let evaluationBins: Int
    private let clockStepBackBins: Int
    private let hangoverBeforeBins: Int
    private let hangoverAfterBins: Int
    private let configuredFloorDB: Double
    private let doubleTalkMarginDB: Double
    private let attenuation: Float

    private var reference: EnergyRing
    private var mic: EnergyRing
    private var referenceSamplesPerBin = 480.0
    private var micSamplesPerBin = 480.0
    /// Least level of an active reference bin: `activeFloorDB`, or 10 dB above
    /// the reference's noise floor when that is higher.
    private var activeFloorDB: Double

    private var coupling: Coupling?
    /// A few candidates at once: with reverb the best delay wanders by a bin or
    /// two, and one stray sighting must not erase the evidence gathered so far.
    private var candidates: [Candidate] = []
    private let candidateExpiryBins: Int
    /// End of the window searched last, and the newest complete mic bin then.
    private var lastEvaluatedBin: Int?
    private var lastSearchMicBin: Int?
    private var newestMicBin: Int?
    /// Latest mic bin that carried the user for sure, for the hangover.
    private var lastUserBin: Int?
    private var rampGain: Float = 1
    private var processedSeconds = 0.0
    private var gatedSeconds = 0.0
    private var unknownSeconds = 0.0
    private var searches = Searches()
    /// Best probes of the current and the previous `probeBlock`.
    private var currentBest: ProbeRecord?
    private var previousBest: ProbeRecord?
    private var probeBlockStart: Int?
    private var referenceTrail = 0.0
    private var maxReferenceTrail = 0.0
    private var hasReferenceTrail = false

    // Scratch, allocated once.
    private let micLevels: UnsafeMutablePointer<Double>
    private let referenceLevels: UnsafeMutablePointer<Double>
    private let scratchA: UnsafeMutablePointer<Double>
    private let scratchB: UnsafeMutablePointer<Double>
    private let floorScratch: UnsafeMutablePointer<Double>
    private let referenceSpan: Int

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        func finite(_ value: Double, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        let bin = finite(configuration.binDuration, 0.01, 0.001...0.1)
        binDuration = bin
        func bins(_ seconds: Double) -> Int { Int((seconds / bin).rounded()) }
        let lagA = bins(finite(configuration.minLag, 0, -2...2))
        let lagB = bins(finite(configuration.maxLag, 0.60, -2...2))
        minLagBins = min(lagA, lagB)
        maxLagBins = max(lagA, lagB)
        searchMinLagBins = minLagBins - max(1, bins(Self.leadGuard))
        windowBins = max(20, bins(finite(configuration.correlationWindow, 1.5, 0...30)))
        holdBins = bins(finite(configuration.couplingHold, 20, 0...86_400))
        maxUnconfirmedBins = bins(Self.maxUnconfirmedActive)
        evaluationBins = max(1, bins(Self.evaluationInterval))
        candidateExpiryBins = bins(Self.candidateExpiry)
        clockStepBackBins = max(1, bins(Self.maxClockStepBack))
        hangoverBeforeBins = bins(Self.hangoverBefore)
        hangoverAfterBins = bins(Self.hangoverAfter)
        configuredFloorDB = finite(configuration.activeFloorDB, -50, -100...0)
        activeFloorDB = configuredFloorDB
        doubleTalkMarginDB = finite(configuration.doubleTalkMarginDB, 6, 0...40)
        let attenuation = configuration.attenuation
        self.attenuation = attenuation.isFinite ? min(max(attenuation, 0), 1) : 0

        referenceSpan = windowBins + maxLagBins - searchMinLagBins
        let historyBins = Int((finite(configuration.history, 4, 0...120) / bin).rounded(.up))
        let capacity = max(historyBins, referenceSpan + 2) + 2
        reference = EnergyRing(capacity: capacity)
        mic = EnergyRing(capacity: capacity)

        micLevels = .allocate(capacity: windowBins)
        referenceLevels = .allocate(capacity: referenceSpan)
        scratchA = .allocate(capacity: windowBins)
        scratchB = .allocate(capacity: windowBins)
        floorScratch = .allocate(capacity: capacity)
        candidates.reserveCapacity(Self.maxCandidates)
    }

    deinit {
        micLevels.deallocate()
        referenceLevels.deallocate()
        scratchA.deallocate()
        scratchB.deallocate()
        floorScratch.deallocate()
    }

    // MARK: Public API

    /// Reference (call audio) mono samples; `startTime` is the capture time of
    /// the first sample in seconds on a clock shared with the mic.
    ///
    /// Call it as soon as the call audio is captured, ahead of anything slow
    /// (such as handing it to the transcriber): `process` can only gate mic
    /// audio whose reference has already arrived.
    public func addReference(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, startTime: Double) {
        guard let base = samples.baseAddress,
              let geometry = BinGeometry(count: samples.count, sampleRate: sampleRate, startTime: startTime, binDuration: binDuration)
        else { return }
        lock.lock()
        defer { lock.unlock() }
        if let newest = reference.newest, geometry.firstBin < newest - clockStepBackBins {
            // The clock went back: the delay to the mic no longer holds.
            reference.reset()
            forgetCoupling()
        }
        referenceSamplesPerBin = geometry.samplesPerBin
        geometry.forEachSegment { bin, lower, upper, _ in
            reference.add(bin: bin, sumOfSquares: Self.sumOfSquares(base, lower, upper), count: upper - lower)
        }
    }

    /// Mic mono samples, attenuated in place where they carry only bleed.
    /// Returns how many samples were attenuated.
    ///
    /// Gating needs the reference that overlaps this buffer at the coupling
    /// delay: up to about `startTime + duration - lag + binDuration` must have
    /// been added already. Mic audio whose reference hasn't arrived yet is
    /// never gated (it goes out unchanged, bleed and all), so add the
    /// reference first, or hold the mic back by a buffer when the call audio
    /// arrives later than the mic.
    @discardableResult
    public func process(_ samples: UnsafeMutableBufferPointer<Float>, sampleRate: Double, startTime: Double) -> Int {
        guard let base = samples.baseAddress,
              let geometry = BinGeometry(count: samples.count, sampleRate: sampleRate, startTime: startTime, binDuration: binDuration)
        else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        if let newest = mic.newest, geometry.firstBin < newest - clockStepBackBins {
            // The clock went back: start over rather than mix two timelines.
            mic.reset()
            forgetCoupling()
            lastEvaluatedBin = nil
            lastSearchMicBin = nil
            newestMicBin = nil
            rampGain = 1
            currentBest = nil
            previousBest = nil
            probeBlockStart = nil
        }
        micSamplesPerBin = geometry.samplesPerBin

        // 1. Levels of the incoming audio (before any gating).
        var lastBin = geometry.firstBin
        geometry.forEachSegment { bin, lower, upper, _ in
            mic.add(bin: bin, sumOfSquares: Self.sumOfSquares(UnsafePointer(base), lower, upper), count: upper - lower)
            lastBin = bin
        }
        newestMicBin = max(newestMicBin ?? lastBin, lastBin)
        if let newestReference = reference.newest {
            let trail = Double(lastBin - newestReference) * binDuration
            referenceTrail = hasReferenceTrail ? referenceTrail + Self.trailSmoothing * (trail - referenceTrail) : trail
            maxReferenceTrail = hasReferenceTrail ? max(maxReferenceTrail, trail) : trail
            hasReferenceTrail = true
        }

        // 2. Coupling, every `evaluationInterval` of mic audio, over complete
        // bins only, and only as far as the reference has arrived for every
        // delay accepted: call audio that trails the mic would otherwise leave
        // the newest mic bins unpaired, and short delays unsearched.
        let micEnd = lastBin - 1
        var windowEnd = micEnd
        if let newestReference = reference.newest {
            windowEnd = min(windowEnd, newestReference - 1 + minLagBins)
        }
        let searchedRecently = lastSearchMicBin.map { micEnd >= $0 && micEnd - $0 < evaluationBins } ?? false
        if !searchedRecently, windowEnd != lastEvaluatedBin {
            let previous = lastEvaluatedBin
            lastSearchMicBin = micEnd
            lastEvaluatedBin = windowEnd
            evaluateCoupling(through: windowEnd, since: previous)
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
        var stats = Stats(
            processedSeconds: processedSeconds,
            gatedSeconds: gatedSeconds,
            unknownReferenceSeconds: unknownSeconds,
            referenceTrailSeconds: referenceTrail,
            maxReferenceTrailSeconds: maxReferenceTrail,
            searches: searches
        )
        if let coupling {
            stats.isCoupled = newestMicBin.map { isFresh(coupling, at: $0) } ?? false
            stats.lagSeconds = Double(coupling.lagBins) * binDuration
            stats.couplingGainDB = coupling.gainDB
            stats.correlation = coupling.correlation
        }
        var best = currentBest
        if let previous = previousBest, previous.probe.correlation > best?.probe.correlation ?? -.infinity { best = previous }
        if let best, let newest = newestMicBin {
            stats.bestRecent = best.probe
            stats.bestRecent?.age = Double(max(0, newest - best.endBin)) * binDuration
        }
        return stats
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        reference.reset()
        mic.reset()
        forgetCoupling()
        activeFloorDB = configuredFloorDB
        lastEvaluatedBin = nil
        lastSearchMicBin = nil
        newestMicBin = nil
        rampGain = 1
        processedSeconds = 0
        gatedSeconds = 0
        unknownSeconds = 0
        searches = Searches()
        currentBest = nil
        previousBest = nil
        probeBlockStart = nil
        referenceTrail = 0
        maxReferenceTrail = 0
        hasReferenceTrail = false
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

    private func forgetCoupling() {
        coupling = nil
        candidates.removeAll(keepingCapacity: true)
        lastUserBin = nil
    }

    private func isFresh(_ coupling: Coupling, at bin: Int) -> Bool {
        let age = bin - coupling.confirmedBin
        guard age >= 0, age <= holdBins else { return false }
        let lowered = coupling.gainDB < coupling.confirmedGainDB
        return !lowered || coupling.unconfirmedActiveBins <= maxUnconfirmedBins
    }

    private var micMinCount: Int { max(1, Int(micSamplesPerBin * Self.minBinFill)) }
    private var referenceMinCount: Int { max(1, Int(referenceSamplesPerBin * Self.minBinFill)) }

    /// Tracks the reference's noise floor: a steady noise bed (an open mic on
    /// the other side, comfort noise) must not count as the other side talking.
    private func updateActiveFloor() {
        activeFloorDB = configuredFloorDB
        guard let newest = reference.newest else { return }
        let minCount = referenceMinCount
        var n = 0
        var bin = newest - reference.capacity + 1
        while bin <= newest {
            let level = reference.level(bin, minCount: minCount)
            if !level.isNaN {
                floorScratch[n] = level
                n += 1
            }
            bin += 1
        }
        guard n >= Self.minNoiseFloorBins else { return }
        let noiseFloor = Self.select(floorScratch, n, Int(Double(n) * Self.noiseFloorPercentile))
        activeFloorDB = max(configuredFloorDB, noiseFloor + Self.noiseFloorMarginDB)
    }

    /// Searches the delays over the window ending at `end` (a mic bin) and
    /// confirms, refreshes, lowers or drops the coupling. `previous` is the end
    /// of the window searched before.
    private func evaluateCoupling(through end: Int, since previous: Int?) {
        let window = windowBins
        let first = end - window + 1
        let referenceFirst = first - maxLagBins
        let micMin = micMinCount
        let referenceMin = referenceMinCount
        searches.total += 1
        var knownMic = 0
        for j in 0..<window {
            micLevels[j] = mic.level(first + j, minCount: micMin)
            if !micLevels[j].isNaN { knownMic += 1 }
        }
        let minKnown = Int((Double(window) * Self.minKnownShare).rounded(.up))
        guard knownMic >= minKnown else {
            searches.micGaps += 1
            return
        }
        for k in 0..<referenceSpan {
            referenceLevels[k] = reference.level(referenceFirst + k, minCount: referenceMin)
        }
        updateActiveFloor()

        // Mic bin j pairs with reference index j + maxLagBins - lag.
        let floor = activeFloorDB
        let minSpread = Self.minReferenceSpreadDB * Self.minReferenceSpreadDB
        var bestCorrelation = -Double.infinity
        var bestLag = 0
        var bestKnown = 0, bestActive = 0
        // How far the best delay got: 0 reference unknown, 1 too little
        // talk, 2 too flat, 3 correlated.
        var stage = 0
        for lag in searchMinLagBins...maxLagBins {
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
            guard known >= minKnown else { continue }
            guard n >= Double(known) * Self.minActiveShare, n >= Double(window) * Self.minActiveShare else {
                stage = max(stage, 1)
                continue
            }
            let mx = sx / n, my = sy / n
            let vx = sxx / n - mx * mx
            let vy = syy / n - my * my
            guard vx >= minSpread, vy > 1e-9 else {
                stage = max(stage, 2)
                continue
            }
            stage = 3
            let r = (sxy / n - mx * my) / (vx * vy).squareRoot()
            if r > bestCorrelation {
                bestCorrelation = r
                bestLag = lag
                bestKnown = known
                bestActive = Int(n)
            }
        }

        var refreshed = false
        switch stage {
        case 0: searches.referenceUnknown += 1
        case 1: searches.referenceQuiet += 1
        case 2: searches.referenceFlat += 1
        default:
            if bestLag >= maxLagBins - 1 { searches.atMaxLag += 1 }
            let measured = measure(lag: bestLag, window: window, floor: floor)
            // A best match with the mic ahead of the reference is the call
            // audio carrying the mic's own sound, never bleed: it confirms nothing.
            let outcome: Probe.Outcome
            if bestLag < minLagBins {
                outcome = .micLeads
            } else if bestCorrelation < configuration.minCorrelation {
                outcome = .weakCorrelation
            } else if let failure = measured.failure {
                outcome = failure
            } else {
                let isStrong = bestCorrelation >= Self.strongCorrelation
                    && measured.slopeRatio <= Self.strongResidualSpreadRatio
                let sighting = Sighting(lagBins: bestLag, gainDB: measured.gainDB, correlation: bestCorrelation, isStrong: isStrong)
                refreshed = accept(sighting, end: end)
                outcome = refreshed ? .confirmed : .pending
            }
            tally(outcome)
            record(Probe(
                lagSeconds: Double(bestLag) * binDuration,
                correlation: bestCorrelation,
                gainDB: measured.gainDB,
                slopeRatio: measured.slopeRatio,
                quietBins: measured.quietBins,
                quietShare: measured.quietShare,
                knownShare: Double(bestKnown) / Double(window),
                activeShare: Double(bestActive) / Double(window),
                outcome: outcome,
                age: 0
            ), end: end)
        }
        guard !refreshed, var current = coupling else { return }

        // The other side's talk the coupling went through unconfirmed.
        let offset = maxLagBins - current.lagBins
        var j = max(0, (previous ?? end) + 1 - first)
        while j < window {
            let x = referenceLevels[j + offset]
            if !micLevels[j].isNaN, !x.isNaN, x >= floor { current.unconfirmedActiveBins += 1 }
            j += 1
        }
        if isFresh(current, at: end) {
            switch review(current, window: window, floor: floor) {
            case .contradicted:
                coupling = nil
                lastUserBin = nil
                return
            case .lowered(let gain):
                current.gainDB = gain
            case .consistent:
                break
            }
        }
        coupling = current
    }

    /// Takes a window that passed every check. Returns whether it confirmed
    /// (refreshed or armed) the coupling in force.
    private func accept(_ sighting: Sighting, end: Int) -> Bool {
        let lag = sighting.lagBins, gain = sighting.gainDB
        var atKnownDelay = false
        // The coupling we know (even past its hold).
        if let current = coupling, abs(lag - current.lagBins) <= 1 {
            atKnownDelay = true
            let ceiling = max(current.gainDB, current.confirmedGainDB) + Self.gainJumpDB
            if gain >= current.gainDB - Self.gainJumpDB, gain <= ceiling {
                // Refresh it.
                let smoothed = current.gainDB + Self.gainSmoothing * (gain - current.gainDB)
                arm(Coupling(lagBins: lag, gainDB: smoothed, confirmedGainDB: smoothed, correlation: sighting.correlation, confirmedBin: end))
                return true
            }
            if gain < current.gainDB || sighting.isStrong {
                // The volume moved. Quieter bleed only gates less, so take it
                // at once; louder needs a strong sighting or a second one.
                arm(Coupling(lagBins: lag, gainDB: gain, confirmedGainDB: gain, correlation: sighting.correlation, confirmedBin: end))
                return true
            }
        }
        // A new one must show up again on new data: a full window later, or
        // half a window for two strong sightings or at the delay already known.
        let span = atKnownDelay ? windowBins / 2 : windowBins
        candidates.removeAll { end - $0.lastBin > candidateExpiryBins || end < $0.lastBin }
        var matched = false
        for i in candidates.indices {
            let seen = candidates[i]
            guard abs(lag - seen.lagBins) <= 1, abs(gain - seen.gainDB) <= Self.candidateGainToleranceDB else { continue }
            matched = true
            let strongSpan = sighting.isStrong ? seen.firstStrongBin.map { end - $0 } ?? -1 : -1
            if end - seen.firstBin >= span || strongSpan >= windowBins / 2 {
                arm(Coupling(lagBins: lag, gainDB: gain, confirmedGainDB: gain, correlation: sighting.correlation, confirmedBin: end))
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

    private func arm(_ new: Coupling) {
        coupling = new
        candidates.removeAll(keepingCapacity: true)
    }

    /// Checks the coupling at `lag` beyond the correlation; `failure` names the
    /// first check that fails, and every measure is filled in either way (for
    /// `Stats.bestRecent`):
    /// - Unit slope: the mic follows the reference dB for dB, so mic minus
    ///   reference stays put while the reference moves. Only the lower side of
    ///   its spread counts: reverb, the user talking over the bleed and the
    ///   mic's noise floor all add energy. Only limiting, clipping and the
    ///   speakers' coloring make the mic quieter than a unit slope predicts,
    ///   and only by a few dB (`maxResidualSpreadRatio`).
    /// - Quiet when the reference is quiet: where the reference has been silent
    ///   for a while, the mic sits well below its level in the active bins.
    ///   Speech that merely happens to line up with the reference fails this.
    /// The gain is the median of mic minus reference over active bins.
    private func measure(lag: Int, window: Int, floor: Double) -> Measurement {
        var result = Measurement(gainDB: .nan, slopeRatio: .nan, quietBins: 0, quietShare: .nan, failure: .slope)
        let offset = maxLagBins - lag
        var n = 0
        for j in 0..<window {
            let y = micLevels[j]
            let x = referenceLevels[j + offset]
            if y.isNaN || x.isNaN || x < floor { continue }
            scratchA[n] = y - x
            scratchB[n] = x
            n += 1
        }
        guard n >= 3 else { return result }
        let gain = Self.median(scratchA, n)
        result.gainDB = gain
        let lowerSpread = gain - Self.select(scratchA, n, n / 5)
        let referenceSpread = Self.medianAbsoluteDeviation(scratchB, n, around: Self.median(scratchB, n))
        guard referenceSpread > 0 else { return result }
        let spreadRatio = lowerSpread / referenceSpread
        result.slopeRatio = spreadRatio

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
        result.quietBins = quiet
        result.quietShare = quiet > 0 ? Double(quieter) / Double(quiet) : .nan
        if spreadRatio > Self.maxResidualSpreadRatio {
            result.failure = .slope
        } else if quiet < Self.minQuietBins {
            result.failure = .fewQuietBins
        } else if Double(quieter) < Self.minQuietShare * Double(quiet) {
            result.failure = .notQuiet
        } else {
            result.failure = nil
        }
        return result
    }

    private func tally(_ outcome: Probe.Outcome) {
        switch outcome {
        case .micLeads: searches.micLeads += 1
        case .weakCorrelation: searches.weakCorrelation += 1
        case .slope: searches.slope += 1
        case .fewQuietBins: searches.fewQuietBins += 1
        case .notQuiet: searches.notQuiet += 1
        case .pending: searches.pending += 1
        case .confirmed: searches.confirmed += 1
        }
    }

    /// Keeps the best probe of the current and the previous block.
    private func record(_ probe: Probe, end: Int) {
        let block = max(1, Int((Self.probeBlock / binDuration).rounded()))
        if let start = probeBlockStart, end >= start, end - start < block {
            // Same block.
        } else {
            previousBest = (probeBlockStart.map { end - $0 < 2 * block && end >= $0 } ?? false) ? currentBest : nil
            currentBest = nil
            probeBlockStart = end
        }
        if probe.correlation > currentBest?.probe.correlation ?? -.infinity {
            currentBest = ProbeRecord(probe: probe, endBin: end)
        }
    }

    /// Checks an unconfirmed coupling against the mic, over the bins where its
    /// bleed would stand clear of the mic's floor. Nothing makes the mic
    /// quieter than the bleed it carries, and the user only adds energy, so the
    /// quiet end of mic minus reference holds even while they talk: far below
    /// the confirmed gain, the bleed is gone; somewhat below it while the user
    /// talks, the bleed got quieter.
    private func review(_ coupling: Coupling, window: Int, floor: Double) -> Review {
        var n = 0
        for j in 0..<window where !micLevels[j].isNaN {
            scratchA[n] = micLevels[j]
            n += 1
        }
        guard n >= 3 else { return .consistent }
        let micFloor = Self.select(scratchA, n, n / 10)
        let offset = maxLagBins - coupling.lagBins
        let confirmed = coupling.confirmedGainDB
        var eligible = 0, under = 0, user = 0
        var deepEligible = 0, deepUnder = 0
        for j in 0..<window {
            let y = micLevels[j]
            let x = referenceLevels[j + offset]
            if y.isNaN || x.isNaN || x < floor { continue }
            let predicted = x + confirmed
            let difference = y - x
            if predicted >= micFloor + Self.deepContradictionDB {
                deepEligible += 1
                if difference < confirmed - Self.deepContradictionDB { deepUnder += 1 }
            }
            guard predicted >= micFloor + Self.contradictionDB else { continue }
            if difference < confirmed - Self.contradictionDB { under += 1 }
            if difference > confirmed + doubleTalkMarginDB { user += 1 }
            scratchA[eligible] = difference
            eligible += 1
        }
        if deepEligible >= Self.minContradictionBins,
           Double(deepUnder) >= Self.deepContradictionShare * Double(deepEligible) {
            return .contradicted
        }
        guard eligible >= Self.minContradictionBins else { return .consistent }
        if Double(under) >= Self.contradictionShare * Double(eligible) { return .contradicted }
        guard Double(user) >= Self.lowerGainUserShare * Double(eligible) else { return .consistent }
        let low = Self.select(scratchA, eligible, Int(Double(eligible) * Self.lowerGainPercentile))
        guard low < coupling.gainDB - Self.lowerGainTriggerDB else { return .consistent }
        let lowered = max(low + Self.lowerGainHeadroomDB, confirmed - Self.contradictionDB)
        return lowered < coupling.gainDB ? .lowered(lowered) : .consistent
    }

    // MARK: Gate

    /// How the gate sees mic `bin`. The predicted bleed is the loudest known
    /// reference bin within one bin of the delay (the timestamps jitter) plus
    /// the coupling gain; the bin is bleed when the reference is active there
    /// and the mic is no louder than that plus the double-talk margin. Unknown
    /// levels never gate.
    private func decide(_ bin: Int, _ coupling: Coupling, referenceMin: Int) -> Decision {
        let micLevel = mic.level(bin, minCount: 1)
        if micLevel.isNaN { return .unknown }
        var loudest = -Double.infinity
        var known = false
        for offset in -1...1 {
            let level = reference.level(bin - coupling.lagBins + offset, minCount: referenceMin)
            if !level.isNaN {
                known = true
                if level > loudest { loudest = level }
            }
        }
        guard known else { return .unknown }
        guard loudest >= activeFloorDB else { return .pass }
        let predicted = loudest + coupling.gainDB
        if micLevel <= predicted + doubleTalkMarginDB { return .bleed(excessDB: micLevel - predicted) }
        return micLevel > predicted + Self.userEvidenceDB ? .user : .pass
    }

    /// Bleed, and if the user was just talking (or is about to), no louder
    /// than the bleed itself.
    private func isGated(_ bin: Int, _ coupling: Coupling, referenceMin: Int, newest: Int) -> Bool {
        guard case .bleed(let excess) = decide(bin, coupling, referenceMin: referenceMin) else { return false }
        if excess <= Self.hangoverMarginDB { return true }
        if let user = lastUserBin, bin >= user, bin - user <= hangoverAfterBins { return false }
        var ahead = bin + 1
        while ahead <= min(bin + hangoverBeforeBins, newest) {
            if case .user = decide(ahead, coupling, referenceMin: referenceMin) { return false }
            ahead += 1
        }
        return true
    }

    /// Attenuates the bleed bins of the buffer. Gains ramp inside gated bins
    /// only: down from wherever the previous sample was, and back up to 1 by the
    /// end of the bin when the next bin passes (or isn't known yet).
    private func gate(_ base: UnsafeMutablePointer<Float>, _ geometry: BinGeometry, _ coupling: Coupling) -> Int {
        let count = geometry.count
        let floorGain = attenuation
        let rampLength = max(1, Int(Self.rampDuration * geometry.sampleRate))
        let step = (1 - floorGain) / Float(rampLength)
        let referenceMin = referenceMinCount
        let newest = newestMicBin ?? Int.min
        var gain = rampGain
        var attenuated = 0
        var unknown = 0

        geometry.forEachSegment { bin, lower, upper, binEnd in
            var gated = false
            switch decide(bin, coupling, referenceMin: referenceMin) {
            case .user:
                lastUserBin = max(lastUserBin ?? bin, bin)
            case .unknown:
                unknown += upper - lower
            case .bleed:
                gated = isGated(bin, coupling, referenceMin: referenceMin, newest: newest)
            case .pass:
                break
            }
            guard gated else {
                gain = 1
                return
            }
            var nextGated = false
            if binEnd < count {
                nextGated = isGated(bin + 1, coupling, referenceMin: referenceMin, newest: newest)
            }
            for i in lower..<upper {
                var g = gain - step
                if g < floorGain { g = floorGain }
                if !nextGated {
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
        unknownSeconds += Double(unknown) / geometry.sampleRate
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
