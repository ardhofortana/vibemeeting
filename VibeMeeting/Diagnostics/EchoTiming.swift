import Foundation

/// How the call audio (the bleed gate's reference) and the mic line up in
/// time on this Mac, for the report. Nothing here changes what the gate does.
///
/// The two streams carry host-clock stamps by different conventions: the tap's
/// is the IO cycle's input time on a tap-only aggregate device, the mic's is
/// AVAudioEngine's time for the first frame of a ~100 ms buffer. Neither says
/// exactly when the sound was in the room, so the gate searches for the delay
/// between them instead of assuming one. It can only use mic audio whose call
/// audio has already reached it, though, so the report shows:
/// - each stream's stamp age on delivery (delivery time minus the stamped end
///   of the buffer): how the stamp convention relates to real time;
/// - the call audio's wait in the processing queue before it reaches the gate;
/// - how far the call audio reaching the gate was ahead of the mic buffer's
///   stamped end, both when the mic buffer was delivered and when the gate
///   judged it (after `MicHold`); the gate's delay must stay under the latter;
/// - gaps between consecutive stamps (a stamp that doesn't advance with the
///   audio, or a missing host time replaced by the callback time).
///
/// Thread safe; recording never allocates (fixed histograms).
final class EchoTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var referenceAge = DelayHistogram()
    private var micAge = DelayHistogram()
    private var referenceQueue = DelayHistogram()
    private var leadOnDelivery = DelayHistogram()
    private var leadWhenJudged = DelayHistogram()
    private var referenceGap = DelayHistogram()
    private var micGap = DelayHistogram()
    private var lastReferenceEnd: Double?
    private var lastMicEnd: Double?

    /// A call-audio buffer stamped `start..<end`, delivered by the IO cycle at
    /// `deliveredAt` and added to the gate at `fedAt` (host-clock seconds).
    func recordReference(start: Double, end: Double, deliveredAt: Double, fedAt: Double) {
        lock.lock()
        defer { lock.unlock() }
        referenceAge.record(deliveredAt - end)
        referenceQueue.record(fedAt - deliveredAt)
        if let last = lastReferenceEnd { referenceGap.record(start - last) }
        lastReferenceEnd = end
    }

    /// A mic buffer stamped `start..<end`, delivered at `deliveredAt`, when
    /// the gate had the call audio through `referenceThrough`.
    func recordMicDelivered(start: Double, end: Double, deliveredAt: Double, referenceThrough: Double?) {
        lock.lock()
        defer { lock.unlock() }
        micAge.record(deliveredAt - end)
        if let last = lastMicEnd { micGap.record(start - last) }
        lastMicEnd = end
        if let referenceThrough { leadOnDelivery.record(referenceThrough - end) }
    }

    /// The gate judged the mic buffer ending at `end` with the call audio
    /// through `referenceThrough`.
    func recordMicJudged(end: Double, referenceThrough: Double?) {
        guard let referenceThrough else { return }
        lock.lock()
        defer { lock.unlock() }
        leadWhenJudged.record(referenceThrough - end)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        referenceAge.reset()
        micAge.reset()
        referenceQueue.reset()
        leadOnDelivery.reset()
        leadWhenJudged.reset()
        referenceGap.reset()
        micGap.reset()
        lastReferenceEnd = nil
        lastMicEnd = nil
    }

    /// One line for the Audio check.
    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        guard let median = leadWhenJudged.quantile(0.5) else { return "no mic audio judged yet" }
        return String(format: "call audio ahead of the mic when judged: median %+.0f ms, worst %+.0f ms",
                      median * 1000, leadWhenJudged.minimum * 1000)
    }

    /// Lines for the copyable report.
    func reportLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "  timing (ms; p10 / median / p90, min, max, n):",
            "    call audio stamp age on delivery: \(referenceAge.summary)",
            "    mic stamp age on delivery: \(micAge.summary)",
            "    call audio queue wait before the gate: \(referenceQueue.summary)",
            "    call audio ahead of mic end, on mic delivery: \(leadOnDelivery.summary)",
            "    call audio ahead of mic end, when judged: \(leadWhenJudged.summary)",
            "    stamp gaps, call audio: \(referenceGap.summary)",
            "    stamp gaps, mic: \(micGap.summary)",
        ]
    }
}

/// A distribution of delays (seconds) in fixed 0.5 ms bins from -1 s to +2 s,
/// so recording never allocates. Values outside count in the edge bins; the
/// exact minimum and maximum are kept.
struct DelayHistogram {
    static let lower = -1.0
    static let binWidth = 0.000_5
    static let binCount = 6_000

    private var counts = [Int](repeating: 0, count: DelayHistogram.binCount)
    private(set) var count = 0
    private(set) var minimum = Double.infinity
    private(set) var maximum = -Double.infinity

    mutating func record(_ seconds: Double) {
        guard seconds.isFinite else { return }
        count += 1
        if seconds < minimum { minimum = seconds }
        if seconds > maximum { maximum = seconds }
        let position = ((seconds - Self.lower) / Self.binWidth).rounded(.down)
        let index = position < 0 ? 0 : min(Int(min(position, Double(Self.binCount))), Self.binCount - 1)
        counts[index] += 1
    }

    mutating func reset() {
        for i in counts.indices { counts[i] = 0 }
        count = 0
        minimum = .infinity
        maximum = -.infinity
    }

    /// The `p`-quantile (0...1) to within a bin, clamped to the values seen
    /// (the lowest and highest ranks are the exact extremes); nil when nothing
    /// was recorded.
    func quantile(_ p: Double) -> Double? {
        guard count > 0 else { return nil }
        let rank = min(count, max(1, Int((min(max(p, 0), 1) * Double(count)).rounded(.up))))
        if rank == 1 { return minimum }
        if rank == count { return maximum }
        var seen = 0
        for index in counts.indices {
            seen += counts[index]
            if seen >= rank {
                let center = Self.lower + (Double(index) + 0.5) * Self.binWidth
                return min(max(center, minimum), maximum)
            }
        }
        return maximum
    }

    /// "3.0 / 5.0 / 8.5, min -1.0, max 12.0, n 3455" in milliseconds.
    var summary: String {
        guard count > 0, let p10 = quantile(0.1), let p50 = quantile(0.5), let p90 = quantile(0.9) else { return "–" }
        return String(format: "%.1f / %.1f / %.1f, min %.1f, max %.1f, n %d",
                      p10 * 1000, p50 * 1000, p90 * 1000, minimum * 1000, maximum * 1000, count)
    }
}
