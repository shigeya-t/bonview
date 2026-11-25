import Foundation
import Testing
@testable import TSCore

/// Malformed or unusual sections and strings: no crash, no misreading.
@Suite struct SectionRobustnessTests {
    static let pmtBody: [UInt8] = [0xE1, 0x00, 0xF0, 0x00, 0x02, 0xE1, 0x11, 0xF0, 0x00]

    @Test func emptyAndShortSectionsAreRejected() {
        for s in [[], [0x00], [0x02, 0xB0], [UInt8](repeating: 0, count: 11)] as [[UInt8]] {
            #expect(PAT(s) == nil)
            #expect(PMT(s) == nil)
            #expect(SDT(s) == nil)
            #expect(EIT(s) == nil)
            #expect(NIT(s) == nil)
            #expect(TOT.time(s) == nil)
        }
        // A PMT of 12–15 bytes has no room for PCR PID + program info length before the CRC.
        let pmt = TSBuilder.section(tableID: 0x02, ext: 1, body: [0xE1])
        #expect(pmt.count < 16)
        #expect(PMT(pmt) == nil)
    }

    @Test func sectionWithoutSyntaxIndicatorIsRejected() {
        var s = TSBuilder.section(tableID: 0x02, ext: 1, body: Self.pmtBody)
        #expect(PMT(s)?.streams.count == 1)
        s[1] &= 0x7F // section_syntax_indicator lost: the CRC is no longer checked, so don't trust it
        #expect(PMT(s) == nil)
    }

    @Test func nextSectionIsIgnored() {
        var s = TSBuilder.section(tableID: 0x02, ext: 1, body: Self.pmtBody)
        s[5] &= 0xFE // current_next_indicator = 0
        #expect(PMT(s) == nil)
    }

    @Test func descriptorsStopBeforeTheCRC() {
        // program_info_length claims 4 bytes, but only the CRC follows.
        let s = TSBuilder.section(tableID: 0x02, ext: 1, body: [0xE1, 0x00, 0xF0, 0x04])
        #expect(Descriptor.parse(s, from: 12, length: 4).isEmpty)
    }
}

@Suite struct ARIBTimeControlTests {
    // 字幕 = 0x3B7A 0x4B6B in JIS X 0208
    static let jimaku: [UInt8] = [0x3B, 0x7A, 0x4B, 0x6B]

    @Test func timeModeIsThreeBytes() {
        // TIME 0x28 P2 (processing mode) before kanji: the parameter must not shift the 2-byte text.
        #expect(ARIBString.decode([0x9D, 0x28, 0x40] + Self.jimaku) == "字幕")
    }

    @Test func timeSettingRunsToItsTerminator() {
        #expect(ARIBString.decode([0x9D, 0x29, 0x31, 0x32, 0x3B, 0x33, 0x34, 0x41] + Self.jimaku) == "字幕")
    }

    @Test func waitIsThreeBytes() {
        #expect(ARIBString.decode([0x9D, 0x20, 0x45] + Self.jimaku) == "字幕")
    }
}

@Suite struct EITPIDPreferenceTests {
    @Test func mEITDoesNotReplaceHEIT() throws {
        var cc12: UInt8 = 0, cc26: UInt8 = 0
        let h = ProgramCacheTests.eit(table: 0x4E, sid: 0x0400, tsid: 0x7FE1, onid: 0x7FE1, section: 0, eventID: 1,
                                      start: ProgramCacheTests.noon, durationBCD: [0x01, 0x00, 0x00], title: "FULL")
        let m = ProgramCacheTests.eit(table: 0x4E, sid: 0x0400, tsid: 0x7FE1, onid: 0x7FE1, section: 0, eventID: 1,
                                      start: ProgramCacheTests.noon, durationBCD: [0x01, 0x00, 0x00], title: "SHORT")
        var ts = TSBuilder.packets(pid: 0x12, payload: h, isSection: true, cc: &cc12)
        ts += TSBuilder.packets(pid: 0x26, payload: m, isSection: true, cc: &cc26)
        ts += TSBuilder.packets(pid: 0x12, payload: h, isSection: true, cc: &cc12)
        let demux = TSDemuxer()
        var titles: [String?] = []
        demux.onServiceEvent = { titles.append($0.event?.title) }
        demux.feed(Data(ts))
        #expect(titles == ["FULL"])

        let collector = EPGCollector()
        collector.feed(Data(ts))
        collector.flush()
        let store = collector.takeUpdates()
        let key = try #require(store.key(originalNetworkID: 0x7FE1, transportStreamID: 0x7FE1, serviceID: 0x0400))
        #expect(store.events(for: key, from: .distantPast, to: .distantFuture).map(\.title) == ["FULL"])
    }

    @Test func lEITOnlyServiceIsKept() {
        // A one-seg service carried on the L-EIT only.
        var cc: UInt8 = 0
        let l = ProgramCacheTests.eit(table: 0x4E, sid: 0x0588, tsid: 0x7FE1, onid: 0x7FE1, section: 0, eventID: 1,
                                      start: ProgramCacheTests.noon, durationBCD: [0x01, 0x00, 0x00], title: "ONESEG")
        let demux = TSDemuxer()
        var titles: [String?] = []
        demux.onServiceEvent = { titles.append($0.event?.title) }
        demux.feed(Data(TSBuilder.packets(pid: 0x27, payload: l, isSection: true, cc: &cc)))
        #expect(titles == ["ONESEG"])
    }
}
