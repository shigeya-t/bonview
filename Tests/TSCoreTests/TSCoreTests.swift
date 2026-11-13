import Foundation
import Testing
@testable import TSCore

// MARK: - Synthetic TS builder

enum TSBuilder {
    static func section(tableID: UInt8, ext: UInt16, version: UInt8 = 0, sectionNumber: UInt8 = 0, body: [UInt8]) -> [UInt8] {
        let len = 5 + body.count + 4
        var s: [UInt8] = [tableID, 0xB0 | UInt8(len >> 8), UInt8(len & 0xFF), UInt8(ext >> 8), UInt8(ext & 0xFF),
                          0xC1 | (version << 1), sectionNumber, sectionNumber]
        s += body
        let crc = CRC32MPEG2.checksum(s)
        s += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return s
    }

    static func packets(pid: UInt16, payload: [UInt8], isSection: Bool, cc: inout UInt8) -> [UInt8] {
        var data = isSection ? [0] + payload : payload
        var out: [UInt8] = []
        var first = true
        while !data.isEmpty {
            let chunk = Array(data.prefix(184))
            data.removeFirst(chunk.count)
            var pkt: [UInt8] = [0x47, (first ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF)]
            if chunk.count < 184 {
                // pad via adaptation field
                let afLen = 183 - chunk.count
                pkt.append(0x30 | cc)
                pkt.append(UInt8(afLen))
                if afLen > 0 { pkt.append(0x00); pkt += [UInt8](repeating: 0xFF, count: afLen - 1) }
            } else {
                pkt.append(0x10 | cc)
            }
            pkt += chunk
            precondition(pkt.count == 188)
            out += pkt
            cc = (cc + 1) & 0x0F
            first = false
        }
        return out
    }

    static func pes(streamID: UInt8, pts: Int64, payload: [UInt8]) -> [UInt8] {
        let p: [UInt8] = [
            0x21 | UInt8((pts >> 29) & 0x0E), UInt8((pts >> 22) & 0xFF), UInt8(((pts >> 14) & 0xFE) | 1),
            UInt8((pts >> 7) & 0xFF), UInt8(((pts << 1) & 0xFE) | 1),
        ]
        let len = 3 + p.count + payload.count
        return [0, 0, 1, streamID, UInt8(len >> 8), UInt8(len & 0xFF), 0x80, 0x80, UInt8(p.count)] + p + payload
    }

    /// ARIB encode of plain ASCII (alnum set via LS1? keep simple: ESC ( J then ASCII).
    static func service(_ id: UInt16, name: [UInt8]) -> [UInt8] {
        let provider: [UInt8] = []
        let desc: [UInt8] = [0x48, UInt8(3 + provider.count + name.count), 0x01, UInt8(provider.count)] + provider + [UInt8(name.count)] + name
        return [UInt8(id >> 8), UInt8(id & 0xFF), 0xFD, 0x80 | UInt8(desc.count >> 8), UInt8(desc.count & 0xFF)] + desc
    }
}

// MARK: - Tests

@Suite struct ARIBStringTests {
    @Test func kanjiViaDefaultG0() {
        // 日 = 0x467C, 本 = 0x4B5C in JIS X 0208
        #expect(ARIBString.decode([0x46, 0x7C, 0x4B, 0x5C]) == "日本")
    }

    @Test func hiraganaInGR() {
        // GR = G2 = hiragana by default: あ = 0x22 | 0x80
        #expect(ARIBString.decode([0xA2, 0xF3]) == "あん")
    }

    @Test func alnumAndKatakanaDesignation() {
        // ESC ( J  → G0 = alnum, then "NHK"; ESC ( 1 → G0 = katakana, "テ"(0x46)
        #expect(ARIBString.decode([0x1B, 0x28, 0x4A, 0x4E, 0x48, 0x4B, 0x1B, 0x28, 0x31, 0x46]) == "NHKテ")
    }

    @Test func lockingShiftToAlnum() {
        // LS1 (0x0E) → GL = G1 = alnum
        #expect(ARIBString.decode([0x0E, 0x42, 0x53, 0x31]) == "BS1")
    }

    @Test func additionalSymbol() {
        #expect(ARIBString.decode([0x7A, 0x56]) == "[字]")
    }

    @Test func gaijiTable() {
        #expect(ARIBString.gaiji.count == 10 * 94)
        #expect(ARIBString.decode([0x7D, 0x7A]) == "♬")          // row 93: music mark used in captions
        #expect(ARIBString.decode([0x7E, 0x7A]) == "\u{277F}")   // row 94: dingbat negative circled 10
        #expect(ARIBString.decode([0x75, 0x22]) == "\u{20158}")  // row 85: additional kanji (non-BMP)
        #expect(ARIBString.decode([0x7D, 0x21 + 13]) == "\u{2121}") // row 93 cell 14: ℡
        #expect(ARIBString.decode([0x7C, 0x21 + 63]) == "〓")    // private-use only → no glyph
        #expect(ARIBString.decode([0x76, 0x7E]) == "〓")         // unassigned
    }
}

@Suite struct DemuxTests {
    @Test func crc() {
        #expect(CRC32MPEG2.checksum(Array("123456789".utf8)) == 0x0376_E6E7)
    }

    @Test func mjd() {
        // 2024-01-01 12:34:56 JST: MJD 60310 = 0xEB96
        let d = AribTime.date(mjdBCD: [0xEB, 0x96, 0x12, 0x34, 0x56])!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2024, 1, 1, 12, 34, 56])
    }

    @Test func endToEnd() {
        var cc0: UInt8 = 0, cc1: UInt8 = 0, cc2: UInt8 = 0, ccv: UInt8 = 0, cca: UInt8 = 0
        var ts: [UInt8] = []
        // PAT: service 0x0400 → PMT 0x01F0, one-seg 0x05C8 → 0x1FC8
        ts += TSBuilder.packets(pid: 0, payload: TSBuilder.section(tableID: 0, ext: 0x7FE0, body: [0x05, 0xC8, 0xFF, 0xC8, 0x04, 0x00, 0xE1, 0xF0]), isSection: true, cc: &cc0)
        // PMTs
        let pmtBody: [UInt8] = [0xE1, 0x00, 0xF0, 0x00,
                                0x02, 0xE1, 0x00, 0xF0, 0x03, 0x52, 0x01, 0x00,
                                0x0F, 0xE1, 0x10, 0xF0, 0x03, 0x52, 0x01, 0x10]
        ts += TSBuilder.packets(pid: 0x01F0, payload: TSBuilder.section(tableID: 2, ext: 0x0400, body: pmtBody), isSection: true, cc: &cc1)
        let oneSeg: [UInt8] = [0xE1, 0x00, 0xF0, 0x00, 0x1B, 0xE2, 0x00, 0xF0, 0x00]
        var ccs: UInt8 = 0
        ts += TSBuilder.packets(pid: 0x1FC8, payload: TSBuilder.section(tableID: 2, ext: 0x05C8, body: oneSeg), isSection: true, cc: &ccs)
        // SDT with kanji name 日本
        let sdtBody: [UInt8] = [0x7F, 0xE1, 0xFF] + TSBuilder.service(0x0400, name: [0x46, 0x7C, 0x4B, 0x5C])
        ts += TSBuilder.packets(pid: 0x11, payload: TSBuilder.section(tableID: 0x42, ext: 0x7FE0, body: sdtBody), isSection: true, cc: &cc2)
        // Two video PES (second flushes the first, since video PES length is bounded here too)
        let video = [UInt8](repeating: 0xAB, count: 500)
        let videoPTS: Int64 = 0x1_2345_6789
        ts += TSBuilder.packets(pid: 0x0100, payload: TSBuilder.pes(streamID: 0xE0, pts: videoPTS, payload: video), isSection: false, cc: &ccv)
        ts += TSBuilder.packets(pid: 0x0110, payload: TSBuilder.pes(streamID: 0xC0, pts: 90000, payload: [1, 2, 3]), isSection: false, cc: &cca)

        let demux = TSDemuxer()
        var services: [ServiceInfo] = []
        var selection: StreamSelection?
        var got: [(TSDemuxer.Track, PESPacket)] = []
        demux.onServicesChanged = { services = $0 }
        demux.onSelectionChanged = { selection = $0 }
        demux.onPES = { t, _, p in got.append((t, p)) }

        // Feed in odd-sized chunks to exercise the splitter.
        var i = 0
        while i < ts.count {
            let n = min(77, ts.count - i)
            demux.feed(Data(ts[i..<(i + n)]))
            i += n
        }

        #expect(services.map(\.serviceID) == [0x05C8, 0x0400])
        #expect(services.first { $0.serviceID == 0x0400 }?.name == "日本")
        #expect(services.first { $0.serviceID == 0x05C8 }?.isOneSeg == true)
        #expect(selection?.serviceID == 0x0400) // one-seg skipped
        #expect(selection?.video?.pid == 0x0100)
        #expect(selection?.audio?.streamType == 0x0F)
        #expect(got.count == 2)
        #expect(got.first { $0.0 == .video }?.1.payload.count == 500)
        let vpts = got.first { $0.0 == .video }?.1.pts
        #expect(vpts == videoPTS)
        #expect(got.first { $0.0 == .audio }?.1.pts == 90000)
        #expect(demux.stats.continuityErrors == 0)

        demux.preferredServiceID = 0x05C8
        #expect(selection?.video?.streamType == 0x1B)
    }

    /// NIT with two TSs; the TS information descriptor carries the remote-control key.
    static func nitSection() -> [UInt8] {
        func ts(_ tsid: UInt16, key: UInt8, name: [UInt8], services: [(UInt16, UInt8)]) -> [UInt8] {
            let tsInfo: [UInt8] = [0xCD, UInt8(2 + name.count + 4), key, UInt8(name.count << 2 | 1)] + name
                + [0x0F, UInt8(services.count)] + services.flatMap { [UInt8($0.0 >> 8), UInt8($0.0 & 0xFF)] }
            let list: [UInt8] = [0x41, UInt8(services.count * 3)] + services.flatMap { [UInt8($0.0 >> 8), UInt8($0.0 & 0xFF), $0.1] }
            let d = tsInfo.count + list.count
            // tsInfo length byte covers key, len, name, type info, count, ids
            var fixed = tsInfo
            fixed[1] = UInt8(fixed.count - 2)
            return [UInt8(tsid >> 8), UInt8(tsid & 0xFF), 0x7F, 0xE0, 0xF0 | UInt8(d >> 8), UInt8(d & 0xFF)] + fixed + list
        }
        let name: [UInt8] = [0x40, 6, 0x0E, 0x54, 0x4F, 0x4B, 0x59, 0x4F] // network name "TOKYO" (LS1 + ASCII)
        let loop = ts(0x7FE8, key: 8, name: [0x0E, 0x43, 0x58], services: [(0x0420, 0x01), (0x0421, 0x01), (0x05A8, 0xC0)])
            + ts(0x7FE1, key: 1, name: [], services: [(0x0400, 0x01)])
        let body: [UInt8] = [0xF0, UInt8(name.count)] + name + [0xF0 | UInt8(loop.count >> 8), UInt8(loop.count & 0xFF)] + loop
        return TSBuilder.section(tableID: 0x40, ext: 0x7FE0, body: body)
    }

    @Test func nitRemoteControlKey() {
        let nit = NIT(Self.nitSection())
        #expect(nit?.networkID == 0x7FE0)
        #expect(nit?.networkName == "TOKYO")
        #expect(nit?.transportStreams.map(\.transportStreamID) == [0x7FE8, 0x7FE1])
        #expect(nit?.transportStreams.map(\.remoteControlKeyID) == [8, 1])
        #expect(nit?.transportStreams.first?.name == "CX")
        #expect(nit?.transportStreams.first?.services.map(\.id) == [0x0420, 0x0421, 0x05A8])

        // Demuxer: key for the current TS only, after PAT and NIT in either order.
        var cc0: UInt8 = 0, cc1: UInt8 = 0
        var ts = TSBuilder.packets(pid: 0x10, payload: Self.nitSection(), isSection: true, cc: &cc1)
        ts += TSBuilder.packets(pid: 0, payload: TSBuilder.section(tableID: 0, ext: 0x7FE8, body: [0x04, 0x20, 0xE1, 0xF0]), isSection: true, cc: &cc0)
        let demux = TSDemuxer()
        demux.feed(Data(ts))
        #expect(demux.hasNIT)
        #expect(demux.remoteControlKeyID == 8)
    }

    @Test func splitterResyncs() {
        var s = TSPacketSplitter()
        var count = 0
        var data = Data([0x00, 0x12, 0x34])
        for _ in 0..<3 { data.append(0x47); data.append(Data(repeating: 0, count: 187)) }
        s.split(data) { _ in count += 1 }
        #expect(count == 3)
        #expect(s.syncLossCount == 1)
    }
}

// MARK: - EIT p/f for all services

@Suite struct ProgramCacheTests {
    /// EIT p/f section with one event (title in ASCII via ESC ( J), or none.
    static func eit(table: UInt8, sid: UInt16, tsid: UInt16, onid: UInt16, section: UInt8,
                    eventID: UInt16, start: [UInt8], durationBCD: [UInt8], title: String?) -> [UInt8] {
        var body: [UInt8] = [UInt8(tsid >> 8), UInt8(tsid & 0xFF), UInt8(onid >> 8), UInt8(onid & 0xFF), 0x01, table]
        if let title {
            let name: [UInt8] = [0x1B, 0x28, 0x4A] + Array(title.utf8)
            let desc: [UInt8] = [0x4D, UInt8(5 + name.count), 0x6A, 0x70, 0x6E, UInt8(name.count)] + name + [0]
            body += [UInt8(eventID >> 8), UInt8(eventID & 0xFF)] + start + durationBCD
                + [0x80 | UInt8(desc.count >> 8), UInt8(desc.count & 0xFF)] + desc
        }
        return TSBuilder.section(tableID: table, ext: sid, sectionNumber: section, body: body)
    }

    // MJD 60310 = 2024-01-01; 12:00:00 JST
    static let noon: [UInt8] = [0xEB, 0x96, 0x12, 0x00, 0x00]
    static let oneThirty: [UInt8] = [0xEB, 0x96, 0x13, 0x30, 0x00]

    @Test func demuxReportsActualAndOther() {
        var cc: UInt8 = 0
        var ts = TSBuilder.packets(pid: 0x12, payload: Self.eit(table: 0x4E, sid: 0x0400, tsid: 0x7FE1, onid: 0x7FE1, section: 0,
                                                                eventID: 1, start: Self.noon, durationBCD: [0x01, 0x00, 0x00], title: "NEWS"),
                                   isSection: true, cc: &cc)
        ts += TSBuilder.packets(pid: 0x12, payload: Self.eit(table: 0x4F, sid: 0x0065, tsid: 0x4010, onid: 4, section: 1,
                                                             eventID: 2, start: Self.oneThirty, durationBCD: [0x00, 0x30, 0x00], title: "MOVIE"),
                                isSection: true, cc: &cc)
        // Same section again: no duplicate callback.
        ts += TSBuilder.packets(pid: 0x12, payload: Self.eit(table: 0x4E, sid: 0x0400, tsid: 0x7FE1, onid: 0x7FE1, section: 0,
                                                             eventID: 1, start: Self.noon, durationBCD: [0x01, 0x00, 0x00], title: "NEWS"),
                                isSection: true, cc: &cc)
        let demux = TSDemuxer()
        var updates: [ServiceEventUpdate] = []
        demux.onServiceEvent = { updates.append($0) }
        demux.feed(Data(ts))
        #expect(updates.count == 2)
        #expect(updates.first?.serviceID == 0x0400 && updates.first?.isFollowing == false)
        #expect(updates.first?.event?.title == "NEWS")
        #expect(updates.last?.originalNetworkID == 4 && updates.last?.transportStreamID == 0x4010)
        #expect(updates.last?.isFollowing == true && updates.last?.event?.title == "MOVIE")
    }

    @Test func currentEventFollowsClock() throws {
        var cache = ProgramCache()
        let present = try #require(EIT(Self.eit(table: 0x4E, sid: 1, tsid: 2, onid: 3, section: 0, eventID: 1, start: Self.noon,
                                                durationBCD: [0x01, 0x00, 0x00], title: "A")))
        let following = try #require(EIT(Self.eit(table: 0x4E, sid: 1, tsid: 2, onid: 3, section: 1, eventID: 2, start: Self.oneThirty,
                                                  durationBCD: [0x00, 0x30, 0x00], title: "B")))
        cache.update(ServiceEventUpdate(originalNetworkID: 3, transportStreamID: 2, serviceID: 1, isFollowing: false, event: present.events.first))
        cache.update(ServiceEventUpdate(originalNetworkID: 3, transportStreamID: 2, serviceID: 1, isFollowing: true, event: following.events.first))
        let start = try #require(present.events.first?.start)
        func title(_ offset: TimeInterval, onid: UInt16? = 3) -> String? {
            cache.currentEvent(originalNetworkID: onid, transportStreamID: 2, serviceID: 1, at: start.addingTimeInterval(offset))?.title
        }
        #expect(title(10 * 60) == "A")
        #expect(title(10 * 60, onid: nil) == "A")
        #expect(title(10 * 60, onid: 9) == nil)
        #expect(title(65 * 60) == nil)       // between A's end (13:00) and B's start (13:30)
        #expect(title(95 * 60) == "B")
        #expect(title(125 * 60) == nil)      // both over
    }
}
