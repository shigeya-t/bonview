import Darwin
import Foundation
@testable import BonDriver

/// In-process BonDriverTunnel server reproducing BonDriverTunnel.cpp's behaviour:
/// Crea/Conn handshake, session IDs, repeated-command reply cache and polled GTsS.
final class MockTunnelServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32

    var origin = "Mock-T"
    var spaces: [(String, [String])] = [("地デジ", ["NHK総合", "Eテレ"])]
    var tsChunks = 5
    var chunk = Data(repeating: 0x47, count: 188 * 100)
    var signal: Float = 31.5
    /// Close the connection after this many commands (once) to exercise reconnection.
    var dropAfterCommands: Int?

    private let lock = NSLock()
    private var _commands: [String] = []
    private var _handshakes: [String] = []
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return _commands }
    var handshakes: [String] { lock.lock(); defer { lock.unlock() }; return _handshakes }

    private let sessionID: UInt32 = 0x1234_5670
    private var lastCommand = Data()
    private var lastReply = Data()
    private var remainingChunks = 0
    private var dropped = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    func start() {
        Thread { [self] in
            while true {
                let fd = accept(listenFD, nil, nil)
                guard fd >= 0 else { return }
                if !serve(TCPSocket(fd: fd)) { return }
            }
        }.start()
    }

    func stop() {
        Darwin.shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    private func dw(_ v: UInt32) -> Data { Data(v.leBytes) }

    private func wstr(_ s: String?) -> Data {
        guard let s else { return dw(0) }
        var d = dw(UInt32(s.utf16.count + 1))
        for u in s.utf16 { d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8)) }
        d.append(contentsOf: [0, 0])
        return d
    }

    /// Returns false when the client released the driver.
    private func serve(_ s: TCPSocket) -> Bool {
        guard let hello = try? s.readExactly(524) else { return true }
        let kind = String(decoding: hello[4..<8], as: UTF8.self)
        var units: [UInt16] = []
        var i = 12
        while i < 524 { let u = UInt16(hello[i]) | UInt16(hello[i + 1]) << 8; if u == 0 { break }; units.append(u); i += 2 }
        let requested = String(decoding: units, as: UTF16.self)
        lock.lock(); _handshakes.append("\(kind):\(requested)"); lock.unlock()
        if requested != origin { s.close(); return true }
        if kind == "Crea" {
            try? s.send(dw(sessionID | 3))
        } else {
            guard hello.leUInt32(at: 8) == sessionID else { s.close(); return true }
            try? s.send(dw(0))
        }

        while let cmd = try? s.readExactly(16) {
            let name = String(decoding: cmd[0..<4], as: UTF8.self)
            lock.lock(); _commands.append(name); let count = _commands.count; lock.unlock()
            let p1 = cmd.leUInt32(at: 8), p2 = cmd.leUInt32(at: 12)
            var reply: Data
            if cmd == lastCommand {
                reply = lastReply // repeated after reconnect
            } else {
                switch name {
                case "Open", "Purg", "Clos": reply = dw(name == "Open" ? 1 : 0)
                case "GTun": reply = wstr("Mock Tuner")
                case "ETun": reply = wstr(Int(p1) < spaces.count ? spaces[Int(p1)].0 : nil)
                case "ECha":
                    let sp = Int(p1), ch = Int(p2)
                    reply = wstr(sp < spaces.count && ch < spaces[sp].1.count ? spaces[sp].1[ch] : nil)
                case "SCh2":
                    remainingChunks = tsChunks
                    reply = dw(Int(p1) < spaces.count && Int(p2) < spaces[Int(p1)].1.count ? 1 : 0)
                case "GSig": reply = dw(signal.bitPattern)
                case "GTot": reply = dw(2)
                case "GAct": reply = dw(1)
                case "GTsS":
                    if remainingChunks > 0 {
                        remainingChunks -= 1
                        reply = dw(UInt32(4 + chunk.count)) + dw(UInt32(remainingChunks)) + chunk
                    } else {
                        reply = dw(4) + dw(0)
                    }
                default: // Rele and anything unknown
                    try? s.send(dw(0))
                    s.close()
                    return false
                }
                lastCommand = cmd
                lastReply = reply
            }
            if let n = dropAfterCommands, count >= n, !dropped {
                dropped = true
                s.close() // drop before replying; client must reconnect and repeat
                return true
            }
            try? s.send(reply)
        }
        return true
    }
}
