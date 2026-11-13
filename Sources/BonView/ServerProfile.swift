import ChannelScan
import BonDriver
import Foundation

/// One selectable "BonDriver" entry (the driver list): a remote tuner reached through
/// BonDriverProxy(Ex) or BonDriverTunnel.
struct ServerProfile: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case proxy
        case tunnel
        var id: Self { self }
        var label: String {
            switch self {
            case .proxy: return "BonDriverProxy(Ex)"
            case .tunnel: return "BonDriverTunnel"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind = .proxy
    var config: ProxyConfig
    var tunnel = TunnelConfig()

    init(name: String, kind: Kind = .proxy, config: ProxyConfig = ProxyConfig(), tunnel: TunnelConfig = TunnelConfig()) {
        self.name = name
        self.kind = kind
        self.config = config
        self.tunnel = tunnel
    }

    // Profiles saved before Tunnel support have no `kind` / `tunnel`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .proxy
        config = try c.decodeIfPresent(ProxyConfig.self, forKey: .config) ?? ProxyConfig()
        tunnel = try c.decodeIfPresent(TunnelConfig.self, forKey: .tunnel) ?? TunnelConfig()
    }

    var address: String { kind == .proxy ? config.address : tunnel.address }
    var port: UInt16 { kind == .proxy ? config.port : tunnel.port }
    var driverName: String { kind == .proxy ? config.bonDriver : "BonDriver_\(TunnelConfig.normalizeOrigin(tunnel.origin)).dll" }

    var displayName: String {
        name.isEmpty ? "\(driverName) @ \(address)" : name
    }

    /// Blocking: connect and create the remote BonDriver.
    func makeDriver() throws -> BonDriver {
        switch kind {
        case .proxy: return try ProxyClient.connect(config: config)
        case .tunnel: return try TunnelClient.connect(config: tunnel)
        }
    }

    static let sample = ServerProfile(name: "地デジ (PT3)", config: ProxyConfig(address: "192.168.0.10", port: 1192, bonDriver: "BonDriver_PT3-T.dll"),
                                      tunnel: TunnelConfig(address: "192.168.0.10", origin: "PT3-T"))
}

enum Preferences {
    private static let profilesKey = "profiles"
    private static let currentKey = "currentProfile"

    /// One-time import of settings saved by development builds (bundle id `local.tvtest.mac`).
    private static func migrateLegacyDefaults() {
        let d = UserDefaults.standard
        guard d.object(forKey: profilesKey) == nil, !d.bool(forKey: "migratedLegacyDefaults"),
              let old = d.persistentDomain(forName: "local.tvtest.mac") else { return }
        for (k, v) in old where !k.hasPrefix("NS") && !k.hasPrefix("Apple") { d.set(v, forKey: k) }
        d.set(true, forKey: "migratedLegacyDefaults")
    }

    static func loadProfiles() -> [ServerProfile] {
        migrateLegacyDefaults()
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let list = try? JSONDecoder().decode([ServerProfile].self, from: data) else { return [] }
        return list
    }

    static func saveProfiles(_ list: [ServerProfile]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: profilesKey) }
    }

    static var currentProfileID: UUID? {
        get { UserDefaults.standard.string(forKey: currentKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: currentKey) }
    }

    static func lastChannel(for profile: UUID) -> (UInt32, UInt32)? {
        guard let s = UserDefaults.standard.string(forKey: "lastChannel.\(profile)") else { return nil }
        let parts = s.split(separator: "-").compactMap { UInt32($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static func setLastChannel(_ ch: (UInt32, UInt32), for profile: UUID) {
        UserDefaults.standard.set("\(ch.0)-\(ch.1)", forKey: "lastChannel.\(profile)")
    }

    static func lastService(for profile: UUID, space: UInt32, channel: UInt32) -> UInt16? {
        let v = UserDefaults.standard.integer(forKey: "lastService.\(profile).\(space)-\(channel)")
        return v > 0 ? UInt16(clamping: v) : nil
    }

    static func setLastService(_ sid: UInt16, for profile: UUID, space: UInt32, channel: UInt32) {
        UserDefaults.standard.set(Int(sid), forKey: "lastService.\(profile).\(space)-\(channel)")
    }

    static func scanResult(for profile: UUID) -> [ScannedChannel] {
        guard let data = UserDefaults.standard.data(forKey: "scan.\(profile)"),
              let list = try? JSONDecoder().decode([ScannedChannel].self, from: data) else { return [] }
        return list
    }

    static func setScanResult(_ list: [ScannedChannel], for profile: UUID) {
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: "scan.\(profile)")
        } else if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "scan.\(profile)")
        }
    }

    static func channelOrder(for profile: UUID) -> [String] {
        UserDefaults.standard.stringArray(forKey: "channelOrder.\(profile)") ?? []
    }

    static func setChannelOrder(_ ids: [String], for profile: UUID) {
        UserDefaults.standard.set(ids.isEmpty ? nil : ids, forKey: "channelOrder.\(profile)")
    }

    static func hiddenEntries(for profile: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenChannels.\(profile)") ?? [])
    }

    static func setHiddenEntries(_ ids: Set<String>, for profile: UUID) {
        UserDefaults.standard.set(ids.isEmpty ? nil : ids.sorted(), forKey: "hiddenChannels.\(profile)")
    }

    static func double(_ key: String, default d: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? d
    }

    static func bool(_ key: String, default d: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? d
    }
}
