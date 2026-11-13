import Foundation
import Testing
@testable import TSCore

/// EIT section builder with full control over the schedule header fields.
enum EITBuilder {
    struct Ev {
        var id: UInt16
        var start: Date
        var minutes: Int
        var title: String = ""
        var text: String = ""
        var genre: UInt8? = nil
        var extended: [(String, String)] = []
    }

    static func mjdBCD(_ d: Date) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AribTime.jst
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let day = cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day))!
        let epoch = cal.date(from: DateComponents(year: 1858, month: 11, day: 17))!
        let mjd = Int((day.timeIntervalSince(epoch) / 86400).rounded())
        func bcd(_ v: Int) -> UInt8 { UInt8((v / 10) << 4 | (v % 10)) }
        return [UInt8(mjd >> 8), UInt8(mjd & 0xFF), bcd(c.hour!), bcd(c.minute!), bcd(c.second!)]
    }

    /// ASCII-only ARIB string (alphanumeric set via LS1).
    static func arib(_ s: String) -> [UInt8] { s.isEmpty ? [] : [0x0E] + Array(s.utf8) }

    static func event(_ e: Ev) -> [UInt8] {
        var descs: [UInt8] = []
        if !e.title.isEmpty || !e.text.isEmpty {
            let t = arib(e.title), x = arib(e.text)
            let body: [UInt8] = Array("jpn".utf8) + [UInt8(t.count)] + t + [UInt8(x.count)] + x
            descs += [0x4D, UInt8(body.count)] + body
        }
        if let g = e.genre { descs += [0x54, 2, g << 4, 0xFF] }
        if !e.extended.isEmpty {
            var items: [UInt8] = []
            for (h, t) in e.extended {
                let hb = arib(h), tb = arib(t)
                items += [UInt8(hb.count)] + hb + [UInt8(tb.count)] + tb
            }
            let body: [UInt8] = [0x00] + Array("jpn".utf8) + [UInt8(items.count)] + items + [0]
            descs += [0x4E, UInt8(body.count)] + body
        }
        let dur: [UInt8] = [UInt8((e.minutes / 60 / 10) << 4 | (e.minutes / 60 % 10)), UInt8((e.minutes % 60 / 10) << 4 | (e.minutes % 60 % 10)), 0]
        return [UInt8(e.id >> 8), UInt8(e.id & 0xFF)] + mjdBCD(e.start) + dur + [0x80 | UInt8(descs.count >> 8), UInt8(descs.count & 0xFF)] + descs
    }

    static func section(table: UInt8, sid: UInt16, tsid: UInt16, onid: UInt16, version: UInt8 = 0,
                        number: UInt8, last: UInt8, segmentLast: UInt8, lastTable: UInt8, events: [Ev]) -> [UInt8] {
        let body: [UInt8] = [UInt8(tsid >> 8), UInt8(tsid & 0xFF), UInt8(onid >> 8), UInt8(onid & 0xFF), segmentLast, lastTable]
            + events.flatMap(event)
        let len = 5 + body.count + 4
        var s: [UInt8] = [table, 0xF0 | UInt8(len >> 8), UInt8(len & 0xFF), UInt8(sid >> 8), UInt8(sid & 0xFF),
                          0xC1 | (version << 1), number, last] + body
        let crc = CRC32MPEG2.checksum(s)
        s += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return s
    }

    /// A complete one-table schedule (sections 0, 8, 16: three segments, one section each) with
    /// one event per segment starting at `base`.
    static func schedule(sid: UInt16, tsid: UInt16, onid: UInt16, base: Date, titlePrefix: String = "P") -> [[UInt8]] {
        (0..<3).map { seg in
            let ev = Ev(id: UInt16(100 + seg), start: base.addingTimeInterval(Double(seg) * 3 * 3600), minutes: 180,
                        title: "\(titlePrefix)\(seg)", genre: UInt8(seg))
            return section(table: 0x50, sid: sid, tsid: tsid, onid: onid, number: UInt8(seg * 8), last: 16,
                           segmentLast: UInt8(seg * 8), lastTable: 0x50, events: [ev])
        }
    }

    static func packets(_ sections: [[UInt8]], pid: UInt16 = 0x12) -> Data {
        var cc: UInt8 = 0
        var out: [UInt8] = []
        for s in sections { out += TSBuilder.packets(pid: pid, payload: s, isSection: true, cc: &cc) }
        return Data(out)
    }
}

@Suite struct EPGTests {
    static let base = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-07 (JST)

    @Test func parsesExtendedAndGenre() throws {
        let ev = EITBuilder.Ev(id: 7, start: Self.base, minutes: 45, title: "News", text: "Today", genre: 0x0,
                               extended: [("Cast", "A"), ("", "B"), ("Staff", "C")])
        let s = EITBuilder.section(table: 0x50, sid: 1024, tsid: 1, onid: 2, number: 0, last: 0, segmentLast: 0, lastTable: 0x50, events: [ev])
        let eit = try #require(EIT(s))
        #expect(eit.isBasicSchedule && !eit.isPresentFollowing)
        let e = try #require(eit.events.first)
        #expect(e.title == "News" && e.text == "Today" && e.genre == 0)
        #expect(e.duration == 45 * 60 && e.start == Self.base)
        // The heading-less item continues "Cast".
        #expect(e.extended == [ExtendedEventItem(heading: "Cast", text: "AB"), ExtendedEventItem(heading: "Staff", text: "C")])
    }

    @Test func storeReplacesOverlappingEvents() {
        let key = EPGServiceKey(originalNetworkID: 2, transportStreamID: 1, serviceID: 1024)
        var store = EPGStore()
        store.insert(EventInfo(serviceID: 1024, eventID: 1, start: Self.base, duration: 3600, title: "A", text: ""), for: key)
        store.insert(EventInfo(serviceID: 1024, eventID: 2, start: Self.base.addingTimeInterval(3600), duration: 3600, title: "B", text: ""), for: key)
        // Programme 3 replaces the second half of A and all of B.
        store.insert(EventInfo(serviceID: 1024, eventID: 3, start: Self.base.addingTimeInterval(1800), duration: 5400, title: "C", text: ""), for: key)
        let titles = store.events(for: key, from: Self.base, to: Self.base.addingTimeInterval(7200)).map(\.title)
        #expect(titles == ["C"])
        #expect(store.event(for: key, at: Self.base.addingTimeInterval(4000))?.title == "C")
        #expect(store.key(originalNetworkID: nil, transportStreamID: 1, serviceID: 1024) == key)

        store.prune(before: Self.base.addingTimeInterval(7201))
        #expect(store.isEmpty)
    }

    @Test func extendedArrivingFirstIsMerged() throws {
        let ext = EITBuilder.section(table: 0x58, sid: 1, tsid: 1, onid: 1, number: 0, last: 0, segmentLast: 0, lastTable: 0x58,
                                     events: [.init(id: 5, start: Self.base, minutes: 30, extended: [("H", "T")])])
        let basic = EITBuilder.section(table: 0x50, sid: 1, tsid: 1, onid: 1, number: 0, last: 0, segmentLast: 0, lastTable: 0x50,
                                       events: [.init(id: 5, start: Self.base, minutes: 30, title: "X")])
        var store = EPGStore()
        store.apply(try #require(EIT(ext)))
        store.apply(try #require(EIT(basic)))
        let key = EPGServiceKey(originalNetworkID: 1, transportStreamID: 1, serviceID: 1)
        #expect(store.event(for: key, at: Self.base)?.extended == [ExtendedEventItem(heading: "H", text: "T")])
        #expect(store.event(for: key, at: Self.base)?.title == "X")
    }

    @Test func codableRoundTrip() throws {
        var store = EPGStore()
        for s in EITBuilder.schedule(sid: 9, tsid: 8, onid: 7, base: Self.base) { store.apply(try #require(EIT(s))) }
        let data = try JSONEncoder().encode(store)
        let back = try JSONDecoder().decode(EPGStore.self, from: data)
        #expect(back == store)
        #expect(back.eventCount == 3)
        #expect(back.dateRange == Self.base...Self.base.addingTimeInterval(9 * 3600))
    }

    @Test func scheduleCompleteness() throws {
        var progress = EITScheduleProgress()
        let secs = EITBuilder.schedule(sid: 1, tsid: 2, onid: 3, base: Self.base)
        #expect(progress.record(try #require(EIT(secs[0]))))
        #expect(!progress.record(try #require(EIT(secs[0]))))
        #expect(progress.record(try #require(EIT(secs[2]))))
        #expect(!progress.isComplete(originalNetworkID: 3, transportStreamID: 2, serviceID: 1))
        progress.record(try #require(EIT(secs[1])))
        #expect(progress.isComplete(originalNetworkID: 3, transportStreamID: 2, serviceID: 1))
        #expect(progress.isComplete(originalNetworkID: nil, transportStreamID: 2, serviceID: 1))

        // A segment using two sections needs both; a second table needs its own sections.
        var p2 = EITScheduleProgress()
        let a = EITBuilder.section(table: 0x50, sid: 1, tsid: 1, onid: 1, number: 0, last: 1, segmentLast: 1, lastTable: 0x51, events: [])
        let b = EITBuilder.section(table: 0x50, sid: 1, tsid: 1, onid: 1, number: 1, last: 1, segmentLast: 1, lastTable: 0x51, events: [])
        let c = EITBuilder.section(table: 0x51, sid: 1, tsid: 1, onid: 1, number: 0, last: 0, segmentLast: 0, lastTable: 0x51, events: [])
        p2.record(try #require(EIT(a)))
        p2.record(try #require(EIT(c)))
        #expect(!p2.isComplete(originalNetworkID: 1, transportStreamID: 1, serviceID: 1))
        p2.record(try #require(EIT(b)))
        #expect(p2.isComplete(originalNetworkID: 1, transportStreamID: 1, serviceID: 1))
    }

    @Test func collectorFromPackets() {
        let collector = EPGCollector()
        let data = EITBuilder.packets(EITBuilder.schedule(sid: 1024, tsid: 0x7FE1, onid: 0x7FE1, base: Self.base))
        // Feed in odd-sized chunks, twice (sections repeat in a real stream).
        for _ in 0..<2 {
            var i = 0
            while i < data.count { let n = min(100, data.count - i); collector.feed(data.subdata(in: i..<(i + n))); i += n }
        }
        collector.flush()
        #expect(collector.isComplete(originalNetworkID: 0x7FE1, transportStreamID: 0x7FE1, serviceID: 1024))
        #expect(collector.lastNewScheduleSection != nil)
        let u = collector.takeUpdates()
        #expect(u.eventCount == 3)
        #expect(collector.takeUpdates().isEmpty)
    }
}
