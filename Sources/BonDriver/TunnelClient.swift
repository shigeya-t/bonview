import Foundation

/// BonDriver_Tunnel for macOS: talks to xtne6f's BonDriverTunnel.exe.
///
/// Wire format (all integers little-endian):
/// * handshake, 524 bytes: `"BD\0\0Crea"` (new) or `"BD\0\0Conn"` (resume) + session ID (4) +
///   origin as NUL-terminated UTF-16LE in 512 bytes. Reply: DWORD; for Crea the low 4 bits are
///   the IBonDriver version (0 = failed) and the rest is the session ID.
/// * command, 16 bytes: 4-char name + sequence number + param1 + param2. Reply: one DWORD,
///   or for strings a WCHAR count (including NUL, 0 = NULL) followed by the characters.
/// * TS is pulled with `GTsS`: reply `[4 + size][remain][TS bytes]`.
///
/// On a broken connection the client reconnects with `Conn` + session ID and repeats the last
/// command with the same sequence number; the server answers repeats from its cache.
public final class TunnelClient: BonDriver, @unchecked Sendable {
    public let config: TunnelConfig
    public var tsHandler: ((Data) -> Void)?
    public var errorHandler: ((BonDriverError) -> Void)?
    /// IBonDriver version reported by the server (1–3).
    public private(set) var interfaceVersion: UInt32 = 0

    static let maxTsBuf = 481_280

    private let lock = NSRecursiveLock()
    private var socket: TCPSocket?
    private var sessionID: UInt32 = 0
    private var sequence: UInt32 = 0
    private var failed = false

    private let stateLock = NSLock()
    private var _signal: Float = 0
    private var _space: UInt32?
    private var _channel: UInt32?
    private var _tunerName = "BonDriver_Tunnel"
    private var tunerOpen = false
    private var released = false
    private var pump: Thread?
    private let pumpDone = DispatchSemaphore(value: 0)

    private init(config: TunnelConfig) {
        self.config = config
    }

    /// Equivalent to `CreateBonDriver()` of BonDriver_Tunnel.dll.
    public static func connect(config: TunnelConfig) throws -> TunnelClient {
        var cfg = config
        cfg.origin = TunnelConfig.normalizeOrigin(cfg.origin)
        guard !cfg.origin.isEmpty, cfg.origin.utf16.count < 256 else {
            throw BonDriverError.rejected("接続先BonDriver名が不正です")
        }
        let c = TunnelClient(config: cfg)
        let reply = try c.handshake(create: true)
        c.sessionID = reply & 0xFFFF_FFF0
        c.interfaceVersion = reply & 0x0F
        guard c.interfaceVersion != 0 else {
            c.socket?.close()
            // BonDriverTunnel.exe answered, but LoadLibrary / CreateBonDriver of the origin failed on the server.
            throw BonDriverError.rejected("""
            サーバー側で BonDriver_\(cfg.origin).dll を開けませんでした。\
            BonDriverTunnel.exe と同じフォルダにあるか、32bit/64bit が一致しているか、\
            BonDriverLocalProxy 経由なら同じ優先度(BonDriver_ProxyX_ の X)の接続が他にないかを確認してください
            """)
        }
        return c
    }

    deinit {
        stopPump()
        socket?.close()
    }

    // MARK: - Transport

    private func openSocket() throws -> TCPSocket {
        let s = try TCPSocket.connect(host: config.address, port: config.port,
                                      timeout: TimeInterval(max(1, config.connectTimeout)))
        s.setTimeouts(config.sendRecvTimeout)
        return s
    }

    /// Opens a socket and performs Crea/Conn. Returns the server's DWORD reply.
    @discardableResult
    private func handshake(create: Bool) throws -> UInt32 {
        socket?.close()
        socket = nil
        let s = try openSocket()
        var buf = Data(count: 524)
        buf.replaceSubrange(0..<8, with: Array("BD\0\0\(create ? "Crea" : "Conn")".utf8))
        buf.replaceSubrange(8..<12, with: sessionID.leBytes)
        var i = 12
        for u in config.origin.utf16 {
            buf[i] = UInt8(u & 0xFF)
            buf[i + 1] = UInt8(u >> 8)
            i += 2
        }
        do {
            try s.send(buf)
            // The server simply closes the socket when the origin is already in use.
            let reply = try s.readExactly(4).leUInt32(at: 0)
            socket = s
            return reply
        } catch {
            s.close()
            if create {
                throw BonDriverError.rejected("BonDriverTunnel が接続を受け付けませんでした（BonDriver_\(config.origin) が使用中か存在しません）")
            }
            throw error
        }
    }

    private func write(_ cmd: String, _ p1: UInt32, _ p2: UInt32) throws {
        guard let s = socket else { throw BonDriverError.disconnected }
        var b = Data(Array(cmd.utf8.prefix(4)))
        b.append(contentsOf: sequence.leBytes)
        b.append(contentsOf: p1.leBytes)
        b.append(contentsOf: p2.leBytes)
        try s.send(b)
    }

    /// Send a command and read its reply with `read`, reconnecting once on failure (same sequence number).
    private func transact<T>(_ cmd: String, _ p1: UInt32 = 0, _ p2: UInt32 = 0, read: (TCPSocket) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        stateLock.lock()
        let isFailed = failed
        stateLock.unlock()
        if isFailed { throw BonDriverError.disconnected }
        sequence &+= 1
        var lastError: Error = BonDriverError.disconnected
        for attempt in 0..<2 {
            do {
                if attempt > 0 { try handshake(create: false) }
                try write(cmd, p1, p2)
                guard let s = socket else { throw BonDriverError.disconnected }
                return try read(s)
            } catch {
                lastError = error
                socket?.close()
                socket = nil
            }
        }
        markFailed()
        throw (lastError as? BonDriverError) ?? .disconnected
    }

    private func dword(_ cmd: String, _ p1: UInt32 = 0, _ p2: UInt32 = 0) throws -> UInt32 {
        try transact(cmd, p1, p2) { try $0.readExactly(4).leUInt32(at: 0) }
    }

    private func string(_ cmd: String, _ p1: UInt32 = 0, _ p2: UInt32 = 0) throws -> String? {
        try transact(cmd, p1, p2) { s in
            let n = Int(try s.readExactly(4).leUInt32(at: 0) % 256)
            if n == 0 { return nil }
            let d = try s.readExactly(n * 2)
            var units: [UInt16] = []
            for k in 0..<n {
                let u = UInt16(d[d.startIndex + k * 2]) | UInt16(d[d.startIndex + k * 2 + 1]) << 8
                if u == 0 { break }
                units.append(u)
            }
            return String(decoding: units, as: UTF16.self)
        }
    }

    private func markFailed() {
        stateLock.lock()
        let first = !failed && !released
        failed = true
        stateLock.unlock()
        if first { errorHandler?(.disconnected) }
    }

    // MARK: - TS pump (GetTsStream polling)

    private func startPump() {
        let t = Thread { [weak self, pumpDone] in
            defer { pumpDone.signal() }
            var lastSignal = Date.distantPast
            while let self, self.pumpRunning {
                do {
                    let (data, remain) = try self.transact("GTsS") { s -> (Data, UInt32) in
                        let n = try s.readExactly(4).leUInt32(at: 0)
                        guard n >= 4, Int(n) - 4 <= Self.maxTsBuf else { throw BonDriverError.rejected("GTsS") }
                        let remain = try s.readExactly(4).leUInt32(at: 0)
                        return (try s.readExactly(Int(n) - 4), remain)
                    }
                    if !data.isEmpty { self.tsHandler?(data) }
                    if Date().timeIntervalSince(lastSignal) >= 1 {
                        lastSignal = Date()
                        let bits = try self.dword("GSig")
                        self.stateLock.lock(); self._signal = Float(bitPattern: bits); self.stateLock.unlock()
                    }
                    if data.isEmpty || remain == 0 { usleep(20_000) }
                } catch {
                    return
                }
            }
        }
        t.name = "BonDriver_Tunnel GetTsStream"
        t.qualityOfService = .userInteractive
        pump = t
        t.start()
    }

    private var pumpRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return tunerOpen && !failed && !released
    }

    private func stopPump() {
        guard let p = pump else { return }
        pump = nil
        if p != Thread.current { pumpDone.wait() }
    }

    // MARK: - IBonDriver

    public func openTuner() throws {
        guard try dword("Open") != 0 else { throw BonDriverError.rejected("OpenTuner") }
        if interfaceVersion >= 2, let name = try? string("GTun") {
            stateLock.lock(); _tunerName = name; stateLock.unlock()
        }
        stateLock.lock(); tunerOpen = true; stateLock.unlock()
        startPump()
    }

    public func closeTuner() {
        stateLock.lock()
        let wasOpen = tunerOpen
        tunerOpen = false
        _signal = 0
        _space = nil
        _channel = nil
        stateLock.unlock()
        stopPump()
        if wasOpen { _ = try? dword("Clos") }
    }

    public var signalLevel: Float {
        stateLock.lock(); defer { stateLock.unlock() }
        return _signal
    }

    public func purgeTsStream() {
        _ = try? dword("Purg")
    }

    public func release() {
        stateLock.lock()
        if released { stateLock.unlock(); return }
        stateLock.unlock()
        closeTuner()
        stateLock.lock(); released = true; stateLock.unlock()
        lock.lock()
        // Any unknown command makes the server release the BonDriver and reply 0.
        sequence &+= 1
        if (try? write("Rele", 0, 0)) != nil { _ = try? socket?.readExactly(4) }
        socket?.close()
        socket = nil
        lock.unlock()
    }

    // MARK: - IBonDriver2

    public var tunerName: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return _tunerName
    }

    public func enumTuningSpace(_ space: UInt32) -> String? {
        guard interfaceVersion >= 2 else { return space == 0 ? "既定" : nil }
        return try? string("ETun", space)
    }

    public func enumChannelName(space: UInt32, channel: UInt32) -> String? {
        guard interfaceVersion >= 2 else { return space == 0 && channel < 256 ? "Ch \(channel)" : nil }
        return try? string("ECha", space, channel)
    }

    public func setChannel(space: UInt32, channel: UInt32) throws -> SetChannelResult {
        let ok: UInt32
        if interfaceVersion >= 2 {
            ok = try dword("SCh2", space, channel)
        } else {
            ok = try dword("SCha", channel)
        }
        guard ok != 0 else { throw BonDriverError.rejected("SetChannel(\(space), \(channel))") }
        stateLock.lock()
        _space = space
        _channel = channel
        _signal = 0
        stateLock.unlock()
        return .tuned
    }

    public var currentSpace: UInt32? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _space
    }

    public var currentChannel: UInt32? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _channel
    }

    // MARK: - IBonDriver3

    public var totalDeviceNum: UInt32 {
        interfaceVersion >= 3 ? (try? dword("GTot")) ?? 0 : 0
    }

    public var activeDeviceNum: UInt32 {
        interfaceVersion >= 3 ? (try? dword("GAct")) ?? 0 : 0
    }

    public func setLnbPower(_ enable: Bool) -> Bool {
        guard interfaceVersion >= 3 else { return false }
        return ((try? dword("SLnb", enable ? 1 : 0)) ?? 0) != 0
    }
}

extension UInt32 {
    var leBytes: [UInt8] { [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8(self >> 24)] }
}

extension Data {
    func leUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
