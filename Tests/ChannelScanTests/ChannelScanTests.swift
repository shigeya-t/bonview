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
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

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
