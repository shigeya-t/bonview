import Foundation
import Testing
@testable import BonDriver

@Suite struct ProxyProtocolTests {
    @Test func headerEncoding() {
        let d = ProxyPacket.dwords(.setChannel2, 1, 0x0203, trailingByte: 0xFE).encoded()
        #expect(Array(d) == [0xFF, 15, 0, 0, 0, 0, 0, 9, 0, 0, 0, 1, 0, 0, 0x02, 0x03, 0xFE])
    }

    @Test func b25OptionByte() throws {
        var p = ProxyPacket.dwords(.setChannel2, 0, 0, trailingByte: 0)
        p.option = ProxyPacket.optionDesireToUseB25
        #expect(Array(p.encoded().prefix(4)) == [0xFF, 15, 0x01, 0])
        #expect(try ProxyConfig.parse("ADDRESS=a\nPORT=1\nBONDRIVER=b\nB25=0").requestB25 == false)
        #expect(try ProxyConfig.parse("ADDRESS=a\nPORT=1\nBONDRIVER=b").requestB25 == true)
        // Profiles saved before this option existed still decode.
        let old = #"{"address":"x","port":1192,"bonDriver":"PT-T","channelLock":0,"connectTimeout":5,"useMagicPacket":false,"tsPacketBufSize":192512}"#
        let cfg = try JSONDecoder().decode(ProxyConfig.self, from: Data(old.utf8))
        #expect(cfg.requestB25 && cfg.bonDriver == "PT-T")
    }

    @Test func wideStrings() {
        #expect(ProxyPacket.wideString(.enumChannelName, "地上D").wideStringValue == "地上D")
        #expect(ProxyPacket.wideString(.enumChannelName, nil).wideStringValue == nil)
    }

    @Test func tsPayloadRejectsSizeMismatch() {
        var p = ProxyPacket.tsStream(signal: 12.5, data: Data([1, 2, 3]))
        #expect(p.tsPayload?.signal == 12.5)
        #expect(p.tsPayload?.data == Data([1, 2, 3]))
        p.body.append(0)
        #expect(p.tsPayload == nil)
    }

    @Test func parseLinuxConf() throws {
        let cfg = try ProxyConfig.parse("""
        ;OPTION
        ADDRESS=192.168.0.100
        PORT=1192
        BONDRIVER=/home/u/BonDriver_LinuxPT-S0.so
        CHANNEL_LOCK=1
        CONNECT_TIMEOUT=30
        USE_MAGICPACKET=1

        ;MAGICPACKET
        TARGET_MACADDRESS=AA-BB-CC-DD-EE-FF
        """)
        #expect(cfg.address == "192.168.0.100")
        #expect(cfg.port == 1192)
        #expect(cfg.bonDriver == "/home/u/BonDriver_LinuxPT-S0.so")
        #expect(cfg.channelLock == 1)
        #expect(cfg.connectTimeout == 30)
        #expect(cfg.useMagicPacket)
        #expect(cfg.macAddress == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    @Test func parseWindowsIni() throws {
        let cfg = try ProxyConfig.parse("[OPTION]\r\nADDRESS = \"tuner.local\"\r\nPORT=1193\r\nBONDRIVER=BonDriver_PT3-T.dll\r\n")
        #expect(cfg.address == "tuner.local")
        #expect(cfg.port == 1193)
        #expect(cfg.bonDriver == "BonDriver_PT3-T.dll")
    }
}

@Suite(.serialized) struct ProxyClientTests {
    @Test func fullSession() throws {
        let server = try MockProxyServer()
        server.start()
        defer { server.stop() }

        let client = try ProxyClient.connect(config: ProxyConfig(address: "127.0.0.1", port: server.port,
                                                                 bonDriver: "BonDriver_Mock.dll", channelLock: 3))
        let received = Received()
        client.tsHandler = { received.add($0) }
        try client.openTuner()

        let spaces = client.enumerateChannels()
        #expect(spaces.map(\.name) == ["UHF", "BS"])
        #expect(spaces[0].channels.map(\.name) == ["NHK総合", "Eテレ"])

        #expect(try client.setChannel(space: 0, channel: 1) == .tuned)
        #expect(client.currentSpace == 0)
        #expect(client.currentChannel == 1)
        #expect(client.totalDeviceNum == 2)

        let deadline = Date().addingTimeInterval(2)
        while received.count < 188 * 4 * 5 && Date() < deadline { usleep(10_000) }
        #expect(received.count == 188 * 4 * 5)
        #expect(client.signalLevel == 24.5)

        // The channel-lock byte must be sent with SetChannel2.
        let set = server.received.first { $0.proxyCommand == .setChannel2 }
        #expect(set?.body.last == 3)
        // HaijinW BonDriverProxyEx B25 request bit (reserved header byte), on by default.
        #expect(set?.option == ProxyPacket.optionDesireToUseB25)
        #expect(server.received.first { $0.proxyCommand == .openTuner }?.option == 0)

        client.release()
    }

    @Test func rejectsUnknownBonDriver() throws {
        let server = try MockProxyServer()
        server.start()
        defer { server.stop() }
        #expect(throws: BonDriverError.self) {
            _ = try ProxyClient.connect(config: ProxyConfig(address: "127.0.0.1", port: server.port, bonDriver: "nope.dll"))
        }
    }

    @Test func channelLocked() throws {
        let server = try MockProxyServer()
        server.lockedChannel = true
        server.start()
        defer { server.stop() }
        let client = try ProxyClient.connect(config: ProxyConfig(address: "127.0.0.1", port: server.port, bonDriver: "BonDriver_Mock.dll"))
        try client.openTuner()
        #expect(try client.setChannel(space: 0, channel: 0) == .locked)
        client.release()
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ d: Data) { lock.lock(); total += d.count; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return total }
}
