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

@Suite struct PacketLevelRobustnessTests {
    @Test func pesHeaderSplitAcrossPackets() {
        // The first packet carries only 4 bytes of PES (long adaptation field): PES_packet_length
        // comes in the next one. The PES must still end at its length, not wait for the next start.
        let pes = TSBuilder.pes(streamID: 0xE0, pts: 9000, payload: [UInt8](repeating: 0xAB, count: 300))
        var asm = PESAssembler()
        var out: [PESPacket] = []
        let first = Array(pes.prefix(4)), rest = Array(pes.dropFirst(4))
        first.withUnsafeBytes { asm.push($0, unitStart: true) { out.append($0) } }
        rest.withUnsafeBytes { asm.push($0, unitStart: false) { out.append($0) } }
        #expect(out.count == 1)
        #expect(out.first?.payload.count == 300)
        #expect(out.first?.pts == 9000)
    }

    @Test func splitterAcrossChunkBoundaries() {
        // Packets fed in odd-sized chunks come out whole and in order (the carry path).
        var cc: UInt8 = 0
        var ts: [UInt8] = []
        for i in 0..<20 { ts += TSBuilder.packets(pid: 0x100, payload: [UInt8](repeating: UInt8(i), count: 184), isSection: false, cc: &cc) }
        var s = TSPacketSplitter()
        var seen: [UInt8] = []
        var i = 0
        for size in [1, 187, 189, 500, 376, 3, 1000, 2000] where i < ts.count {
            let chunk = Data(ts[i..<min(i + size, ts.count)])
            i += chunk.count
            s.split(chunk) { p in seen.append(p.payload!.first!) }
        }
        if i < ts.count { s.split(Data(ts[i...])) { p in seen.append(p.payload!.first!) } }
        #expect(seen == (0..<20).map(UInt8.init))
        #expect(s.syncLossCount == 0)
    }

    @Test func loneSyncByteInGarbageIsNotAPacket() {
        // Garbage with a single 0x47 exactly one packet before the end: nothing is emitted until
        // the next sync byte confirms it (this used to come out as a packet).
        var s = TSPacketSplitter()
        var count = 0
        var garbage = [UInt8](repeating: 0x11, count: 300)
        garbage[112] = 0x47
        s.split(Data(garbage)) { _ in count += 1 }
        #expect(count == 0)
        #expect(s.syncLossCount > 0)
        s.reset()
        #expect(s.syncLossCount == 0)
    }

    @Test func multiSectionNITKeepsEveryStream() {
        // Section 0 lists another TS; ours is in section 1, which arrives first.
        func nit(_ section: UInt8, tsid: UInt16, key: UInt8) -> [UInt8] {
            let tsInfo: [UInt8] = [0xCD, 2, key, 0]
            let loop: [UInt8] = [UInt8(tsid >> 8), UInt8(tsid & 0xFF), 0x7F, 0xE0, 0xF0, UInt8(tsInfo.count)] + tsInfo
            let body: [UInt8] = [0xF0, 0x00, 0xF0 | UInt8(loop.count >> 8), UInt8(loop.count & 0xFF)] + loop
            var s = TSBuilder.section(tableID: 0x40, ext: 0x7FE0, sectionNumber: section, body: body)
            s[7] = 1 // last_section_number
            let crc = CRC32MPEG2.checksum(Array(s.dropLast(4)))
            s.replaceSubrange((s.count - 4)..., with: [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
            return s
        }
        var cc0: UInt8 = 0, cc1: UInt8 = 0
        var ts = TSBuilder.packets(pid: 0x10, payload: nit(1, tsid: 0x7FE1, key: 1), isSection: true, cc: &cc1)
        ts += TSBuilder.packets(pid: 0x10, payload: nit(0, tsid: 0x7FE8, key: 8), isSection: true, cc: &cc1)
        ts += TSBuilder.packets(pid: 0, payload: TSBuilder.section(tableID: 0, ext: 0x7FE1, body: [0x04, 0x00, 0xE1, 0xF0]), isSection: true, cc: &cc0)
        let demux = TSDemuxer()
        demux.feed(Data(ts))
        #expect(demux.remoteControlKeyID == 1)
    }

    @Test func duplicatePacketsDoNotBreakEPGSections() throws {
        // Each packet sent twice (allowed by ISO 13818-1): the collector must skip the copies. The
        // section spans more than two packets, so a copied middle packet would be appended into it.
        let title = String(repeating: "A", count: 200)
        let events = (0..<3).map {
            EITBuilder.Ev(id: UInt16(1 + $0), start: EPGTests.base.addingTimeInterval(Double($0) * 3600), minutes: 60, title: title)
        }
        let section = EITBuilder.section(table: 0x50, sid: 9, tsid: 8, onid: 7, number: 0, last: 0, segmentLast: 0, lastTable: 0x50,
                                         events: events)
        #expect(section.count > 2 * 184)
        let ts = [UInt8](EITBuilder.packets([section]))
        var doubled: [UInt8] = []
        for i in stride(from: 0, to: ts.count, by: 188) { doubled += ts[i..<(i + 188)] + ts[i..<(i + 188)] }
        let collector = EPGCollector()
        collector.feed(Data(doubled))
        collector.flush()
        let store = collector.takeUpdates()
        #expect(store.eventCount == 3)
    }
}

@Suite struct ParserRobustnessTests {
    @Test func invalidBCDTimesAreRejected() {
        #expect(AribTime.date(mjdBCD: [0xE4, 0x4F, 0x12, 0x34, 0x56]) != nil)
        #expect(AribTime.date(mjdBCD: [0xE4, 0x4F, 0x1A, 0x34, 0x56]) == nil) // nibble > 9
        #expect(AribTime.date(mjdBCD: [0xE4, 0x4F, 0x25, 0x00, 0x00]) == nil) // hour 25
        #expect(AribTime.date(mjdBCD: [0x00, 0x01, 0x12, 0x00, 0x00]) == nil) // MJD before 1900
        #expect(AribTime.duration(bcd: [0x01, 0x30, 0x00]) == 5400)
        #expect(AribTime.duration(bcd: [0x01, 0x60, 0x00]) == nil)
    }

    @Test func malformedControlSequencesDoNotSwallowText() {
        let ascii: [UInt8] = [0x1B, 0x28, 0x4A] + Array("ABC".utf8)
        // A lone macro end (0x95 0x4F).
        #expect(ARIBString.decode([0x95, 0x4F] + ascii) == "ABC")
        // A CSI that never terminates only drops the CSI byte.
        #expect(ARIBString.decode(ascii + [0x9B] + ascii).hasSuffix("ABC"))
        // Kanji designated as a 1-byte set (ESC ( B): the following ASCII set still decodes.
        #expect(ARIBString.decode([0x1B, 0x28, 0x42, 0x21] + ascii) == "〓ABC")
    }

    @Test func drcs0AndOneByteDRCSDoNotCollide() throws {
        // A DRCS-0 character 0x4121 and the 1-byte set F = 0x41, code 0x21 are different glyphs.
        let oneByte: [UInt8] = [1, 0x41, 0x21, 1, 0x00, 0, 2, 1, 0b1000_0000]
        let twoByte: [UInt8] = [1, 0x41, 0x21, 1, 0x00, 0, 2, 1, 0b0100_0000]
        let a = try #require(CaptionDRCS.parseUnit(oneByte)[0x4121])
        let b = try #require(CaptionDRCS.parseUnit(twoByte, drcs0: true)[CaptionDRCS.drcs0Flag | 0x4121])
        #expect(a != b)

        // DRCS sent with the management data is used by the statements.
        var dec = CaptionDecoder()
        let management = CaptionBuilder.pesPayload(groupID: 0, groupData: [0x3F, 1, 0x00, 0x6A, 0x70, 0x6E, 0x50]
            + CaptionBuilder.loop([CaptionBuilder.unit(oneByte, parameter: 0x30)]))
        dec.feed(management)
        let body: [UInt8] = [0x0C, 0x1B, 0x28, 0x20, 0x41, 0x21]
        dec.feed(CaptionBuilder.pesPayload(groupID: 1, groupData: [0x3F] + CaptionBuilder.loop([CaptionBuilder.unit(body)])))
        #expect(dec.frame.glyphs.first?.content == .drcs(a))
    }

    @Test func pruneKeepsPendingExtendedItems() throws {
        let ext = EITBuilder.section(table: 0x58, sid: 1, tsid: 1, onid: 1, number: 0, last: 0, segmentLast: 0, lastTable: 0x58,
                                     events: [.init(id: 5, start: EPGTests.base, minutes: 30, extended: [("H", "T")])])
        let basic = EITBuilder.section(table: 0x50, sid: 1, tsid: 1, onid: 1, number: 0, last: 0, segmentLast: 0, lastTable: 0x50,
                                       events: [.init(id: 5, start: EPGTests.base, minutes: 30, title: "X")])
        var store = EPGStore()
        store.apply(try #require(EIT(ext)))
        store.prune(before: EPGTests.base.addingTimeInterval(-3600)) // a periodic save in between
        store.apply(try #require(EIT(basic)))
        let key = EPGServiceKey(originalNetworkID: 1, transportStreamID: 1, serviceID: 1)
        #expect(store.event(for: key, at: EPGTests.base)?.extended == [ExtendedEventItem(heading: "H", text: "T")])
    }
}
