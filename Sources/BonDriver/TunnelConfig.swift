import Foundation

/// Settings of BonDriver_Tunnel (`BonDriver_hoge.ini` next to the renamed BonDriver_Tunnel.dll).
public struct TunnelConfig: Codable, Hashable, Sendable {
    /// BonDriverTunnel.exe host.
    public var address: String
    public var port: UInt16
    /// Origin BonDriver on the server: the `*` of `BonDriver_*.dll` (e.g. `PT3-T`).
    public var origin: String
    public var connectTimeout: Int
    /// send/recv timeout; a stalled connection is re-established after this.
    public var sendRecvTimeout: Int

    public init(address: String = "127.0.0.1", port: UInt16 = 1193, origin: String = "",
                connectTimeout: Int = 5, sendRecvTimeout: Int = 5) {
        self.address = address
        self.port = port
        self.origin = origin
        self.connectTimeout = connectTimeout
        self.sendRecvTimeout = sendRecvTimeout
    }

    /// Accepts `PT3-T`, `BonDriver_PT3-T` or `BonDriver_PT3-T.dll` and returns `PT3-T`.
    public static func normalizeOrigin(_ s: String) -> String {
        var o = s.trimmingCharacters(in: .whitespaces)
        if o.lowercased().hasSuffix(".dll") { o = String(o.dropLast(4)) }
        if o.lowercased().hasPrefix("bondriver_") { o = String(o.dropFirst(10)) }
        return o
    }

    public enum ParseError: Error, CustomStringConvertible {
        case missing(String)
        public var description: String {
            switch self { case .missing(let k): return "\(k) が設定されていません" }
        }
    }

    /// Parse `BonDriver_hoge.ini`. `fileName` (e.g. "BonDriver_PT3-T.ini") supplies the origin
    /// when ORIGIN is absent, exactly like the DLL deriving it from its own name.
    public static func parse(_ text: String, fileName: String? = nil) throws -> TunnelConfig {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            if values[key] == nil { values[key] = value }
        }
        guard let address = values["ADDRESS"], !address.isEmpty else { throw ParseError.missing("ADDRESS") }
        var cfg = TunnelConfig(address: address)
        if let v = values["PORT"], let p = UInt16(v) { cfg.port = p }
        if let v = values["CONNECT_TIMEOUT"], let n = Int(v) { cfg.connectTimeout = n }
        if let v = values["SEND_RECV_TIMEOUT"], let n = Int(v) { cfg.sendRecvTimeout = n }
        if let o = values["ORIGIN"], !o.isEmpty {
            cfg.origin = o
        } else if let f = fileName {
            let base = (f as NSString).deletingPathExtension
            if base.lowercased().hasPrefix("bondriver_") { cfg.origin = String(base.dropFirst(10)) }
        }
        guard !cfg.origin.isEmpty else { throw ParseError.missing("ORIGIN") }
        return cfg
    }

    /// Heuristic for import: a Tunnel ini has no BONDRIVER key.
    public static func looksLikeTunnelConfig(_ text: String) -> Bool {
        let upper = text.uppercased()
        return !upper.contains("BONDRIVER=") && !upper.contains("BONDRIVER =") && upper.contains("ADDRESS")
    }
}
