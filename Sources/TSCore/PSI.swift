import Foundation

// MARK: - CRC

public enum CRC32MPEG2 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = (c & 0x8000_0000) != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }

    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(b))] }
        return crc
    }
}

// MARK: - Section assembly

/// Reassembles PSI/SI sections from TS packet payloads of one PID.
public struct SectionAssembler {
    private var buffer: [UInt8] = []
    private var collecting = false

    public init() {}

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        collecting = false
    }

    /// Feed one packet's payload. Complete sections (CRC already verified when applicable)
    /// are passed to `emit`.
    public mutating func push(_ payload: UnsafeRawBufferPointer, unitStart: Bool, _ emit: ([UInt8]) -> Void) {
        var p = payload[...]
        if unitStart {
            guard let pointer = p.first else { return }
            p = p.dropFirst()
            let ptr = Int(pointer)
            guard ptr <= p.count else { reset(); return }
            if collecting {
                buffer.append(contentsOf: p.prefix(ptr))
                drain(emit)
            }
            buffer.removeAll(keepingCapacity: true)
            buffer.append(contentsOf: p.dropFirst(ptr))
            collecting = true
        } else {
            guard collecting else { return }
            buffer.append(contentsOf: p)
        }
        drain(emit)
    }

    private mutating func drain(_ emit: ([UInt8]) -> Void) {
        while collecting {
            guard let first = buffer.first else { return }
            if first == 0xFF { reset(); return } // stuffing
            guard buffer.count >= 3 else { return }
            let len = 3 + (Int(buffer[1] & 0x0F) << 8 | Int(buffer[2]))
            guard buffer.count >= len else { return }
            let section = Array(buffer[0..<len])
            buffer.removeFirst(len)
            if Self.isValid(section) { emit(section) }
        }
    }

    static func isValid(_ s: [UInt8]) -> Bool {
        let syntax = s[1] & 0x80 != 0
        // TDT (0x70) has no CRC; TOT (0x73) has one despite section_syntax_indicator == 0.
        if syntax || s[0] == 0x73 {
            guard s.count >= 7 else { return false }
            return CRC32MPEG2.checksum(s) == 0
        }
        return true
    }
}

// MARK: - Byte reading helpers

extension Array where Element == UInt8 {
    @inline(__always) func u16(_ i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    @inline(__always) func u12(_ i: Int) -> Int { Int(self[i] & 0x0F) << 8 | Int(self[i + 1]) }
    @inline(__always) func u13(_ i: Int) -> UInt16 { UInt16(self[i] & 0x1F) << 8 | UInt16(self[i + 1]) }
}

/// Common long-form section header.
public struct SectionHeader {
    public var tableID: UInt8
    public var tableIDExtension: UInt16
    public var version: UInt8
    public var currentNext: Bool
    public var sectionNumber: UInt8
    public var lastSectionNumber: UInt8

    init?(_ s: [UInt8]) {
        guard s.count >= 12 else { return nil }
        tableID = s[0]
        tableIDExtension = s.u16(3)
        version = (s[5] >> 1) & 0x1F
        currentNext = s[5] & 1 != 0
        sectionNumber = s[6]
        lastSectionNumber = s[7]
    }
}

public struct Descriptor {
    public var tag: UInt8
    public var data: ArraySlice<UInt8>

    static func parse(_ s: [UInt8], from: Int, length: Int) -> [Descriptor] {
        var out: [Descriptor] = []
        var i = from
        let end = Swift.min(from + length, s.count)
        while i + 2 <= end {
            let tag = s[i], len = Int(s[i + 1])
            guard i + 2 + len <= end else { break }
            out.append(Descriptor(tag: tag, data: s[(i + 2)..<(i + 2 + len)]))
            i += 2 + len
        }
        return out
    }
}

// MARK: - PAT

public struct PAT: Equatable {
    public var transportStreamID: UInt16
    /// program_number → PMT PID (program 0 / NIT excluded)
    public var programs: [(programNumber: UInt16, pmtPID: UInt16)]

    public init?(_ s: [UInt8]) {
        guard s[0] == 0x00, let h = SectionHeader(s) else { return nil }
        transportStreamID = h.tableIDExtension
        programs = []
        var i = 8
        while i + 4 <= s.count - 4 {
            let num = s.u16(i), pid = s.u13(i + 2)
            if num != 0 { programs.append((num, pid)) }
            i += 4
        }
    }

    public static func == (a: PAT, b: PAT) -> Bool {
        a.transportStreamID == b.transportStreamID && a.programs.elementsEqual(b.programs) { $0 == $1 }
    }
}

// MARK: - PMT

public struct ElementaryStreamInfo: Equatable, Sendable {
    public var streamType: UInt8
    public var pid: UInt16
    public var componentTag: UInt8?

    public var isVideo: Bool { [0x01, 0x02, 0x1B, 0x24].contains(streamType) }
    public var isAudio: Bool { [0x03, 0x04, 0x0F, 0x11].contains(streamType) }
    /// ARIB caption / superimpose (private PES with data_component 0x0008).
    public var isCaption: Bool { streamType == 0x06 && (componentTag.map { (0x30...0x37).contains($0) } ?? false) }

    public var codecName: String {
        switch streamType {
        case 0x01: return "MPEG-1 Video"
        case 0x02: return "MPEG-2 Video"
        case 0x1B: return "H.264"
        case 0x24: return "HEVC"
        case 0x03, 0x04: return "MPEG Audio"
        case 0x0F: return "AAC"
        case 0x11: return "AAC (LATM)"
        case 0x06: return "Private PES"
        case 0x0D: return "DSM-CC"
        default: return String(format: "0x%02X", streamType)
        }
    }
}

public struct PMT: Equatable {
    public var programNumber: UInt16
    public var version: UInt8
    public var pcrPID: UInt16
    public var streams: [ElementaryStreamInfo]
    /// CA_descriptor present in program info (ECM PID) – i.e. the service is scrambled.
    public var ecmPID: UInt16?

    public init?(_ s: [UInt8]) {
        guard s[0] == 0x02, let h = SectionHeader(s) else { return nil }
        programNumber = h.tableIDExtension
        version = h.version
        pcrPID = s.u13(8)
        let progInfoLen = s.u12(10)
        ecmPID = Descriptor.parse(s, from: 12, length: progInfoLen).first { $0.tag == 0x09 && $0.data.count >= 4 }
            .map { d in UInt16(d.data[d.data.startIndex + 2] & 0x1F) << 8 | UInt16(d.data[d.data.startIndex + 3]) }
        streams = []
        var i = 12 + progInfoLen
        let end = s.count - 4
        while i + 5 <= end {
            let type = s[i], pid = s.u13(i + 1), infoLen = s.u12(i + 3)
            let descs = Descriptor.parse(s, from: i + 5, length: infoLen)
            let tag = descs.first { $0.tag == 0x52 && !$0.data.isEmpty }.map { $0.data.first! }
            streams.append(ElementaryStreamInfo(streamType: type, pid: pid, componentTag: tag))
            i += 5 + infoLen
        }
    }
}

// MARK: - SDT

public struct SDT {
    public struct Service {
        public var serviceID: UInt16
        public var serviceType: UInt8
        public var providerName: String
        public var name: String
        public var hasEITPresentFollowing: Bool
        public var freeCA: Bool
    }

    public var transportStreamID: UInt16
    public var originalNetworkID: UInt16
    public var services: [Service]

    public init?(_ s: [UInt8]) {
        guard s[0] == 0x42, let h = SectionHeader(s), s.count >= 15 else { return nil }
        transportStreamID = h.tableIDExtension
        originalNetworkID = s.u16(8)
        services = []
        var i = 11
        let end = s.count - 4
        while i + 5 <= end {
            let sid = s.u16(i)
            let pf = s[i + 2] & 0x01 != 0
            let freeCA = s[i + 3] & 0x10 != 0
            let len = s.u12(i + 3)
            var svc = Service(serviceID: sid, serviceType: 0, providerName: "", name: "", hasEITPresentFollowing: pf, freeCA: freeCA)
            for d in Descriptor.parse(s, from: i + 5, length: len) where d.tag == 0x48 {
                let b = Array(d.data)
                guard b.count >= 3 else { continue }
                svc.serviceType = b[0]
                let pl = Int(b[1])
                guard 2 + pl < b.count else { continue }
                svc.providerName = ARIBString.decode(b[2..<(2 + pl)])
                let nl = Int(b[2 + pl])
                let ns = 3 + pl
                svc.name = ARIBString.decode(b[ns..<min(ns + nl, b.count)])
            }
            services.append(svc)
            i += 5 + len
        }
    }
}

// MARK: - EIT (present / following)

public struct EventInfo: Equatable, Sendable {
    public var serviceID: UInt16
    public var eventID: UInt16
    public var start: Date?
    public var duration: TimeInterval?
    public var title: String
    public var text: String

    public var end: Date? {
        guard let s = start, let d = duration else { return nil }
        return s.addingTimeInterval(d)
    }
}

public struct EIT {
    public var tableID: UInt8
    public var serviceID: UInt16
    public var sectionNumber: UInt8
    public var events: [EventInfo]

    public init?(_ s: [UInt8]) {
        guard (0x4E...0x6F).contains(s[0]), let h = SectionHeader(s), s.count >= 18 else { return nil }
        tableID = s[0]
        serviceID = h.tableIDExtension
        sectionNumber = h.sectionNumber
        events = []
        var i = 14
        let end = s.count - 4
        while i + 12 <= end {
            let eid = s.u16(i)
            let start = AribTime.date(mjdBCD: Array(s[(i + 2)..<(i + 7)]))
            let dur = AribTime.duration(bcd: Array(s[(i + 7)..<(i + 10)]))
            let len = s.u12(i + 10)
            var ev = EventInfo(serviceID: serviceID, eventID: eid, start: start, duration: dur, title: "", text: "")
            for d in Descriptor.parse(s, from: i + 12, length: len) where d.tag == 0x4D {
                let b = Array(d.data)
                guard b.count >= 5 else { continue }
                let nl = Int(b[3])
                ev.title = ARIBString.decode(b[4..<min(4 + nl, b.count)])
                if 4 + nl < b.count {
                    let tl = Int(b[4 + nl])
                    let ts = 5 + nl
                    ev.text = ARIBString.decode(b[min(ts, b.count)..<min(ts + tl, b.count)])
                }
            }
            events.append(ev)
            i += 12 + len
        }
    }
}

// MARK: - NIT

/// Network Information Table (actual network, table 0x40).
public struct NIT: Equatable {
    public struct TransportStream: Equatable {
        public var transportStreamID: UInt16
        public var originalNetworkID: UInt16
        /// ISDB-T: remote-control "one-touch" key (1–12) from the TS information descriptor (0xCD).
        public var remoteControlKeyID: UInt8?
        /// TS name from the TS information descriptor (e.g. "フジテレビ").
        public var name: String?
        /// service_list_descriptor (0x41): service IDs and types in broadcast order.
        public var services: [(id: UInt16, type: UInt8)]

        public static func == (a: Self, b: Self) -> Bool {
            a.transportStreamID == b.transportStreamID && a.originalNetworkID == b.originalNetworkID
                && a.remoteControlKeyID == b.remoteControlKeyID && a.name == b.name
                && a.services.map(\.id) == b.services.map(\.id) && a.services.map(\.type) == b.services.map(\.type)
        }
    }

    public var networkID: UInt16
    public var networkName: String?
    public var transportStreams: [TransportStream]

    public init?(_ s: [UInt8]) {
        guard s[0] == 0x40, let h = SectionHeader(s), s.count >= 16 else { return nil }
        networkID = h.tableIDExtension
        networkName = nil
        transportStreams = []
        let end = s.count - 4
        let ndl = s.u12(8)
        guard 10 + ndl + 2 <= end else { return nil }
        for d in Descriptor.parse(s, from: 10, length: ndl) where d.tag == 0x40 {
            networkName = ARIBString.decode(d.data)
        }
        var i = 10 + ndl + 2
        let loopEnd = min(i + s.u12(10 + ndl), end)
        while i + 6 <= loopEnd {
            let len = s.u12(i + 4)
            var ts = TransportStream(transportStreamID: s.u16(i), originalNetworkID: s.u16(i + 2),
                                     remoteControlKeyID: nil, name: nil, services: [])
            for d in Descriptor.parse(s, from: i + 6, length: len) {
                let b = Array(d.data)
                switch d.tag {
                case 0xCD where b.count >= 2:
                    ts.remoteControlKeyID = b[0]
                    let nameLen = Int(b[1] >> 2)
                    if 2 + nameLen <= b.count { ts.name = ARIBString.decode(b[2..<(2 + nameLen)]) }
                case 0x41:
                    var k = 0
                    while k + 3 <= b.count {
                        ts.services.append((UInt16(b[k]) << 8 | UInt16(b[k + 1]), b[k + 2]))
                        k += 3
                    }
                default:
                    break
                }
            }
            transportStreams.append(ts)
            i += 6 + len
        }
    }
}

// MARK: - TOT / TDT

public enum TOT {
    /// Current broadcast time (JST) from TDT (0x70) or TOT (0x73).
    public static func time(_ s: [UInt8]) -> Date? {
        guard (s[0] == 0x70 || s[0] == 0x73), s.count >= 8 else { return nil }
        return AribTime.date(mjdBCD: Array(s[3..<8]))
    }
}

public enum AribTime {
    static let jst = TimeZone(identifier: "Asia/Tokyo")!

    @inline(__always) static func bcd(_ b: UInt8) -> Int { Int(b >> 4) * 10 + Int(b & 0x0F) }

    /// 16-bit MJD + 24-bit BCD hh:mm:ss in JST. All-ones means "undefined".
    public static func date(mjdBCD b: [UInt8]) -> Date? {
        guard b.count == 5, !b.allSatisfy({ $0 == 0xFF }) else { return nil }
        let mjd = Int(b[0]) << 8 | Int(b[1])
        // ETSI EN 300 468 Annex C
        let yp = Int((Double(mjd) - 15078.2) / 365.25)
        let mp = Int((Double(mjd) - 14956.1 - Double(Int(Double(yp) * 365.25))) / 30.6001)
        let day = mjd - 14956 - Int(Double(yp) * 365.25) - Int(Double(mp) * 30.6001)
        let k = (mp == 14 || mp == 15) ? 1 : 0
        var c = DateComponents()
        c.year = 1900 + yp + k
        c.month = mp - 1 - k * 12
        c.day = day
        c.hour = bcd(b[2])
        c.minute = bcd(b[3])
        c.second = bcd(b[4])
        c.timeZone = jst
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        return cal.date(from: c)
    }

    public static func duration(bcd b: [UInt8]) -> TimeInterval? {
        guard b.count == 3, !b.allSatisfy({ $0 == 0xFF }) else { return nil }
        return TimeInterval(bcd(b[0]) * 3600 + bcd(b[1]) * 60 + bcd(b[2]))
    }
}
