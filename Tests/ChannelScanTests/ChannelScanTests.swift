import BonDriver
@testable import ChannelScan
import Foundation
import Testing
import TSCore

/// In-memory BonDriver: channels with a TS file deliver it (looped), others deliver nothing.
final class FakeDriver: BonDriver, @unchecked Sendable {
    var tsHandler: ((Data) -> Void)?
    var errorHandler: ((BonDriverError) -> Void)?
    let streams: [UInt32: Data]
    private let lock = NSLock()
    private var generation = 0
    private var current: UInt32?
    private(set) var tuned: [UInt32] = []

    init(streams: [UInt32: Data]) { self.streams = streams }

    func openTuner() throws {}
    func closeTuner() {}
    var signalLevel: Float { lock.lock(); defer { lock.unlock() }; return current.flatMap { streams[$0] } != nil ? 30 : 0 }
    func purgeTsStream() {}
    func release() { lock.lock(); generation += 1; lock.unlock() }
    var tunerName: String { "Fake" }
    func enumTuningSpace(_ space: UInt32) -> String? { space == 0 ? "UHF" : nil }
    func enumChannelName(space: UInt32, channel: UInt32) -> String? { space == 0 && channel < 4 ? "\(channel + 13)Ch" : nil }
    var currentSpace: UInt32? { 0 }
    var currentChannel: UInt32? { lock.lock(); defer { lock.unlock() }; return current }
    var totalDeviceNum: UInt32 { 1 }
    var activeDeviceNum: UInt32 { 1 }
    func setLnbPower(_ enable: Bool) -> Bool { false }

    func setChannel(space: UInt32, channel: UInt32) throws -> SetChannelResult {
        lock.lock()
        generation += 1
        let gen = generation
        current = channel
        tuned.append(channel)
        lock.unlock()
        guard let data = streams[channel] else { return .tuned }
        Thread.detachNewThread { [weak self] in
            while let self {
                self.lock.lock(); let live = self.generation == gen; self.lock.unlock()
                guard live else { return }
                var i = 0
                while i < data.count {
                    let n = min(188 * 256, data.count - i)
                    self.tsHandler?(data.subdata(in: i..<(i + n)))
                    i += n
                }
                usleep(100_000)
            }
        }
        return .tuned
    }
}

@Suite struct ChannelScanTests {
    /// `FFMPEG_CLI` overrides the Homebrew locations (the CLI only generates test streams).
    static let ffmpeg = [ProcessInfo.processInfo.environment["FFMPEG_CLI"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }

    static func makeTS(tsid: Int, sid: Int, name: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bonview-scan-\(tsid).ts")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg!)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                       "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "1",
                       "-c:v", "mpeg2video", "-metadata", "service_name=\(name)",
                       "-mpegts_service_id", "\(sid)", "-mpegts_transport_stream_id", "\(tsid)",
                       "-mpegts_original_network_id", "\(tsid)", "-f", "mpegts", url.path]
        try p.run()
        p.waitUntilExit()
        return try Data(contentsOf: url)
    }

    @Test(.enabled(if: ffmpeg != nil)) func findsBroadcastChannels() throws {
        let driver = FakeDriver(streams: [
            1: try Self.makeTS(tsid: 0x7FE1, sid: 1024, name: "A"),
            3: try Self.makeTS(tsid: 0x7FE3, sid: 1056, name: "B"),
        ])
        var opts = ChannelScanner.Options()
        opts.noSignalTimeout = 0.2
        opts.timeout = 1.5
        let scanner = ChannelScanner(options: opts)
        driver.tsHandler = { scanner.feed($0) }
        var events: [String] = []
        let result = scanner.scan(driver, spaces: driver.enumerateChannels()) { ev in
            switch ev {
            case .started(let ch, _, _): events.append("start \(ch.index)")
            case .found(let c): events.append("found \(c.channel)")
            case .empty(let ch): events.append("empty \(ch.index)")
            }
        }
        driver.release()
        #expect(result.map(\.channel) == [1, 3])
        #expect(result.map(\.transportStreamID) == [0x7FE1, 0x7FE3])
        #expect(result.map { $0.services.map(\.serviceID) } == [[1024], [1056]])
        #expect(result[0].channelName == "14Ch" && result[0].spaceName == "UHF")
        #expect(result[0].originalNetworkID == 0x7FE1)
        #expect(result[0].services[0].serviceType == 0x01)
        #expect(result[0].services[0].isViewable)
        // (ffmpeg writes DVB, not ARIB, service names, so the name itself isn't checked here.)
        #expect(events.contains("empty 0") && events.contains("empty 2"))
    }

    @Test func cancelStopsEarly() {
        let driver = FakeDriver(streams: [:])
        let scanner = ChannelScanner()
        scanner.cancel()
        #expect(scanner.scan(driver, spaces: driver.enumerateChannels()).isEmpty)
        #expect(driver.tuned.isEmpty)
    }

    @Test func threeDigitNumbers() {
        func svc(_ id: UInt16, _ name: String, type: UInt8 = 0x01) -> ScannedService {
            ScannedService(serviceID: id, name: name, serviceType: type, isOneSeg: false)
        }
        // Terrestrial, remote key 8: 1056 → 081, 1057 → 082, 1058 → 083.
        let cx = ScannedChannel(space: 0, channel: 8, channelName: "21Ch", spaceName: "UHF", transportStreamID: 0x7FE8,
                                originalNetworkID: 0x7FE8, remoteControlKeyID: 8,
                                services: [svc(1056, "フジテレビ"), svc(1057, "フジテレビ"), svc(1058, "フジテレビ")])
        #expect(cx.services.map { cx.threeDigitNumber(for: $0) } == [81, 82, 83])
        #expect(cx.duplicateNameServiceIDs == [1057, 1058])

        // MX: 091 MX1, 092 MX2, 093 MX1 (sub) → only the second MX1 is a duplicate.
        let mx = ScannedChannel(space: 0, channel: 3, channelName: "16Ch", spaceName: "UHF", transportStreamID: 0x7FF0,
                                originalNetworkID: 0x7FF0, remoteControlKeyID: 9,
                                services: [svc(23610, "TOKYO MX1"), svc(23608, "TOKYO MX1"), svc(23609, "TOKYO MX2"),
                                           svc(23612, "データ", type: 0xC0)])
        #expect(mx.threeDigitNumber(for: mx.services[1]) == 91)
        #expect(mx.duplicateNameServiceIDs == [23610])

        // BS: the service ID is the number. Unknown key on terrestrial (old scan data): none.
        let bs = ScannedChannel(space: 1, channel: 0, channelName: "BS01/TS0", spaceName: "BS", transportStreamID: 0x4010,
                                originalNetworkID: 4, services: [svc(101, "NHK BS")])
        #expect(bs.threeDigitNumber(for: bs.services[0]) == 101)
        let old = ScannedChannel(space: 0, channel: 8, channelName: "21Ch", spaceName: "UHF", transportStreamID: 0x7FE8,
                                 originalNetworkID: 0x7FE8, services: [svc(1056, "フジテレビ")])
        #expect(old.threeDigitNumber(for: old.services[0]) == nil)
    }

    @Test func decodesScanDataWithoutRemoteKey() throws {
        let json = #"{"space":0,"channel":1,"channelName":"14Ch","spaceName":"UHF","transportStreamID":1,"services":[]}"#
        let ch = try JSONDecoder().decode(ScannedChannel.self, from: Data(json.utf8))
        #expect(ch.remoteControlKeyID == nil && ch.originalNetworkID == nil)
    }

    @Test func viewableFilter() {
        #expect(ScannedService(serviceID: 1, name: "", serviceType: 0x01, isOneSeg: false).isViewable)
        #expect(!ScannedService(serviceID: 1, name: "", serviceType: 0xC0, isOneSeg: false).isViewable)
        #expect(!ScannedService(serviceID: 1, name: "", serviceType: 0x01, isOneSeg: true).isViewable)
    }
}

@Suite struct EPGGrabberTests {
    /// EIT schedule TS built in-process (no ffmpeg): one complete one-table schedule per service.
    static func scheduleTS(tsid: UInt16, sids: [UInt16]) -> Data {
        var cc: UInt8 = 0
        var out: [UInt8] = []
        let base = Date(timeIntervalSince1970: 1_794_000_000)
        for sid in sids {
            for seg in 0..<3 {
                let s = section(sid: sid, tsid: tsid, number: UInt8(seg * 8), start: base.addingTimeInterval(Double(seg) * 10800), id: UInt16(seg + 1))
                var data = [0] + s
                var first = true
                while !data.isEmpty {
                    let chunk = Array(data.prefix(184)); data.removeFirst(chunk.count)
                    out += [0x47, (first ? 0x40 : 0), 0x12, 0x10 | cc] + chunk + [UInt8](repeating: 0xFF, count: 184 - chunk.count)
                    cc = (cc + 1) & 0x0F
                    first = false
                }
            }
        }
        return Data(out)
    }

    static func section(sid: UInt16, tsid: UInt16, number: UInt8, start: Date, id: UInt16) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let c = cal.dateComponents([.year, .month, .day, .hour], from: start)
        let day = cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day))!
        let mjd = Int((day.timeIntervalSince(cal.date(from: DateComponents(year: 1858, month: 11, day: 17))!) / 86400).rounded())
        let hour = UInt8((c.hour! / 10) << 4 | (c.hour! % 10))
        let title: [UInt8] = [0x0E] + Array("T\(id)".utf8)
        let sed: [UInt8] = Array("jpn".utf8) + [UInt8(title.count)] + title + [0]
        let desc: [UInt8] = [0x4D, UInt8(sed.count)] + sed
        let ev: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), UInt8(mjd >> 8), UInt8(mjd & 0xFF), hour, 0, 0, 0x03, 0, 0,
                           0x80, UInt8(desc.count)] + desc
        let body: [UInt8] = [UInt8(tsid >> 8), UInt8(tsid & 0xFF), UInt8(tsid >> 8), UInt8(tsid & 0xFF), number, 0x50] + ev
        let len = 5 + body.count + 4
        var s: [UInt8] = [0x50, 0xF0 | UInt8(len >> 8), UInt8(len & 0xFF), UInt8(sid >> 8), UInt8(sid & 0xFF), 0xC1, number, 16] + body
        let crc = CRC32MPEG2.checksum(s)
        s += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return s
    }

    static func channel(_ ch: UInt32, tsid: UInt16, sids: [UInt16]) -> ScannedChannel {
        ScannedChannel(space: 0, channel: ch, channelName: "\(ch + 13)Ch", spaceName: "UHF", transportStreamID: tsid,
                       originalNetworkID: tsid, services: sids.map { ScannedService(serviceID: $0, name: "S\($0)", serviceType: 0x01, isOneSeg: false) })
    }

    @Test func grabsEveryChannel() throws {
        let driver = FakeDriver(streams: [
            1: Self.scheduleTS(tsid: 0x7FE1, sids: [1024, 1025]),
            2: Self.scheduleTS(tsid: 0x7FE2, sids: [1032]),
        ])
        var opts = EPGGrabber.Options()
        opts.noDataTimeout = 0.5
        opts.stallTimeout = 2
        let grabber = EPGGrabber(options: opts)
        driver.tsHandler = { grabber.feed($0) }
        let channels = [Self.channel(1, tsid: 0x7FE1, sids: [1024, 1025]), Self.channel(3, tsid: 0x7FE3, sids: [1040]),
                        Self.channel(2, tsid: 0x7FE2, sids: [1032]),
                        // Same TS again (e.g. listed twice): already complete → skipped without tuning.
                        Self.channel(1, tsid: 0x7FE1, sids: [1024])]
        var store = EPGStore()
        var log: [String] = []
        try grabber.grab(driver, channels: channels) { ev in
            switch ev {
            case .started(let c, _, _): log.append("start \(c.channel)")
            case .skipped(let c): log.append("skip \(c.channel)")
            case .locked(let c): log.append("locked \(c.channel)")
            case .finished(let c, let complete): log.append("done \(c.channel) \(complete)")
            case .updates(let u): store.merge(u)
            }
        }
        driver.release()
        #expect(log == ["start 1", "done 1 true", "start 3", "done 3 false", "start 2", "done 2 true", "skip 1"])
        #expect(driver.tuned == [1, 3, 2])
        #expect(store.eventCount == 9)
        let key = try #require(store.key(originalNetworkID: 0x7FE2, transportStreamID: 0x7FE2, serviceID: 1032))
        #expect(store.events(for: key, from: .distantPast, to: .distantFuture).map(\.title) == ["T1", "T2", "T3"])
    }
}
