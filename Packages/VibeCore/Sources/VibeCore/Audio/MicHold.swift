import Foundation

/// Holds mic audio back, briefly, until the call audio it overlaps has reached
/// the echo gate.
///
/// `EchoGate` can only judge mic audio whose reference (the call audio at the
/// coupling delay) it already has; anything else is unknown and passes
/// untouched. The two streams don't arrive in step: the mic comes in ~100 ms
/// buffers on AVAudioEngine's thread, the call audio in ~10 ms IO cycles on
/// Core Audio's, through a queue, and each device stamps its audio by its own
/// convention. So the reference can come in after the mic audio it overlaps,
/// and a gate fed in arrival order then sees only unknowns at the end of every
/// mic buffer (or in all of it).
///
/// Each mic buffer waits here until the reference it needs has arrived, or
/// until newer mic audio reaches `maxHold` past its end, whichever comes
/// first, and buffers always leave in order. Nothing waits while the
/// reference is on time, and nothing waits for a reference that has stopped
/// coming (system audio down or rebuilding). The cost is a little latency for
/// the mic's transcript, and only when the reference is late.
///
/// Thread safe. `push` and `flush` hand buffers on in order under one lock, so
/// the mic thread and a final flush never interleave; `referenceArrived` takes
/// its own lock and never waits for a buffer being handed on.
public final class MicHold<Element>: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Longest a buffer waits for its reference, in mic time: it leaves
        /// once newer mic audio reaches this far past its end.
        public var maxHold: Double
        /// A reference this far behind the newest mic audio has stopped
        /// coming: nothing waits for it.
        public var staleAfter: Double
        /// Buffers waiting at once, at most: a bound on memory whatever the
        /// timestamps say, high enough that `maxHold` decides even for small
        /// mic buffers.
        public var maxPending: Int

        public init(maxHold: Double = 0.3, staleAfter: Double = 1.0, maxPending: Int = 32) {
            self.maxHold = maxHold
            self.staleAfter = staleAfter
            self.maxPending = maxPending
        }
    }

    public struct Stats: Equatable, Sendable {
        /// Buffers handed on.
        public var releasedBuffers = 0
        /// Of those, buffers that waited for their reference.
        public var heldBuffers = 0
        /// Of those, buffers that left after `maxHold` without their reference.
        public var timedOutBuffers = 0
        /// Total and longest wait, in mic time (newer mic audio past the
        /// buffer's end when it left): the latency the hold added.
        public var heldSeconds = 0.0
        public var maxHeldSeconds = 0.0

        public init() {}
    }

    /// Mic audio the echo gate needs the reference for, through this time:
    /// through all but the buffer's last 0.15 s while the gate searches for the
    /// coupling (the search only uses bins whose reference is in), and through
    /// the end minus the delay plus two bins once a coupling is armed (the gate
    /// looks a bin to either side of the delay, and the last mic bin may be partial).
    public static func referenceNeeded(forMicEndingAt end: Double, coupledLag: Double?) -> Double {
        // While searching, the gate tolerates up to 20% unknown bins in a
        // window; waiting only for all but the last 0.15 s (half that budget)
        // keeps headphone users from waiting on every buffer for nothing.
        guard let lag = coupledLag, lag.isFinite else { return end - 0.15 }
        return end - lag + 0.02
    }

    public let configuration: Configuration

    private struct Pending {
        var element: Element
        var end: Double
        var needed: Double
    }

    /// Slack for buffer ends that are a hair short of `maxHold` apart.
    private static var timeTolerance: Double { 0.005 }

    private let lock = NSLock()
    private var pending: [Pending] = []
    private var newestEnd: Double?
    private var counters = Stats()
    /// After `flush`, buffers pass straight through until `reset`: a mic
    /// callback still in flight at the end of capture is never stranded.
    private var isFlushed = false

    private let referenceLock = NSLock()
    private var referenceEnd: Double?

    public init(configuration: Configuration = Configuration()) {
        var configuration = configuration
        if !configuration.maxHold.isFinite || configuration.maxHold < 0 { configuration.maxHold = 0 }
        if !configuration.staleAfter.isFinite || configuration.staleAfter < 0 { configuration.staleAfter = 0 }
        configuration.maxPending = max(1, configuration.maxPending)
        self.configuration = configuration
        pending.reserveCapacity(configuration.maxPending + 1)
    }

    /// The reference has reached the gate through `end` (seconds, the clock
    /// the mic's times use). Call it right after `EchoGate.addReference`.
    public func referenceArrived(through end: Double) {
        guard end.isFinite else { return }
        referenceLock.lock()
        defer { referenceLock.unlock() }
        if referenceEnd.map({ end > $0 }) ?? true { referenceEnd = end }
    }

    /// Newest reference time that has arrived, if any.
    public var referenceArrivedThrough: Double? {
        referenceLock.lock()
        defer { referenceLock.unlock() }
        return referenceEnd
    }

    /// Takes a mic buffer that ends at `end` and needs the reference through
    /// `needed` (see `referenceNeeded`), and hands on, oldest first, every
    /// waiting buffer that may go now. `release` runs under the hold's lock:
    /// it must not call `push`, `flush`, `stats` or `reset` (reading
    /// `referenceArrivedThrough` is fine; it has its own lock).
    public func push(_ element: Element, end: Double, referenceNeeded needed: Double, release: (Element) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard end.isFinite, needed.isFinite, !isFlushed else {
            // Can't place it in time, or capture is over: let it and
            // everything before it go.
            releaseAll(release)
            count(waited: 0, held: false, timedOut: false)
            release(element)
            return
        }
        pending.append(Pending(element: element, end: end, needed: needed))
        let newest = max(newestEnd ?? end, end)
        newestEnd = newest
        let reference = referenceArrivedThrough
        while let first = pending.first {
            let waited = max(0, newest - first.end)
            let arrived = reference.map { $0 >= first.needed } ?? false
            let stopped = reference.map { $0 < newest - configuration.staleAfter } ?? true
            let timedOut = waited >= configuration.maxHold - Self.timeTolerance
            guard arrived || stopped || timedOut || pending.count > configuration.maxPending else { break }
            pending.removeFirst()
            count(waited: waited, held: waited > 0, timedOut: !arrived && !stopped)
            release(first.element)
        }
    }

    /// Hands on every waiting buffer, in order, at the end of capture. Until
    /// `reset`, later buffers then pass straight through.
    public func flush(release: (Element) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        releaseAll(release)
        isFlushed = true
    }

    public var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// Forgets the waiting buffers (without handing them on), the reference
    /// and the counters, ready for a new capture.
    public func reset() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        newestEnd = nil
        counters = Stats()
        isFlushed = false
        lock.unlock()
        referenceLock.lock()
        referenceEnd = nil
        referenceLock.unlock()
    }

    // MARK: Private (under `lock`)

    private func releaseAll(_ release: (Element) -> Void) {
        let newest = newestEnd ?? -.infinity
        while !pending.isEmpty {
            let first = pending.removeFirst()
            let waited = max(0, newest - first.end)
            count(waited: waited, held: waited > 0, timedOut: false)
            release(first.element)
        }
    }

    private func count(waited: Double, held: Bool, timedOut: Bool) {
        counters.releasedBuffers += 1
        guard held else { return }
        counters.heldBuffers += 1
        if timedOut { counters.timedOutBuffers += 1 }
        counters.heldSeconds += waited
        counters.maxHeldSeconds = max(counters.maxHeldSeconds, waited)
    }
}
