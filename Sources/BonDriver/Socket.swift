import Darwin
import Foundation

/// Minimal blocking TCP socket used by the proxy client (and the test server).
final class TCPSocket: @unchecked Sendable {
    /// -1 once closed. Changed under `writeLock`, so a send never writes to a descriptor number
    /// that `close` has freed (and the system may have handed to another socket).
    private var fd: Int32
    private let writeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        // A server that vanished (power loss, network change) is noticed after about a minute
        // even while only receiving.
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
        var idle: Int32 = 30, interval: Int32 = 10, count: Int32 = 3
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    /// Resolve `host` and connect with a per-address timeout, like the original `Connect()`.
    static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> TCPSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw BonDriverError.connectionFailed("\(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(first) }

        var lastError = "no address"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { continue }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var r = Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen)
            if r != 0 && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                // Clamped: the value comes from user settings and must fit an Int32 of milliseconds.
                let ms = Int32(min(max(timeout, 0.1), 3600) * 1000)
                repeat { r = poll(&pfd, 1, ms) } while r < 0 && errno == EINTR
                if r == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    r = err == 0 ? 0 : -1
                    if err != 0 { lastError = String(cString: strerror(err)) }
                } else {
                    lastError = r == 0 ? "timeout" : String(cString: strerror(errno))
                    r = -1
                }
            } else if r != 0 {
                lastError = String(cString: strerror(errno))
            }
            if r == 0 {
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                return TCPSocket(fd: fd)
            }
            Darwin.close(fd)
        }
        throw BonDriverError.connectionFailed("\(host):\(port) (\(lastError))")
    }

    /// SO_SNDTIMEO / SO_RCVTIMEO. A timed-out read or write throws `.disconnected`. Clamped to
    /// 1 s … 1 h: no timeout would let a silent server block the caller forever.
    func setTimeouts(_ seconds: Int) {
        var tv = timeval(tv_sec: min(max(seconds, 1), 3600), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// SO_SNDTIMEO only (for connections whose reader legitimately waits for long periods).
    func setSendTimeout(_ seconds: Int) {
        var tv = timeval(tv_sec: min(max(seconds, 1), 3600), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func readExactly(_ count: Int) throws -> Data {
        var d = Data(count: count)
        if count > 0 { try d.withUnsafeMutableBytes { try readExactly(into: $0.baseAddress!, count: count) } }
        return d
    }

    func send(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard fd >= 0 else { throw BonDriverError.disconnected }
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = Darwin.send(fd, buf.baseAddress! + off, buf.count - off, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw BonDriverError.disconnected
                }
                off += n
            }
        }
    }

    /// Read exactly `count` bytes into `buffer`. Throws on EOF / error.
    func readExactly(into buffer: UnsafeMutableRawPointer, count: Int) throws {
        var off = 0
        while off < count {
            let n = recv(fd, buffer + off, count - off, 0)
            if n == 0 { throw BonDriverError.disconnected }
            if n < 0 {
                if errno == EINTR { continue }
                throw BonDriverError.disconnected
            }
            off += n
        }
    }

    /// Read one protocol packet. `maxBody` guards against garbage lengths.
    func readPacket(maxBody: Int) throws -> ProxyPacket {
        var head = [UInt8](repeating: 0, count: ProxyPacket.headerSize)
        try head.withUnsafeMutableBytes { try readExactly(into: $0.baseAddress!, count: ProxyPacket.headerSize) }
        guard head[0] == ProxyPacket.syncByte else { throw BonDriverError.rejected("invalid sync byte") }
        let len = Int(UInt32(head[4]) << 24 | UInt32(head[5]) << 16 | UInt32(head[6]) << 8 | UInt32(head[7]))
        guard len <= maxBody else { throw BonDriverError.rejected("packet too large (\(len))") }
        var body = Data(count: len)
        if len > 0 {
            try body.withUnsafeMutableBytes { try readExactly(into: $0.baseAddress!, count: len) }
        }
        return ProxyPacket(command: head[1], option: head[2], body: body)
    }

    /// Unblocks a reader thread (the descriptor stays open until `close`).
    func shutdown() {
        writeLock.lock(); defer { writeLock.unlock() }
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    /// Call once no thread is reading any more (readers use the descriptor without the lock).
    func close() {
        writeLock.lock()
        let f = fd
        fd = -1
        writeLock.unlock()
        if f >= 0 { Darwin.close(f) }
    }
}
