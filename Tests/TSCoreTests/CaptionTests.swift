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

@Suite struct CaptionLayoutTests {
    static func csi(_ params: String, _ final: UInt8) -> [UInt8] { [0x9B] + Array(params.utf8) + [0x20, final] }

    /// Typical HD caption header: SWF 7 (960×540), SDF 620×480 at SDP (170,30), 36×36 chars, SHS 4, SVS 24.
    static let header: [UInt8] = csi("7", 0x53) + csi("620;480", 0x56) + csi("170;30", 0x5F)
        + csi("36;36", 0x57) + csi("4", 0x58) + csi("24", 0x59)

    @Test func apsPlacesCellsInDisplayArea() throws {
        var screen = CaptionScreen()
        screen.apply(Self.header + [0x1C, 0x40 + 2, 0x40 + 3] + CaptionBuilder.kanji("字幕"))
        let g = screen.frame.glyphs
        #expect(g.count == 2)
        let first = try #require(g.first)
        #expect(first.x == 170 + 3 * 40)
        #expect(first.y == 30 + 2 * 60)
        #expect(first.width == 40 && first.height == 60)
        #expect(first.charWidth == 36 && first.charHeight == 36)
        #expect(g[1].x == first.x + 40)
        #expect(screen.frame.planeWidth == 960)
    }

    @Test func acpsIsLowerLeftOfCell() throws {
        var screen = CaptionScreen()
        screen.apply(Self.header + Self.csi("250;479", 0x61) + CaptionBuilder.kanji("あ"))
        let g = try #require(screen.frame.glyphs.first)
        #expect(g.x == 250 && g.y == 479 - 60)
    }

    @Test func coloursAndPalette() throws {
        var screen = CaptionScreen()
        // YLF (palette 0), COL palette 4 (the half-opacity copy of 0–15), COL background 0.
        // Colours are resolved against the palette in effect when they are designated.
        screen.apply([0x83, 0x90, 0x20, 0x44, 0x90, 0x50] + CaptionBuilder.kanji("色"))
        let g = try #require(screen.frame.glyphs.first)
        #expect(g.foreground == CaptionColor(255, 255, 0))
        #expect(g.background == CaptionColor(0, 0, 0, 128))
    }

    @Test func sizesAndRuby() throws {
        var screen = CaptionScreen()
        // MSZ "A", SSZ "る", NSZ "字"
        screen.apply(Self.header + [0x1C, 0x41, 0x40, 0x89, 0x0E, 0x41, 0x88, 0x0F] + CaptionBuilder.kanji("る")
                     + [0x8A] + CaptionBuilder.kanji("字"))
        let g = screen.frame.glyphs
        #expect(g.map(\.width) == [20, 20, 40])
        #expect(g.map(\.height) == [60, 30, 60])
        #expect(g.map(\.isSmall) == [false, true, false])
        #expect(screen.lines == ["A字"])
    }

    @Test func wrapsAtAreaEdge() {
        var screen = CaptionScreen()
        // Area 80 dots wide → 2 cells per row.
        screen.apply(Self.csi("80;480", 0x56) + CaptionBuilder.kanji("一二三"))
        #expect(screen.frame.glyphs.map(\.y) == [0, 0, 60])
        #expect(screen.lines == ["一二", "三"])
    }

    @Test func repeatCharacter() {
        var screen = CaptionScreen()
        screen.apply([0x98, 0x43] + CaptionBuilder.kanji("ー"))
        #expect(screen.lines == ["ーーー"])
    }

    @Test func drcsPattern() throws {
        // 1-byte DRCS set 1 (F = 0x41), code 0x21: 2-level 4×2 pattern 1001 0110.
        let unit: [UInt8] = [1, 0x41, 0x21, 1, 0x00, 0, 4, 2, 0b1001_0110]
        let patterns = CaptionDRCS.parseUnit(unit)
        let p = try #require(patterns[0x4121])
        #expect(p.width == 4 && p.height == 2)
        #expect(p.pixels == [1, 0, 0, 1, 0, 1, 1, 0])

        var dec = CaptionDecoder()
        // ESC ( SP A → G0 = DRCS-1, then 0x21.
        let body: [UInt8] = [0x0C, 0x1B, 0x28, 0x20, 0x41, 0x21]
        let group = CaptionBuilder.pesPayload(groupID: 1, groupData: [0x3F] + CaptionBuilder.loop([
            CaptionBuilder.unit(unit, parameter: 0x30), CaptionBuilder.unit(body)]))
        let shown = dec.feed(group)
        #expect(shown)
        #expect(dec.frame.glyphs.first?.content == .drcs(p))
    }

    @Test func managementFormatSetsPlane() {
        var dec = CaptionDecoder()
        // Format 5 = 1920×1080 horizontal.
        var d: [UInt8] = [0x3F, 1, 0x1A] + Array("jpn".utf8) + [0x50]
        d += CaptionBuilder.loop([])
        dec.feed(CaptionBuilder.pesPayload(groupID: 0, groupData: d))
        dec.feed(CaptionBuilder.statement(CaptionBuilder.kanji("大")))
        #expect(dec.frame.planeWidth == 1920)
        #expect(dec.frame.glyphs.first?.width == 80)
    }

    @Test func clut() {
        #expect(CaptionColor.clut.count == 128)
        #expect(CaptionColor.clut[8].isTransparent)
        #expect(CaptionColor.clut[7] == CaptionColor(255, 255, 255))
        #expect(CaptionColor.clut[64] == CaptionColor(0, 0, 0, 128))
    }

    @Test func demuxerRoutesSuperimpose() {
        var cc0: UInt8 = 0, cc1: UInt8 = 0, ccs: UInt8 = 0
        var ts: [UInt8] = []
        ts += TSBuilder.packets(pid: 0, payload: TSBuilder.section(tableID: 0, ext: 1, body: [0x04, 0x00, 0xE1, 0xF0]), isSection: true, cc: &cc0)
        let pmtBody: [UInt8] = [0xE1, 0x00, 0xF0, 0x00,
                                0x02, 0xE1, 0x00, 0xF0, 0x03, 0x52, 0x01, 0x00,
                                0x06, 0xE1, 0x38, 0xF0, 0x03, 0x52, 0x01, 0x38]
        ts += TSBuilder.packets(pid: 0x01F0, payload: TSBuilder.section(tableID: 2, ext: 0x0400, body: pmtBody), isSection: true, cc: &cc1)
        ts += TSBuilder.packets(pid: 0x0138, payload: TSBuilder.pes(streamID: 0xBD, pts: 1, payload: CaptionBuilder.statement(CaptionBuilder.kanji("速報"))), isSection: false, cc: &ccs)
        let demux = TSDemuxer()
        var selection: StreamSelection?
        var tracks: [TSDemuxer.Track] = []
        demux.onSelectionChanged = { selection = $0 }
        demux.onPES = { t, _, _ in tracks.append(t) }
        demux.feed(Data(ts))
        #expect(selection?.caption == nil)
        #expect(selection?.superimpose?.pid == 0x0138)
        #expect(tracks == [.superimpose])
    }
}
