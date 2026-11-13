import Foundation
import Testing
@testable import TSCore

@Suite struct AACChannelModeTests {
    /// ADTS header (no CRC unless `crc`) followed by `body`.
    static func adts(chanConfig: Int, crc: Bool = false, body: [UInt8]) -> Data {
        let len = 7 + (crc ? 2 : 0) + body.count
        var h: [UInt8] = [0xFF, crc ? 0xF0 : 0xF1,
                          UInt8(1 << 6 | 3 << 2 | (chanConfig >> 2)),           // AAC LC, 48 kHz
                          UInt8((chanConfig & 3) << 6 | (len >> 11)),
                          UInt8((len >> 3) & 0xFF), UInt8((len & 7) << 5 | 0x1F), 0xFC]
        if crc { h += [0, 0] }
        return Data(h + body)
    }

    /// Packs (value, width) fields MSB-first, padded with zeros.
    static func bits(_ fields: [(Int, Int)]) -> [UInt8] {
        var out: [UInt8] = [], acc = 0, n = 0
        for (v, w) in fields {
            for i in stride(from: w - 1, through: 0, by: -1) {
                acc = acc << 1 | (v >> i & 1); n += 1
                if n == 8 { out.append(UInt8(acc)); acc = 0; n = 0 }
            }
        }
        if n > 0 { out.append(UInt8(acc << (8 - n))) }
        return out + [0, 0, 0, 0]
    }

    static func pce(front: [Bool], side: Int = 0, back: Int = 0, mixdown: Bool = false) -> [UInt8] {
        var f: [(Int, Int)] = [(5, 3), (0, 4), (1, 2), (3, 4), (front.count, 4), (side, 4), (back, 4),
                               (0, 2), (0, 3), (0, 4)]
        f += mixdown ? [(1, 1), (0, 4), (1, 1), (0, 4), (1, 1), (0, 3)] : [(0, 1), (0, 1), (0, 1)]
        for isCPE in front { f += [(isCPE ? 1 : 0, 1), (0, 4)] }
        return bits(f)
    }

    @Test func sceWithStereoConfigIsDualMono() {
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 2, body: Self.bits([(0, 3), (0, 4)]))) == .dualMono)
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 2, crc: true, body: Self.bits([(0, 3), (0, 4)]))) == .dualMono)
    }

    @Test func sceWithoutPCEIsDualMono() {
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 0, body: Self.bits([(0, 3), (0, 4)]))) == .dualMono)
    }

    @Test func stereoAndMonoAreNot() {
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 2, body: Self.bits([(1, 3), (0, 4)]))) == .other)
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 1, body: Self.bits([(0, 3), (0, 4)]))) == .other)
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 6, body: Self.bits([(0, 3), (0, 4)]))) == .other)
    }

    @Test func pceWithTwoFrontSCEsIsDualMono() {
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 0, body: Self.pce(front: [false, false]))) == .dualMono)
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 0, body: Self.pce(front: [false, false], mixdown: true))) == .dualMono)
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 0, body: Self.pce(front: [true]))) == .other)
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 0, body: Self.pce(front: [false, true]))) == .other)
        #expect(AACChannelMode.detect(adts: Self.adts(chanConfig: 0, body: Self.pce(front: [false, false], back: 1))) == .other)
    }

    @Test func rejectsNonADTS() {
        #expect(AACChannelMode.detect(adts: Data([0x47, 0x00, 0x11, 0x22])) == nil)
        #expect(AACChannelMode.detect(adts: Data()) == nil)
    }

    /// Real encoder output (ffmpeg, stereo → CPE) must not be taken for dual mono.
    @Test func ffmpegStereoIsNotDualMono() throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile) else { return }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-\(UUID()).aac")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "sine=f=440:d=0.2", "-ac", "2", "-c:a", "aac", "-f", "adts", out.path]
        try p.run(); p.waitUntilExit()
        #expect(AACChannelMode.detect(adts: try Data(contentsOf: out)) == .other)
    }
}
