import Foundation
import Testing
@testable import TSCore

enum CaptionBuilder {
    /// JIS X 0208 bytes (GL, default G0 = Kanji) for a string of full-width characters.
    static func kanji(_ s: String) -> [UInt8] {
        s.data(using: .japaneseEUC)!.map { $0 & 0x7F }
    }

    static func unit(_ body: [UInt8], parameter: UInt8 = 0x20) -> [UInt8] {
        [0x1F, parameter, UInt8(body.count >> 16), UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    /// Synchronized PES_data_packet carrying one data group.
    static func pesPayload(groupID: UInt8, groupData: [UInt8]) -> [UInt8] {
        var g: [UInt8] = [groupID << 2, 0, 0, UInt8(groupData.count >> 8), UInt8(groupData.count & 0xFF)] + groupData
        let crc = CRC16.ccitt(g)
        g += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        return [0x80, 0xFF, 0xF0] + g
    }

    static func loop(_ units: [[UInt8]]) -> [UInt8] {
        let u = units.flatMap { $0 }
        return [UInt8(u.count >> 16), UInt8((u.count >> 8) & 0xFF), UInt8(u.count & 0xFF)] + u
    }

    static func management(languages: [String]) -> [UInt8] {
        var d: [UInt8] = [0x3F, UInt8(languages.count)] // TMD = free
        for (tag, code) in languages.enumerated() {
            d += [UInt8(tag << 5) | 0x10 | 0x0A] + Array(code.utf8) + [0x00] // DMF 0b1010, format/TCS/rollup
        }
        return pesPayload(groupID: 0x00, groupData: d + loop([]))
    }

    static func statement(_ body: [UInt8], language: UInt8 = 1) -> [UInt8] {
        pesPayload(groupID: language, groupData: [0x3F] + loop([unit(body)]))
    }
}

@Suite struct CaptionTests {
    @Test func crc16() {
        #expect(CRC16.ccitt(Array("123456789".utf8)) == 0x31C3)
    }

    @Test func parsesManagementData() throws {
        let g = try #require(CaptionDataGroup(pesPayload: CaptionBuilder.management(languages: ["jpn", "eng"])))
        #expect(g.isManagement)
        #expect(g.languages == [CaptionLanguage(tag: 0, code: "jpn"), CaptionLanguage(tag: 1, code: "eng")])
    }

    @Test func rejectsBadCRC() {
        var p = CaptionBuilder.statement(CaptionBuilder.kanji("字幕"))
        p[p.count - 1] ^= 0xFF
        #expect(CaptionDataGroup(pesPayload: p) == nil)
    }

    @Test func statementRowsAndClear() {
        var dec = CaptionDecoder()
        dec.feed(CaptionBuilder.management(languages: ["jpn"]))
        // CS, APS(row 9), "こんにちは", APS(row 10), "世界"
        let body: [UInt8] = [0x0C, 0x1C, 0x40 + 9, 0x40] + CaptionBuilder.kanji("こんにちは")
            + [0x1C, 0x40 + 10, 0x40] + CaptionBuilder.kanji("世界")
        let shown = dec.feed(CaptionBuilder.statement(body))
        #expect(shown)
        #expect(dec.screen.lines == ["こんにちは", "世界"])
        // A statement that only clears.
        let cleared = dec.feed(CaptionBuilder.statement([0x0C]))
        #expect(cleared)
        #expect(dec.screen.lines.isEmpty)
    }

    @Test func newLineAndRubyDropped() {
        var screen = CaptionScreen()
        // NSZ 漢字 SSZ かんじ(ruby) NSZ APR です
        let body: [UInt8] = [0x8A] + CaptionBuilder.kanji("漢字") + [0x88] + CaptionBuilder.kanji("かんじ")
            + [0x8A, 0x0D] + CaptionBuilder.kanji("です")
        screen.apply(body)
        #expect(screen.lines == ["漢字", "です"])
    }

    @Test func dotPositionOrdersLines() {
        var screen = CaptionScreen()
        func acps(_ x: Int, _ y: Int) -> [UInt8] { [0x9B] + Array("\(x);\(y)".utf8) + [0x20, 0x61] }
        // Lower line first, then the upper one.
        screen.apply(acps(170, 479) + CaptionBuilder.kanji("下") + acps(170, 419) + CaptionBuilder.kanji("上"))
        #expect(screen.lines == ["上", "下"])
    }

    @Test func defaultMacroAndAlnum() {
        var screen = CaptionScreen()
        // SS3 0x60 → default macro: G0 Kanji, G1 alnum, G2 hiragana, G3 macro. Then LS1 "TV" LS0 番組.
        screen.apply([0x1D, 0x60, 0x0E] + Array("TV".utf8) + [0x0F] + CaptionBuilder.kanji("番組"))
        #expect(screen.lines == ["TV番組"])
    }

    @Test func otherLanguageIgnored() {
        var dec = CaptionDecoder()
        dec.feed(CaptionBuilder.management(languages: ["jpn", "eng"]))
        let ignored = dec.feed(CaptionBuilder.statement(CaptionBuilder.kanji("英語"), language: 2))
        #expect(!ignored)
        dec.languageIndex = 1
        let shown = dec.feed(CaptionBuilder.statement(CaptionBuilder.kanji("英語"), language: 2))
        #expect(shown)
        #expect(dec.screen.lines == ["英語"])
    }

    @Test func demuxerRoutesCaptionPES() {
        var cc0: UInt8 = 0, cc1: UInt8 = 0, ccc: UInt8 = 0
        var ts: [UInt8] = []
        ts += TSBuilder.packets(pid: 0, payload: TSBuilder.section(tableID: 0, ext: 1, body: [0x04, 0x00, 0xE1, 0xF0]), isSection: true, cc: &cc0)
        let pmtBody: [UInt8] = [0xE1, 0x00, 0xF0, 0x00,
                                0x02, 0xE1, 0x00, 0xF0, 0x03, 0x52, 0x01, 0x00,
                                0x0F, 0xE1, 0x10, 0xF0, 0x03, 0x52, 0x01, 0x10,
                                0x06, 0xE1, 0x30, 0xF0, 0x03, 0x52, 0x01, 0x30]
        ts += TSBuilder.packets(pid: 0x01F0, payload: TSBuilder.section(tableID: 2, ext: 0x0400, body: pmtBody), isSection: true, cc: &cc1)
        let caption = CaptionBuilder.statement([0x0C] + CaptionBuilder.kanji("字幕"))
        ts += TSBuilder.packets(pid: 0x0130, payload: TSBuilder.pes(streamID: 0xBD, pts: 123_456, payload: caption), isSection: false, cc: &ccc)

        let demux = TSDemuxer()
        var selection: StreamSelection?
        var got: [PESPacket] = []
        demux.onSelectionChanged = { selection = $0 }
        demux.onPES = { t, _, p in if t == .caption { got.append(p) } }
        demux.feed(Data(ts))

        #expect(selection?.caption?.pid == 0x0130)
        #expect(got.count == 1)
        #expect(got.first?.pts == 123_456)
        var dec = CaptionDecoder()
        let shown = dec.feed(got[0].payload)
        #expect(shown)
        #expect(dec.screen.lines == ["字幕"])
    }
}
