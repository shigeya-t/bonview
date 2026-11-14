import Foundation

public typealias EPGServiceKey = ProgramCache.ServiceKey

// MARK: - Store

/// Programme guide data: events per service, from EIT schedule (and present/following).
///
/// Events are keyed by event ID; inserting an event removes other events of the same service
/// whose time overlaps it (rescheduled / replaced programmes).
public struct EPGStore: Sendable, Equatable {
    private var services: [EPGServiceKey: [UInt16: EventInfo]] = [:]
    /// Extended items received before their basic event (extended tables cycle separately).
    private var pendingExtended: [EPGServiceKey: [UInt16: [ExtendedEventItem]]] = [:]

    public init() {}

    public var isEmpty: Bool { services.isEmpty && pendingExtended.isEmpty }
    public var serviceKeys: [EPGServiceKey] { Array(services.keys) }
    public var eventCount: Int { services.values.reduce(0) { $0 + $1.count } }

    public mutating func apply(_ eit: EIT) {
        let key = EPGServiceKey(originalNetworkID: eit.originalNetworkID, transportStreamID: eit.transportStreamID, serviceID: eit.serviceID)
        if eit.isSchedule && !eit.isBasicSchedule {
            for ev in eit.events where !ev.extended.isEmpty { setExtended(ev.extended, eventID: ev.eventID, for: key) }
        } else {
            for ev in eit.events { insert(ev, for: key) }
        }
    }

    public mutating func insert(_ ev: EventInfo, for key: EPGServiceKey) {
        guard let start = ev.start, let duration = ev.duration, duration > 0 else { return }
        var list = services[key] ?? [:]
        let old = list[ev.eventID]
        var e = ev
        if e.extended.isEmpty { e.extended = old?.extended ?? pendingExtended[key]?[ev.eventID] ?? [] }
        if e.genre == nil { e.genre = old?.genre }
        if e.text.isEmpty, let t = old?.text, e.title == old?.title { e.text = t }
        pendingExtended[key]?[ev.eventID] = nil
        if pendingExtended[key]?.isEmpty == true { pendingExtended[key] = nil }
        if old == e { return }
        let end = start.addingTimeInterval(duration)
        for (id, other) in list where id != e.eventID {
            guard let s = other.start, let oe = other.end else { continue }
            if s < end && start < oe { list[id] = nil }
        }
        list[e.eventID] = e
        services[key] = list
    }

    private mutating func setExtended(_ items: [ExtendedEventItem], eventID: UInt16, for key: EPGServiceKey) {
        if services[key]?[eventID] != nil {
            if services[key]![eventID]!.extended != items { services[key]![eventID]!.extended = items }
        } else {
            pendingExtended[key, default: [:]][eventID] = items
        }
    }

    /// Add everything from `other` (newer data wins).
    public mutating func merge(_ other: EPGStore) {
        for (key, list) in other.services {
            for ev in list.values.sorted(by: { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }) { insert(ev, for: key) }
        }
        for (key, list) in other.pendingExtended {
            for (id, items) in list { setExtended(items, eventID: id, for: key) }
        }
    }

    /// Resolve a service; `originalNetworkID` nil matches any network.
    public func key(originalNetworkID: UInt16?, transportStreamID: UInt16, serviceID: UInt16) -> EPGServiceKey? {
        if let onid = originalNetworkID {
            let k = EPGServiceKey(originalNetworkID: onid, transportStreamID: transportStreamID, serviceID: serviceID)
            return services[k] != nil ? k : nil
        }
        return services.keys.first { $0.transportStreamID == transportStreamID && $0.serviceID == serviceID }
    }

    /// Events of a service overlapping `from..<to`, by start time.
    public func events(for key: EPGServiceKey, from: Date, to: Date) -> [EventInfo] {
        guard let list = services[key] else { return [] }
        return list.values.filter { ev in
            guard let s = ev.start, let e = ev.end else { return false }
            return s < to && e > from
        }.sorted { $0.start! < $1.start! }
    }

    public func event(for key: EPGServiceKey, at date: Date) -> EventInfo? {
        services[key]?.values.first { ev in
            guard let s = ev.start, let e = ev.end else { return false }
            return s <= date && date < e
        }
    }

    /// Start of the first and end of the last event of all services.
    public var dateRange: ClosedRange<Date>? {
        var lo: Date?, hi: Date?
        for list in services.values {
            for ev in list.values {
                guard let s = ev.start, let e = ev.end else { continue }
                if lo.map({ s < $0 }) ?? true { lo = s }
                if hi.map({ e > $0 }) ?? true { hi = e }
            }
        }
        guard let lo, let hi, lo <= hi else { return nil }
        return lo...hi
    }

    /// Drop events that ended before `date`.
    public mutating func prune(before date: Date) {
        for (key, list) in services {
            let kept = list.filter { $0.value.end.map { $0 >= date } ?? false }
            services[key] = kept.isEmpty ? nil : kept
        }
        pendingExtended.removeAll()
    }
}

extension EPGStore: Codable {
    private struct Service: Codable {
        var key: EPGServiceKey
        var events: [EventInfo]
    }

    private enum CodingKeys: String, CodingKey { case decoderRevision, services }

    /// Thrown when the data was decoded by an older `ARIBString.decoderRevision` (or is in the
    /// original bare-array format): its text can't be re-decoded, so it should be fetched again.
    public struct StaleData: Error {}

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              try c.decode(Int.self, forKey: .decoderRevision) == ARIBString.decoderRevision else { throw StaleData() }
        for s in try c.decode([Service].self, forKey: .services) {
            services[s.key] = Dictionary(s.events.map { ($0.eventID, $0) }, uniquingKeysWith: { _, b in b })
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let list = services.map { Service(key: $0.key, events: $0.value.values.sorted { $0.eventID < $1.eventID }) }
            .sorted { ($0.key.originalNetworkID, $0.key.transportStreamID, $0.key.serviceID) < ($1.key.originalNetworkID, $1.key.transportStreamID, $1.key.serviceID) }
        try c.encode(ARIBString.decoderRevision, forKey: .decoderRevision)
        try c.encode(list, forKey: .services)
    }
}

// MARK: - Schedule completeness

/// Tracks which EIT schedule sections have been received, to tell when a service's basic
/// schedule (tables 0x50–0x57 actual / 0x60–0x67 other) is complete.
///
/// Each table holds 32 segments of 8 sections (3 hours each); a segment uses sections
/// `segment × 8 … segment_last_section_number`. Past segments are sent as empty sections, so
/// every segment up to `last_section_number` is expected.
public struct EITScheduleProgress: Sendable {
    struct Table: Sendable {
        var version: UInt8
        var lastSection: UInt8
        var segmentLast: [UInt8: UInt8] = [:]
        var received: Set<UInt8> = []

        var isComplete: Bool {
            for seg in 0...(Int(lastSection) / 8) {
                guard let last = segmentLast[UInt8(seg)] else { return false }
                let first = seg * 8
                for n in first...max(first, Int(last)) where !received.contains(UInt8(n)) { return false }
            }
            return true
        }
    }

    struct Group: Sendable {
        var lastTableID: UInt8
        var tables: [UInt8: Table] = [:]

        func isComplete(base: UInt8) -> Bool {
            guard lastTableID >= base else { return false }
            for t in base...lastTableID {
                guard let table = tables[t], table.isComplete else { return false }
            }
            return true
        }
    }

    /// service → group base (0x50 / 0x60) → state
    private var groups: [EPGServiceKey: [UInt8: Group]] = [:]

    public init() {}

    /// Record a basic schedule section. Returns true if it had not been seen before.
    @discardableResult
    public mutating func record(_ eit: EIT) -> Bool {
        guard eit.isBasicSchedule else { return false }
        let key = EPGServiceKey(originalNetworkID: eit.originalNetworkID, transportStreamID: eit.transportStreamID, serviceID: eit.serviceID)
        let base = eit.tableID & 0xF0
        var group = groups[key]?[base] ?? Group(lastTableID: eit.tableID)
        group.lastTableID = min(max(eit.lastTableID, eit.tableID), base + 7)
        var table = group.tables[eit.tableID] ?? Table(version: eit.version, lastSection: eit.lastSectionNumber)
        if table.version != eit.version || table.lastSection != eit.lastSectionNumber {
            table = Table(version: eit.version, lastSection: eit.lastSectionNumber)
        }
        table.segmentLast[eit.sectionNumber / 8] = eit.segmentLastSectionNumber
        let new = table.received.insert(eit.sectionNumber).inserted
        group.tables[eit.tableID] = table
        groups[key, default: [:]][base] = group
        return new
    }

    /// Whether the actual or the other schedule of the service is complete.
    public func isComplete(_ key: EPGServiceKey) -> Bool {
        guard let g = groups[key] else { return false }
        return g.contains { $0.value.isComplete(base: $0.key) }
    }

    /// `originalNetworkID` nil matches any network.
    public func isComplete(originalNetworkID: UInt16?, transportStreamID: UInt16, serviceID: UInt16) -> Bool {
        if let onid = originalNetworkID {
            return isComplete(EPGServiceKey(originalNetworkID: onid, transportStreamID: transportStreamID, serviceID: serviceID))
        }
        return groups.keys.contains { $0.transportStreamID == transportStreamID && $0.serviceID == serviceID && isComplete($0) }
    }
}

// MARK: - Collector

/// Collects EIT (p/f and schedule) and TOT from a TS. Thread-safe: `feed` may be called from
/// the driver's receive thread; parsing runs on a private serial queue.
public final class EPGCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bonview.epg", qos: .utility)
    private var splitter = TSPacketSplitter()
    private var sections: [UInt16: SectionAssembler] = [:]
    private var seen: [SectionID: UInt32] = [:]
    private var updates = EPGStore()
    private var progress = EITScheduleProgress()
    private var _actualTSID: UInt16?
    private var _time: Date?
    private var _lastNewSchedule: Date?

    private struct SectionID: Hashable {
        var tableID: UInt8, serviceID: UInt16, tsid: UInt16, onid: UInt16, section: UInt8
    }

    private static let pids: Set<UInt16> = [0x0012, 0x0026, 0x0027, 0x0014]

    public init() {}

    public func feed(_ data: Data) {
        queue.async { self.process(data) }
    }

    /// Events received since the last call.
    public func takeUpdates() -> EPGStore {
        queue.sync {
            let u = updates
            updates = EPGStore()
            return u
        }
    }

    /// Forget the packet/section state (after a channel change). Schedule progress is kept.
    public func resetStream() {
        queue.sync {
            splitter.reset()
            sections.removeAll()
            _actualTSID = nil
            _lastNewSchedule = nil
        }
    }

    /// Wait until everything fed so far has been processed.
    public func flush() { queue.sync {} }

    /// TSID of the stream, from EIT p/f actual.
    public var actualTransportStreamID: UInt16? { queue.sync { _actualTSID } }
    public var broadcastTime: Date? { queue.sync { _time } }
    /// When a basic schedule section not seen before last arrived (since `resetStream`).
    public var lastNewScheduleSection: Date? { queue.sync { _lastNewSchedule } }

    public func isComplete(originalNetworkID: UInt16?, transportStreamID: UInt16, serviceID: UInt16) -> Bool {
        queue.sync { progress.isComplete(originalNetworkID: originalNetworkID, transportStreamID: transportStreamID, serviceID: serviceID) }
    }

    private func process(_ data: Data) {
        splitter.split(data) { p in
            guard !p.transportError, p.scramblingControl == 0, Self.pids.contains(p.pid), let payload = p.payload else { return }
            var asm = sections[p.pid] ?? SectionAssembler()
            asm.push(payload, unitStart: p.payloadUnitStart) { section($0) }
            sections[p.pid] = asm
        }
    }

    private func section(_ s: [UInt8]) {
        switch s[0] {
        case 0x70, 0x73:
            if let t = TOT.time(s) { _time = t }
        case 0x4E...0x6F:
            guard s.count >= 18 else { return }
            let crc = UInt32(s[s.count - 4]) << 24 | UInt32(s[s.count - 3]) << 16 | UInt32(s[s.count - 2]) << 8 | UInt32(s[s.count - 1])
            let id = SectionID(tableID: s[0], serviceID: s.u16(3), tsid: s.u16(8), onid: s.u16(10), section: s[6])
            if s[0] == 0x4E { _actualTSID = id.tsid }
            if seen[id] == crc { return }
            seen[id] = crc
            guard let eit = EIT(s) else { return }
            updates.apply(eit)
            if progress.record(eit) { _lastNewSchedule = Date() }
        default:
            break
        }
    }
}
