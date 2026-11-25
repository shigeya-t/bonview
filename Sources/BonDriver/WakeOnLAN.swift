import Darwin
import Foundation

public enum WakeOnLAN {
    /// Send a magic packet (6×0xFF + 16×MAC) over UDP with SO_BROADCAST, like BonDriver_Proxy.
    ///
    /// IPv4 only (Wake-on-LAN is an IPv4 broadcast affair). The packet goes to `host` and also to
    /// the limited broadcast address: a sleeping machine's ARP entry may have expired, and then a
    /// unicast packet never leaves this Mac.
    public static func send(mac: [UInt8], host: String, port: UInt16) throws {
        guard mac.count == 6 else { throw BonDriverError.connectionFailed("invalid MAC address") }
        var payload = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { payload += mac }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw BonDriverError.connectionFailed("magic packet: cannot resolve \(host)")
        }
        defer { freeaddrinfo(first) }
        var targets: [sockaddr_in] = []
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            if let addr = a.pointee.ai_addr, a.pointee.ai_family == AF_INET {
                targets.append(addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee })
            }
        }
        var broadcast = sockaddr_in()
        broadcast.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        broadcast.sin_family = sa_family_t(AF_INET)
        broadcast.sin_port = port.bigEndian
        broadcast.sin_addr.s_addr = INADDR_BROADCAST
        if !targets.contains(where: { $0.sin_addr.s_addr == INADDR_BROADCAST }) { targets.append(broadcast) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw BonDriverError.connectionFailed("magic packet: socket failed") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var sent = false
        for var t in targets {
            let n = withUnsafePointer(to: &t) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    payload.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            if n == payload.count { sent = true }
        }
        if !sent { throw BonDriverError.connectionFailed("magic packet: send failed") }
    }
}
