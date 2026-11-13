import Foundation

/// Present / following events per service, collected from EIT p/f (actual and other) while
/// watching. Answers "what is on now" for services other than the selected one, e.g. for the
/// channel list. Terrestrial TSs only carry their own services' EIT, so other channels are known
/// once they have been tuned; BS / CS carry EIT p/f other for the whole network.
public struct ProgramCache: Sendable {
    public struct ServiceKey: Hashable, Sendable {
        public var originalNetworkID: UInt16
        public var transportStreamID: UInt16
        public var serviceID: UInt16

        public init(originalNetworkID: UInt16, transportStreamID: UInt16, serviceID: UInt16) {
            self.originalNetworkID = originalNetworkID
            self.transportStreamID = transportStreamID
            self.serviceID = serviceID
        }
    }

    private struct Entry: Sendable {
        var present: EventInfo?
        var following: EventInfo?
    }

    private var entries: [ServiceKey: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func update(_ u: ServiceEventUpdate) {
        let key = ServiceKey(originalNetworkID: u.originalNetworkID, transportStreamID: u.transportStreamID, serviceID: u.serviceID)
        var e = entries[key] ?? Entry()
        if u.isFollowing { e.following = u.event } else { e.present = u.event }
        entries[key] = e
    }

    /// The event on air at `now`: the present event until it ends, then the following one.
    /// `originalNetworkID` nil matches any network (channels scanned without an SDT).
    public func currentEvent(originalNetworkID: UInt16?, transportStreamID: UInt16, serviceID: UInt16, at now: Date) -> EventInfo? {
        let entry: Entry?
        if let onid = originalNetworkID {
            entry = entries[ServiceKey(originalNetworkID: onid, transportStreamID: transportStreamID, serviceID: serviceID)]
        } else {
            entry = entries.first { $0.key.transportStreamID == transportStreamID && $0.key.serviceID == serviceID }?.value
        }
        guard let entry else { return nil }
        if let p = entry.present, p.end.map({ now < $0 }) ?? true { return p }
        if let f = entry.following, f.start.map({ now >= $0 }) ?? true, f.end.map({ now < $0 }) ?? true { return f }
        return nil
    }
}
