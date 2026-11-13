import Foundation

/// Settings of BonDriver_Proxy (`BonDriver_Proxy.ini` on Windows, `BonDriver_Proxy.so.conf` on Linux).
public struct ProxyConfig: Codable, Hashable, Sendable {
    /// BonDriverProxy / BonDriverProxyEx server.
    public var address: String
    public var port: UInt16
    /// BonDriver to load on the server, e.g. `BonDriver_PT3-T.dll` or `/usr/local/lib/BonDriver_LinuxPT-T0.so`.
    public var bonDriver: String
    /// Channel lock priority (0 = none, 0xFF = exclusive). Clients with a higher value win.
    public var channelLock: UInt8
    /// Connection timeout in seconds.
    public var connectTimeout: Int

    public var useMagicPacket: Bool
    public var magicPacketAddress: String?
    public var magicPacketPort: UInt16?
    /// 6-byte MAC address for Wake-on-LAN.
    public var macAddress: [UInt8]?

    /// Upper bound of one TS packet payload accepted from the server (TSPACKET_BUFSIZE).
    public var tsPacketBufSize: Int
    /// Ask HaijinW BonDriverProxyEx to descramble (B25=1 of its BonDriver_Proxy.ini).
    /// The server descrambles only when its own ini also has B25=1; other servers ignore it.
    public var requestB25: Bool

    public init(address: String = "127.0.0.1", port: UInt16 = 1192, bonDriver: String = "",
                channelLock: UInt8 = 0, connectTimeout: Int = 5,
                useMagicPacket: Bool = false, magicPacketAddress: String? = nil, magicPacketPort: UInt16? = nil,
                macAddress: [UInt8]? = nil, tsPacketBufSize: Int = 192_512, requestB25: Bool = true) {
        self.address = address
        self.port = port
        self.bonDriver = bonDriver
        self.channelLock = channelLock
        self.connectTimeout = connectTimeout
        self.useMagicPacket = useMagicPacket
        self.magicPacketAddress = magicPacketAddress
        self.magicPacketPort = magicPacketPort
        self.macAddress = macAddress
        self.tsPacketBufSize = tsPacketBufSize
        self.requestB25 = requestB25
    }

    private enum CodingKeys: String, CodingKey {
        case address, port, bonDriver, channelLock, connectTimeout
        case useMagicPacket, magicPacketAddress, magicPacketPort, macAddress, tsPacketBufSize, requestB25
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(address: try c.decode(String.self, forKey: .address),
                  port: try c.decode(UInt16.self, forKey: .port),
                  bonDriver: try c.decode(String.self, forKey: .bonDriver),
                  channelLock: try c.decodeIfPresent(UInt8.self, forKey: .channelLock) ?? 0,
                  connectTimeout: try c.decodeIfPresent(Int.self, forKey: .connectTimeout) ?? 5,
                  useMagicPacket: try c.decodeIfPresent(Bool.self, forKey: .useMagicPacket) ?? false,
                  magicPacketAddress: try c.decodeIfPresent(String.self, forKey: .magicPacketAddress),
                  magicPacketPort: try c.decodeIfPresent(UInt16.self, forKey: .magicPacketPort),
                  macAddress: try c.decodeIfPresent([UInt8].self, forKey: .macAddress),
                  tsPacketBufSize: try c.decodeIfPresent(Int.self, forKey: .tsPacketBufSize) ?? 192_512,
                  requestB25: try c.decodeIfPresent(Bool.self, forKey: .requestB25) ?? true)
    }

    public enum ParseError: Error, CustomStringConvertible {
        case missing(String)
        case invalidMAC(String)
        public var description: String {
            switch self {
            case .missing(let k): return "\(k) が設定されていません"
            case .invalidMAC(let v): return "MACアドレスが不正です: \(v)"
            }
        }
    }

    /// Parse the original `.ini` (Windows) / `.conf` (Linux) format. `[SECTION]` headers and
    /// `;` comments are ignored, the first occurrence of each key wins (same as the original).
    public static func parse(_ text: String) throws -> ProxyConfig {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if values[key] == nil { values[key] = value }
        }
        guard let address = values["ADDRESS"], !address.isEmpty else { throw ParseError.missing("ADDRESS") }
        guard let portStr = values["PORT"], let port = UInt16(portStr) else { throw ParseError.missing("PORT") }
        guard let driver = values["BONDRIVER"], !driver.isEmpty else { throw ParseError.missing("BONDRIVER") }

        var cfg = ProxyConfig(address: address, port: port, bonDriver: driver)
        if let v = values["CHANNEL_LOCK"], let n = Int(v) { cfg.channelLock = UInt8(clamping: n) }
        if let v = values["CONNECT_TIMEOUT"], let n = Int(v), n > 0 { cfg.connectTimeout = n }
        if let v = values["TSPACKET_BUFSIZE"], let n = Int(v), n > 0 { cfg.tsPacketBufSize = n }
        if let v = values["B25"], let n = Int(v) { cfg.requestB25 = n != 0 }
        if let v = values["USE_MAGICPACKET"], let n = Int(v) { cfg.useMagicPacket = n != 0 }
        if let mac = values["TARGET_MACADDRESS"] {
            guard let bytes = parseMAC(mac) else { throw ParseError.invalidMAC(mac) }
            cfg.macAddress = bytes
        }
        cfg.magicPacketAddress = values["TARGET_ADDRESS"]
        if let v = values["TARGET_PORT"] { cfg.magicPacketPort = UInt16(v) }
        if cfg.useMagicPacket && cfg.macAddress == nil { throw ParseError.missing("TARGET_MACADDRESS") }
        return cfg
    }

    /// Accepts `AA-BB-CC-DD-EE-FF`, `AA:BB:...` or `AABBCCDDEEFF`.
    public static func parseMAC(_ s: String) -> [UInt8]? {
        let hex = s.filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var out: [UInt8] = []
        var idx = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}
