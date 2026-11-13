import Darwin
import Foundation
@testable import BonDriver

/// In-process BonDriverProxy server speaking the same protocol as BonDriverProxy.cpp.
final class MockProxyServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private var thread: Thread?

    var spaces: [(String, [String])] = [("UHF", ["NHK総合", "Eテレ"]), ("BS", ["BS朝日"])]
    var acceptedDriver = "BonDriver_Mock.dll"
    var lockedChannel = false
    var tsChunk = Data(repeating: 0x47, count: 188 * 4)
    var signal: Float = 24.5

    private let lock = NSLock()
    private var _received: [ProxyPacket] = []
    var received: [ProxyPacket] { lock.lock(); defer { lock.unlock() }; return _received }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    func start() {
        let t = Thread { [self] in
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            serve(TCPSocket(fd: fd))
        }
        thread = t
        t.start()
    }

    func stop() {
        Darwin.shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    private func serve(_ s: TCPSocket) {
        var streaming = false
        var pusher: Thread?
        while let p = try? s.readPacket(maxBody: 1 << 20) {
            lock.lock(); _received.append(p); lock.unlock()
            guard let cmd = p.proxyCommand else { continue }
            switch cmd {
            case .selectBonDriver:
                let name = String(decoding: p.body.prefix { $0 != 0 }, as: UTF8.self)
                try? s.send(ProxyPacket.bool(.selectBonDriver, name == acceptedDriver).encoded())
            case .createBonDriver, .openTuner, .purgeTsStream, .setLnbPower:
                try? s.send(ProxyPacket.bool(cmd, true).encoded())
            case .enumTuningSpace:
                let i = Int(p.body.readBE32(at: 0)!)
                try? s.send(ProxyPacket.wideString(cmd, i < spaces.count ? spaces[i].0 : nil).encoded())
            case .enumChannelName:
                let sp = Int(p.body.readBE32(at: 0)!), ch = Int(p.body.readBE32(at: 4)!)
                let name = sp < spaces.count && ch < spaces[sp].1.count ? spaces[sp].1[ch] : nil
                try? s.send(ProxyPacket.wideString(cmd, name).encoded())
            case .setChannel2:
                try? s.send(ProxyPacket.dwords(.setChannel2, lockedChannel ? 1 : 0).encoded())
                if !streaming && !lockedChannel {
                    streaming = true
                    let chunk = tsChunk, sig = signal
                    pusher = Thread {
                        for _ in 0..<5 {
                            try? s.send(ProxyPacket.tsStream(signal: sig, data: chunk).encoded())
                            usleep(5000)
                        }
                    }
                    pusher?.start()
                }
            case .getTotalDeviceNum:
                try? s.send(ProxyPacket.dwords(cmd, 2).encoded())
            case .getActiveDeviceNum:
                try? s.send(ProxyPacket.dwords(cmd, 1).encoded())
            case .release:
                s.shutdown()
                return
            default:
                break
            }
        }
    }
}
