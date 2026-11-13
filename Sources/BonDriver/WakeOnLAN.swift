import Darwin
import Foundation

public enum WakeOnLAN {
    /// Send a magic packet (6×0xFF + 16×MAC) over UDP with SO_BROADCAST, like BonDriver_Proxy.
    public static func send(mac: [UInt8], host: String, port: UInt16) throws {
        guard mac.count == 6 else { throw BonDriverError.connectionFailed("invalid MAC address") }
        var payload = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { payload += mac }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw BonDriverError.connectionFailed("magic packet: cannot resolve \(host)")
        }
        defer { freeaddrinfo(first) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            let n = payload.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, a.pointee.ai_addr, a.pointee.ai_addrlen) }
            close(fd)
            if n == payload.count { return }
        }
        throw BonDriverError.connectionFailed("magic packet: send failed")
    }
}
