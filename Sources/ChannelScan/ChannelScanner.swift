import BonDriver
import Foundation
import TSCore

/// A service found by a channel scan.
public struct ScannedService: Codable, Hashable, Sendable, Identifiable {
    public var serviceID: UInt16
    public var name: String
    public var serviceType: UInt8
    public var isOneSeg: Bool

    public var id: UInt16 { serviceID }
    public var displayName: String { name.isEmpty ? "サービス \(serviceID)" : name }

    /// Digital TV (0x01), temporary/promotional video (0xA5, 0xAD) and radio (0x02), excluding one-seg.
    /// Data broadcasting (0xC0) and engineering services are hidden from the channel list.
    public var isViewable: Bool {
        !isOneSeg && [0x01, 0x02, 0xA5, 0xAD].contains(serviceType)
    }

    public init(serviceID: UInt16, name: String, serviceType: UInt8, isOneSeg: Bool) {
        self.serviceID = serviceID
        self.name = name
        self.serviceType = serviceType
        self.isOneSeg = isOneSeg
    }
}

/// A physical BonDriver channel on which a broadcast was found.
public struct ScannedChannel: Codable, Hashable, Sendable, Identifiable {
    public var space: UInt32
    public var channel: UInt32
    /// BonDriver's channel name (e.g. "21Ch").
    public var channelName: String
    public var spaceName: String
    public var transportStreamID: UInt16
    public var originalNetworkID: UInt16?
    /// ISDB-T remote-control key (1–12) from the NIT; nil if not received (or scanned by an older version).
    public var remoteControlKeyID: UInt8?
    public var services: [ScannedService]

    public var id: String { "\(space)-\(channel)" }

    public init(space: UInt32, channel: UInt32, channelName: String, spaceName: String,
                transportStreamID: UInt16, originalNetworkID: UInt16?, remoteControlKeyID: UInt8? = nil,
                services: [ScannedService]) {
        self.space = space
        self.channel = channel
        self.channelName = channelName
        self.spaceName = spaceName
        self.transportStreamID = transportStreamID
        self.originalNetworkID = originalNetworkID
        self.remoteControlKeyID = remoteControlKeyID
        self.services = services
    }

    /// The 3-digit channel number shown by TVs (e.g. 081, 082 for remote key 8).
    /// Terrestrial: key × 10 + service number (low 3 bits of the service ID) + 1.
    /// BS / CS (original network 4, 6, 7): the service ID itself.
    public func threeDigitNumber(for service: ScannedService) -> Int? {
        if let key = remoteControlKeyID, key > 0 {
            return Int(key) * 10 + Int(service.serviceID & 0x07) + 1
        }
        if let onid = originalNetworkID, [4, 6, 7].contains(onid) {
            return Int(service.serviceID)
        }
        return nil
    }

    /// Viewable services whose name repeats that of a lower-numbered service on the same channel —
    /// multi-programming sub-channels (082, 083…) that usually carry nothing of their own.
    public var duplicateNameServiceIDs: Set<UInt16> {
        var seen = Set<String>()
        var dups = Set<UInt16>()
        for svc in services.filter(\.isViewable).sorted(by: { $0.serviceID < $1.serviceID }) {
            let key = svc.name.trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            if !seen.insert(key).inserted { dups.insert(svc.serviceID) }
        }
        return dups
    }
}

/// Channel scan: tune each BonDriver channel, read PAT/PMT/SDT and keep the
/// channels that carry a broadcast.
///
/// `scan` blocks; run it off the main thread. Route the driver's TS into `feed(_:)` while it runs
/// (the scanner does not touch `tsHandler`, which the driver reads from its own thread).
public final class ChannelScanner: @unchecked Sendable {
    public struct Options: Sendable {
        /// Give up on a channel that delivered no PAT after this long and has no signal.
        public var noSignalTimeout: Double = 1.5
        /// Maximum time spent on one channel.
        public var timeout: Double = 12
        /// Once PAT/SDT are complete, keep waiting this long (from tuning) for the NIT, which some
        /// broadcasters repeat only every few seconds. It carries the remote-control key.
        public var nitTimeout: Double = 10
        /// Signal level (dB) below which a channel without PAT is considered empty.
        public var minSignal: Float = 1

        public init() {}
    }

    public enum Event: Sendable {
        case started(TuningSpace.Channel, index: Int, total: Int)
        case found(ScannedChannel)
        case empty(TuningSpace.Channel)
    }

    public let options: Options
    private let cancelLock = NSLock()
    private var _cancelled = false
    private let demuxLock = NSLock()
    private var demux = TSDemuxer()

    public init(options: Options = Options()) {
        self.options = options
    }

    public func cancel() {
        cancelLock.lock(); _cancelled = true; cancelLock.unlock()
    }

    /// TS input (any thread).
    public func feed(_ data: Data) {
        demuxLock.lock(); demux.feed(data); demuxLock.unlock()
    }

    public var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _cancelled
    }

    /// Scan `spaces` (all channels in each). Returns the channels on which a TS was found, in order.
    public func scan(_ driver: BonDriver, spaces: [TuningSpace], onEvent: ((Event) -> Void)? = nil) -> [ScannedChannel] {
        let channels = spaces.flatMap { s in s.channels.map { (s.name, $0) } }
        var found: [ScannedChannel] = []
        for (i, (spaceName, ch)) in channels.enumerated() {
            if isCancelled { break }
            onEvent?(.started(ch, index: i, total: channels.count))
            guard (try? driver.setChannel(space: ch.space, channel: ch.index)) == .tuned else {
                onEvent?(.empty(ch))
                continue
            }
            // Data queued before SetChannel returned may belong to the previous channel.
            demuxLock.lock(); demux = TSDemuxer(); demuxLock.unlock()

            let start = Date()
            var result: ScannedChannel?
            while !isCancelled {
                usleep(50_000)
                let elapsed = Date().timeIntervalSince(start)
                demuxLock.lock()
                let tsid = demux.transportStreamID
                let onid = demux.originalNetworkID
                let services = demux.services
                let key = demux.remoteControlKeyID
                let hasNIT = demux.hasNIT
                demuxLock.unlock()

                if let tsid {
                    let named = !services.isEmpty && services.allSatisfy { !$0.name.isEmpty }
                    let scanned = ScannedChannel(
                        space: ch.space, channel: ch.index, channelName: ch.name, spaceName: spaceName,
                        transportStreamID: tsid, originalNetworkID: onid, remoteControlKeyID: key,
                        services: services.map {
                            ScannedService(serviceID: $0.serviceID, name: $0.name, serviceType: $0.serviceType, isOneSeg: $0.isOneSeg)
                        }.sorted { $0.serviceID < $1.serviceID })
                    result = scanned
                    if onid != nil && named && (hasNIT || elapsed >= options.nitTimeout) { break }
                } else if elapsed >= options.noSignalTimeout && driver.signalLevel < options.minSignal {
                    break
                }
                if elapsed >= options.timeout { break }
            }
            if isCancelled { break }
            if let result {
                found.append(result)
                onEvent?(.found(result))
            } else {
                onEvent?(.empty(ch))
            }
        }
        return found
    }
}
