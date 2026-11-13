import Foundation

/// BonDriver_Proxy for macOS: talks to BonDriverProxy / BonDriverProxyEx / BonDriverProxy_Linux.
///
/// Behaviour follows `cProxyClient` (BonDriver_Proxy.cpp):
/// * connect → SelectBonDriver(name) → CreateBonDriver on `connect(config:)`
/// * requests are answered in order; TS is pushed by the server as GetTsStream packets
///   once the tuner is open, carrying the current signal level with every chunk
/// * GetTunerName / IsTunerOpening / GetCurSpace / GetCurChannel are answered locally
public final class ProxyClient: BonDriver, @unchecked Sendable {
    public static let defaultTunerName = "BonDriver_Proxy"

    public let config: ProxyConfig
    public var tsHandler: ((Data) -> Void)?
    public var errorHandler: ((BonDriverError) -> Void)?
    /// Request timeout. SetChannel can take a few seconds on real tuners.
    public var requestTimeout: TimeInterval = 15

    private let socket: TCPSocket
    private var receiver: Thread?
    private let receiverDone = DispatchSemaphore(value: 0)

    // One RPC at a time; responses are matched by command.
    private let rpcLock = NSLock()
    private let cond = NSCondition()
    private var pendingCommand: UInt8?
    private var response: ProxyPacket?
    private var failure: BonDriverError?

    private let stateLock = NSLock()
    private var _signal: Float = 0
    private var _space: UInt32?
    private var _channel: UInt32?
    private var bonDriverCreated = false
    private var tunerOpen = false
    private var released = false

    // MARK: - Lifecycle

    private init(config: ProxyConfig, socket: TCPSocket) {
        self.config = config
        self.socket = socket
    }

    /// Equivalent to `CreateBonDriver()` exported by BonDriver_Proxy.dll.
    public static func connect(config: ProxyConfig) throws -> ProxyClient {
        if config.useMagicPacket, let mac = config.macAddress {
            try WakeOnLAN.send(mac: mac, host: config.magicPacketAddress ?? config.address,
                               port: config.magicPacketPort ?? config.port)
        }
        let sock = try TCPSocket.connect(host: config.address, port: config.port,
                                         timeout: TimeInterval(max(1, config.connectTimeout)))
        let client = ProxyClient(config: config, socket: sock)
        client.startReceiver()
        do {
            guard try client.call(.string(.selectBonDriver, config.bonDriver)).boolValue else {
                throw BonDriverError.rejected("SelectBonDriver(\(config.bonDriver))")
            }
            guard try client.call(ProxyPacket(.createBonDriver)).boolValue else {
                throw BonDriverError.rejected("CreateBonDriver(\(config.bonDriver))")
            }
            client.bonDriverCreated = true
        } catch {
            client.teardown()
            throw error
        }
        return client
    }

    deinit { teardown() }

    private func startReceiver() {
        let maxBody = max(config.tsPacketBufSize, 65536) + 8
        let t = Thread { [weak self, socket, receiverDone] in
            defer { receiverDone.signal() }
            while true {
                let packet: ProxyPacket
                do {
                    packet = try socket.readPacket(maxBody: maxBody)
                } catch let e as BonDriverError {
                    self?.fail(e)
                    return
                } catch {
                    self?.fail(.disconnected)
                    return
                }
                guard let self else { return }
                self.dispatch(packet)
            }
        }
        t.name = "BonDriver_Proxy receiver"
        t.qualityOfService = .userInteractive
        receiver = t
        t.start()
    }

    private func dispatch(_ packet: ProxyPacket) {
        if packet.command == ProxyCommand.getTsStream.rawValue {
            guard let ts = packet.tsPayload else { return } // drop malformed, like the original
            stateLock.lock()
            _signal = ts.signal
            stateLock.unlock()
            if !ts.data.isEmpty { tsHandler?(ts.data) }
            return
        }
        cond.lock()
        if pendingCommand == packet.command {
            response = packet
            pendingCommand = nil
            cond.broadcast()
        }
        cond.unlock()
    }

    private func fail(_ error: BonDriverError) {
        cond.lock()
        let first = failure == nil
        if first { failure = error }
        cond.broadcast()
        cond.unlock()
        stateLock.lock()
        let wasReleased = released
        stateLock.unlock()
        if first && !wasReleased { errorHandler?(error) }
    }

    private func teardown() {
        stateLock.lock()
        released = true
        stateLock.unlock()
        socket.shutdown()
        if let r = receiver {
            receiver = nil
            // The last reference can be dropped on the receiver thread itself; don't self-join.
            if r != Thread.current { receiverDone.wait() } else { return }
        }
        socket.close()
    }

    // MARK: - RPC

    /// Send a packet and wait for the reply with the same command.
    @discardableResult
    func call(_ packet: ProxyPacket) throws -> ProxyPacket {
        rpcLock.lock()
        defer { rpcLock.unlock() }
        cond.lock()
        if let f = failure { cond.unlock(); throw f }
        pendingCommand = packet.command
        response = nil
        cond.unlock()

        try socket.send(packet.encoded())

        let deadline = Date().addingTimeInterval(requestTimeout)
        cond.lock()
        defer { cond.unlock() }
        while response == nil && failure == nil {
            if !cond.wait(until: deadline) { break }
        }
        if let r = response { return r }
        pendingCommand = nil
        if let f = failure { throw f }
        throw BonDriverError.timeout(String(describing: packet.proxyCommand.map { "\($0)" } ?? "\(packet.command)"))
    }

    /// Fire-and-forget commands (CloseTuner, Release).
    private func post(_ packet: ProxyPacket) {
        try? socket.send(packet.encoded())
    }

    // MARK: - IBonDriver

    public func openTuner() throws {
        guard bonDriverCreated else { throw BonDriverError.notOpen }
        guard try call(ProxyPacket(.openTuner)).boolValue else { throw BonDriverError.rejected("OpenTuner") }
        stateLock.lock(); tunerOpen = true; stateLock.unlock()
    }

    public func closeTuner() {
        stateLock.lock()
        let wasOpen = tunerOpen
        tunerOpen = false
        _signal = 0
        _space = nil
        _channel = nil
        stateLock.unlock()
        if wasOpen { post(ProxyPacket(.closeTuner)) }
    }

    public var signalLevel: Float {
        stateLock.lock(); defer { stateLock.unlock() }
        return _signal
    }

    public func purgeTsStream() {
        guard isTunerOpen else { return }
        _ = try? call(ProxyPacket(.purgeTsStream))
    }

    public func release() {
        stateLock.lock()
        let alreadyReleased = released
        stateLock.unlock()
        if alreadyReleased { return }
        closeTuner()
        post(ProxyPacket(.release))
        teardown()
    }

    // MARK: - IBonDriver2

    public var tunerName: String { Self.defaultTunerName }

    public func enumTuningSpace(_ space: UInt32) -> String? {
        guard isTunerOpen else { return nil }
        return (try? call(.dwords(.enumTuningSpace, space)))?.wideStringValue
    }

    public func enumChannelName(space: UInt32, channel: UInt32) -> String? {
        guard isTunerOpen else { return nil }
        return (try? call(.dwords(.enumChannelName, space, channel)))?.wideStringValue
    }

    public func setChannel(space: UInt32, channel: UInt32) throws -> SetChannelResult {
        guard isTunerOpen else { throw BonDriverError.notOpen }
        var packet = ProxyPacket.dwords(.setChannel2, space, channel, trailingByte: config.channelLock)
        if config.requestB25 { packet.option = ProxyPacket.optionDesireToUseB25 }
        let reply = try call(packet)
        switch reply.dwordValue {
        case 0x00:
            stateLock.lock()
            _space = space
            _channel = channel
            _signal = 0
            stateLock.unlock()
            return .tuned
        case 0x01:
            return .locked
        default:
            stateLock.lock(); _signal = 0; stateLock.unlock()
            throw BonDriverError.rejected("SetChannel(\(space), \(channel))")
        }
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
        guard isTunerOpen else { return 0 }
        return (try? call(ProxyPacket(.getTotalDeviceNum)))?.dwordValue ?? 0
    }

    public var activeDeviceNum: UInt32 {
        guard isTunerOpen else { return 0 }
        return (try? call(ProxyPacket(.getActiveDeviceNum)))?.dwordValue ?? 0
    }

    public func setLnbPower(_ enable: Bool) -> Bool {
        guard isTunerOpen else { return false }
        return (try? call(.bool(.setLnbPower, enable)))?.boolValue ?? false
    }

    private var isTunerOpen: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return tunerOpen
    }
}
