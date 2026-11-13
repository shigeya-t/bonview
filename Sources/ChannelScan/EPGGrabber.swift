import BonDriver
import Foundation
import TSCore

/// Programme guide acquisition: tunes each scanned channel in turn and collects its EIT
/// schedule until every viewable service on it is complete (or the channel stops delivering
/// new sections). Meant to run on a second BonDriver connection so viewing is not interrupted.
///
/// `grab` blocks; run it off the main thread. Route the driver's TS into `feed(_:)`.
public final class EPGGrabber: @unchecked Sendable {
    public struct Options: Sendable {
        /// Maximum time spent on one channel.
        public var channelTimeout: Double = 180
        /// Move on when no new schedule section arrived for this long.
        public var stallTimeout: Double = 20
        /// Move on when no schedule section arrived at all after tuning (no signal / no EIT).
        public var noDataTimeout: Double = 12
        /// How often collected events are handed out while a channel is being read.
        public var updateInterval: Double = 3

        public init() {}
    }

    public enum Event: Sendable {
        case started(ScannedChannel, index: Int, total: Int)
        /// Every service of the channel already had a complete schedule (BS / CS carry the whole
        /// network's schedule on each transponder).
        case skipped(ScannedChannel)
        /// The server kept the tuner on another channel (shared tuner with a higher channel lock).
        case locked(ScannedChannel)
        case finished(ScannedChannel, complete: Bool)
        /// Events collected since the previous update.
        case updates(EPGStore)
    }

    public let options: Options
    public let collector = EPGCollector()
    private let cancelLock = NSLock()
    private var _cancelled = false

    public init(options: Options = Options()) {
        self.options = options
    }

    public func cancel() {
        cancelLock.lock(); _cancelled = true; cancelLock.unlock()
    }

    public var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _cancelled
    }

    /// TS input (any thread).
    public func feed(_ data: Data) { collector.feed(data) }

    private func isComplete(_ ch: ScannedChannel) -> Bool {
        let services = ch.services.filter(\.isViewable)
        return !services.isEmpty && services.allSatisfy {
            collector.isComplete(originalNetworkID: ch.originalNetworkID, transportStreamID: ch.transportStreamID, serviceID: $0.serviceID)
        }
    }

    /// Visit `channels` in order. Throws only when the driver fails (e.g. disconnected).
    public func grab(_ driver: BonDriver, channels: [ScannedChannel], onEvent: (Event) -> Void) throws {
        for (i, ch) in channels.enumerated() {
            if isCancelled { return }
            if ch.services.filter(\.isViewable).isEmpty || isComplete(ch) {
                onEvent(.skipped(ch))
                continue
            }
            onEvent(.started(ch, index: i, total: channels.count))
            if try driver.setChannel(space: ch.space, channel: ch.channel) == .locked {
                onEvent(.locked(ch))
                continue
            }
            // Data queued before SetChannel returned may belong to the previous channel.
            collector.resetStream()
            let start = Date()
            var lastUpdate = start
            while !isCancelled {
                usleep(200_000)
                let now = Date()
                if isComplete(ch) { break }
                if let last = collector.lastNewScheduleSection {
                    if now.timeIntervalSince(last) >= options.stallTimeout { break }
                } else if now.timeIntervalSince(start) >= options.noDataTimeout {
                    break
                }
                if now.timeIntervalSince(start) >= options.channelTimeout { break }
                if now.timeIntervalSince(lastUpdate) >= options.updateInterval {
                    lastUpdate = now
                    let u = collector.takeUpdates()
                    if !u.isEmpty { onEvent(.updates(u)) }
                }
            }
            collector.flush()
            let u = collector.takeUpdates()
            if !u.isEmpty { onEvent(.updates(u)) }
            if isCancelled { return }
            onEvent(.finished(ch, complete: isComplete(ch)))
        }
    }
}
