import Foundation
import SettingsSync
import SwiftUI

/// Shares settings between the user's Macs, iPhones and iPads through iCloud key-value storage
/// (`SettingsSync`). Synced: the server list and current server, channel lists (scan result, order,
/// hidden / known entries), last channel / service, caption display and automatic guide grabbing.
/// Device-specific settings (volume, decoding, deinterlacing, screenshots, panel) and the programme
/// guide data stay local.
///
/// Works only in builds signed with the `com.apple.developer.ubiquity-kvstore-identifier`
/// entitlement (iOS app, Developer ID release of the Mac app); elsewhere `isAvailable` is false and
/// everything stays in UserDefaults as before.
enum CloudSettings {
    /// Local-only switch (設定 → iCloud で同期).
    static let enabledKey = "iCloudSync"
    private static let syncedKeys: Set<String> = ["profiles", "currentProfile", "showCaptions", "captionStyle", "epgAutoGrab"]
    private static let syncedPrefixes = ["scan.", "channelOrder.", "hiddenChannels.", "knownChannels.", "lastChannel.", "lastServices."]

    static func isSynced(_ key: String) -> Bool {
        syncedKeys.contains(key) || syncedPrefixes.contains { key.hasPrefix($0) }
    }

    /// Called on the main thread with the settings another device changed (already in UserDefaults).
    static var onChange: ((Set<String>) -> Void)?

    private static var sync: SettingsSync?
    private static var observer: NSObjectProtocol?
    /// Whether this build can use iCloud key-value storage (entitled and running as an app).
    private(set) static var isAvailable = false

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                // Merge again: changes made while it was off are combined, not overwritten.
                UserDefaults.standard.removeObject(forKey: "iCloudSyncInitialized")
                start()
                onChange?(Set(UserDefaults.standard.settingKeys.filter(isSynced)))
            } else {
                stop()
            }
        }
    }

    /// Start syncing (idempotent). Runs before the app model reads its settings.
    static func start() {
        guard sync == nil, Bundle.main.bundleIdentifier != nil else { return }
        let store = NSUbiquitousKeyValueStore.default
        // false without the iCloud entitlement (ad-hoc builds, `swift run`). Checked even while
        // syncing is off, so the settings toggle can turn it back on.
        isAvailable = store.synchronize()
        guard isAvailable, isEnabled else { return }
        // Per-channel keys of earlier versions (now one `lastServices.<profile>` each).
        for key in store.dictionaryRepresentation.keys where key.hasPrefix("lastService.") { store.removeObject(forKey: key) }
        let s = SettingsSync(local: UserDefaults.standard, cloud: store, isSynced: isSynced,
                             merge: ["profiles": mergeProfiles])
        sync = s
        s.start()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { note in
            guard let s = sync else { return }
            let info = note.userInfo ?? [:]
            let reason = info[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = info[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            let changed: Set<String>
            switch reason {
            case NSUbiquitousKeyValueStoreAccountChange:
                changed = s.accountDidChange()
            case NSUbiquitousKeyValueStoreInitialSyncChange:
                // First download for this device: merge (server lists are combined) instead of replacing.
                changed = s.initialMerge()
            case NSUbiquitousKeyValueStoreQuotaViolationChange:
                NSLog("BonView: iCloud key-value storage quota exceeded; some settings are not synced")
                changed = []
            default:
                changed = s.cloudDidChange(keys: keys)
            }
            if !changed.isEmpty { onChange?(changed) }
        }
    }

    private static func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        sync = nil
    }

    /// A setting was written to UserDefaults.
    static func didSet(_ key: String) {
        sync?.localDidSet(key)
    }

    private static func mergeProfiles(local: Any, cloud: Any) -> Any {
        let decoder = JSONDecoder()
        guard let l = local as? Data, let c = cloud as? Data,
              let localList = try? decoder.decode([ServerProfile].self, from: l),
              let cloudList = try? decoder.decode([ServerProfile].self, from: c) else { return cloud }
        let merged = mergeProfiles(local: localList, cloud: cloudList, deleted: Preferences.deletedProfileIDs)
        return (try? Preferences.encoder.encode(merged)) ?? cloud
    }

    /// Server lists of two devices: iCloud's entries first, then this device's entries iCloud lacks,
    /// without the servers deleted here (e.g. while syncing was off).
    static func mergeProfiles(local: [ServerProfile], cloud: [ServerProfile], deleted: Set<UUID>) -> [ServerProfile] {
        let ids = Set(cloud.map(\.id))
        return (cloud + local.filter { !ids.contains($0.id) }).filter { !deleted.contains($0.id) }
    }
}


/// Settings section for iCloud sync (macOS settings window, iOS settings screen).
struct CloudSyncSection: View {
    @State private var enabled = CloudSettings.isEnabled

    var body: some View {
        Section {
            Toggle("iCloud で設定を同期", isOn: $enabled)
                .onChange(of: enabled) { _, on in CloudSettings.isEnabled = on }
                .disabled(!CloudSettings.isAvailable && !enabled)
        } header: {
            Text("iCloud")
        } footer: {
            Text(CloudSettings.isAvailable || !enabled
                 ? "BonDriver サーバー、チャンネル一覧、前回のチャンネル、字幕と番組表の自動取得の設定を、同じ Apple アカウントの Mac・iPhone・iPad で共有します。音量や再生の設定、番組表のデータは端末ごとです。"
                 : "このビルドでは iCloud を使えません（iCloud の権限付きで署名した配布版・iOS 版で使えます）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
