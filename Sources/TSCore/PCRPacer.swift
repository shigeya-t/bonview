import Foundation

/// Real-time pacing for a recorded TS: maps the stream's PCR onto the wall clock so that a
/// file is handed to the player no faster than it would arrive from a tuner.
///
/// The first PID seen carrying a PCR is followed. Data may run up to `lead` seconds ahead of
/// real time (initial buffering). PCR jumps (wrap, splice, file loop) and stalls on our side
/// re-base the mapping instead of causing a burst or a long sleep.
public struct PCRPacer {
    /// How far ahead of real time data may be handed over.
    public var lead: Double = 1.0
    /// Whether a PCR has been seen yet (if not, the caller needs a fallback).
    public var hasPCR: Bool { pcrPID != nil }

    private var splitter = TSPacketSplitter()
    private var pcrPID: UInt16?
    private var base: (pcr: Double, wall: Double)?
    private var lastPCR: Double?

    public init() {}

    public mutating func reset() {
        splitter.reset()
        pcrPID = nil
        base = nil
        lastPCR = nil
    }

    /// Scans `data` (the next chunk to be played) and returns how many seconds to wait, from
    /// `now` (monotonic seconds), before handing it over.
    public mutating func delay(for data: Data, now: Double) -> Double {
        var latest: Double?
        splitter.split(data) { p in
            guard let pcr = p.pcr else { return }
            if pcrPID == nil { pcrPID = p.pid }
            if p.pid == pcrPID { latest = pcr }
        }
        guard let pcr = latest else { return 0 }
        defer { lastPCR = pcr }
        if let last = lastPCR, pcr < last - 1 || pcr > last + 5 { base = nil } // discontinuity
        guard let b = base else {
            base = (pcr, now)
            return 0
        }
        let due = b.wall + (pcr - b.pcr) - lead
        if now - due > 2 {
            // We fell behind (decoder stall, machine asleep): resume from here, don't burst.
            base = (pcr, now)
            return 0
        }
        return max(0, due - now)
    }
}
