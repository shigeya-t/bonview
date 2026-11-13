import Foundation
import Testing
@testable import BonDriver

@Suite struct TunnelConfigTests {
    @Test func originFromFileName() throws {
        let cfg = try TunnelConfig.parse("[OPTION]\r\nADDRESS=192.168.0.20\r\n", fileName: "BonDriver_PT3-T.ini")
        #expect(cfg.address == "192.168.0.20")
        #expect(cfg.port == 1193)
        #expect(cfg.origin == "PT3-T")
        #expect(cfg.sendRecvTimeout == 5)
    }

    @Test func explicitOrigin() throws {
        let cfg = try TunnelConfig.parse("ADDRESS=host\nPORT=2000\nORIGIN=Proxy0_PT3-S\nSEND_RECV_TIMEOUT=10\n", fileName: "BonDriver_X.ini")
        #expect(cfg.port == 2000)
        #expect(cfg.origin == "Proxy0_PT3-S")
        #expect(cfg.sendRecvTimeout == 10)
    }

    @Test func normalize() {
        #expect(TunnelConfig.normalizeOrigin("BonDriver_PT3-T.dll") == "PT3-T")
        #expect(TunnelConfig.normalizeOrigin("PT3-T") == "PT3-T")
    }

    @Test func detectKind() {
        #expect(TunnelConfig.looksLikeTunnelConfig("[OPTION]\nADDRESS=1.2.3.4\n"))
        #expect(!TunnelConfig.looksLikeTunnelConfig("ADDRESS=1.2.3.4\nBONDRIVER=BonDriver_PT3-T.dll\n"))
    }
}

@Suite(.serialized) struct TunnelClientTests {
    @Test func fullSession() throws {
        let server = try MockTunnelServer()
        server.start()
        defer { server.stop() }

        let client = try TunnelClient.connect(config: TunnelConfig(address: "127.0.0.1", port: server.port, origin: "BonDriver_Mock-T.dll"))
        #expect(client.interfaceVersion == 3)
        let received = Received()
        client.tsHandler = { received.add($0) }
        try client.openTuner()
        #expect(client.tunerName == "Mock Tuner")

        let spaces = client.enumerateChannels()
        #expect(spaces.map(\.name) == ["地デジ"])
        #expect(spaces[0].channels.map(\.name) == ["NHK総合", "Eテレ"])
        #expect(try client.setChannel(space: 0, channel: 1) == .tuned)
        #expect(client.totalDeviceNum == 2)

        let deadline = Date().addingTimeInterval(3)
        while received.count < 188 * 100 * 5 && Date() < deadline { usleep(10_000) }
        #expect(received.count == 188 * 100 * 5)
        while client.signalLevel == 0 && Date() < deadline { usleep(10_000) }
        #expect(client.signalLevel == 31.5)

        client.release()
        #expect(server.handshakes == ["Crea:Mock-T"])
        #expect(server.commands.last == "Rele")
    }

    @Test func reconnectsAndRepeatsCommand() throws {
        let server = try MockTunnelServer()
        server.dropAfterCommands = 2 // drop while answering the 2nd command (ETun)
        server.start()
        defer { server.stop() }

        let client = try TunnelClient.connect(config: TunnelConfig(address: "127.0.0.1", port: server.port, origin: "Mock-T"))
        try client.openTuner() // Open, GTun
        #expect(client.enumTuningSpace(0) == "地デジ")
        #expect(server.handshakes == ["Crea:Mock-T", "Conn:Mock-T"])
        client.release()
    }

    @Test func rejectsUnknownOrigin() throws {
        let server = try MockTunnelServer()
        server.start()
        defer { server.stop() }
        #expect(throws: BonDriverError.self) {
            _ = try TunnelClient.connect(config: TunnelConfig(address: "127.0.0.1", port: server.port, origin: "Nope"))
        }
    }
}
