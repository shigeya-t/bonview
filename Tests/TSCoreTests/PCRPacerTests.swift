import Foundation
import Testing
@testable import TSCore

@Suite struct PCRPacerTests {
    /// Adaptation-field-only packet carrying a PCR of `seconds`.
    static func pcrPacket(pid: UInt16 = 0x100, seconds: Double) -> Data {
        let ticks = Int64(seconds * 27_000_000)
        let base = ticks / 300, ext = ticks % 300
        var p: [UInt8] = [0x47, UInt8(pid >> 8), UInt8(pid & 0xFF), 0x20, 183, 0x10,
                          UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF), UInt8((base >> 9) & 0xFF),
                          UInt8((base >> 1) & 0xFF), UInt8((base & 1) << 7) | 0x7E | UInt8(ext >> 8), UInt8(ext & 0xFF)]
        p += [UInt8](repeating: 0xFF, count: 188 - p.count)
        return Data(p)
    }

    @Test func parsesPCR() {
        let d = Self.pcrPacket(seconds: 12345.678)
        let pcr = d.withUnsafeBytes { TSPacket($0).pcr }
        #expect(abs(pcr! - 12345.678) < 1e-6)
    }

    @Test func pacesToRealTimeWithLead() {
        var pacer = PCRPacer()
        pacer.lead = 1
        #expect(pacer.delay(for: Self.pcrPacket(seconds: 100), now: 50) == 0)   // anchors
        #expect(pacer.delay(for: Self.pcrPacket(seconds: 100.8), now: 50) == 0) // within lead
        #expect(abs(pacer.delay(for: Self.pcrPacket(seconds: 103), now: 50) - 2) < 1e-6)
        #expect(abs(pacer.delay(for: Self.pcrPacket(seconds: 103.5), now: 52.2) - 0.3) < 1e-6)
    }

    @Test func followsFirstPCRPIDOnly() {
        var pacer = PCRPacer()
        pacer.lead = 0
        _ = pacer.delay(for: Self.pcrPacket(pid: 0x100, seconds: 10), now: 0)
        // A PCR on another PID far ahead is ignored.
        #expect(pacer.delay(for: Self.pcrPacket(pid: 0x200, seconds: 500), now: 0) == 0)
        #expect(abs(pacer.delay(for: Self.pcrPacket(pid: 0x100, seconds: 11), now: 0) - 1) < 1e-6)
    }

    @Test func rebasesOnDiscontinuityAndStall() {
        var pacer = PCRPacer()
        pacer.lead = 0
        _ = pacer.delay(for: Self.pcrPacket(seconds: 1000), now: 0)
        // PCR jumps back (file loop / wrap): no sleep, new base.
        #expect(pacer.delay(for: Self.pcrPacket(seconds: 5), now: 1) == 0)
        #expect(abs(pacer.delay(for: Self.pcrPacket(seconds: 6), now: 1) - 1) < 1e-6)
        // We stalled for 10 s: no burst-then-wait, resume from here.
        #expect(pacer.delay(for: Self.pcrPacket(seconds: 7), now: 12) == 0)
        #expect(abs(pacer.delay(for: Self.pcrPacket(seconds: 7.5), now: 12) - 0.5) < 1e-6)
    }

    @Test func noPCRMeansNoDelay() {
        var pacer = PCRPacer()
        var p = [UInt8](repeating: 0xFF, count: 188); p[0] = 0x47; p[1] = 0x01; p[3] = 0x10
        #expect(pacer.delay(for: Data(p), now: 0) == 0)
        #expect(!pacer.hasPCR)
    }
}
