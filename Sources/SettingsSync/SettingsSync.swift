import Foundation

/// A key-value store the settings live in: `UserDefaults` (local) or `NSUbiquitousKeyValueStore` (iCloud).
public protocol KeyValueStore: AnyObject {
    func setting(forKey key: String) -> Any?
    /// `nil` removes the key.
    func setSetting(_ value: Any?, forKey key: String)
    var settingKeys: [String] { get }
}

extension UserDefaults: KeyValueStore {
    public func setting(forKey key: String) -> Any? { object(forKey: key) }

    public func setSetting(_ value: Any?, forKey key: String) {
        if let value { set(value, forKey: key) } else { removeObject(forKey: key) }
    }

    /// Only this app's own domain (not NSGlobalDomain / argument domain).
    public var settingKeys: [String] {
        guard let id = Bundle.main.bundleIdentifier else { return Array(dictionaryRepresentation().keys) }
        return Array((persistentDomain(forName: id) ?? [:]).keys)
    }
}

extension NSUbiquitousKeyValueStore: KeyValueStore {
    public func setting(forKey key: String) -> Any? { object(forKey: key) }

    public func setSetting(_ value: Any?, forKey key: String) {
        if let value { set(value, forKey: key) } else { removeObject(forKey: key) }
    }

    public var settingKeys: [String] { Array(dictionaryRepresentation.keys) }
}

/// Mirrors a subset of the app's settings between the local store (authoritative for reads) and
/// iCloud.
///
/// - Local writes of synced keys go to iCloud as well (`localDidSet`), only when the value differs,
///   so devices don't echo each other's changes back.
/// - Changes from other devices (`cloudDidChange`) are copied into the local store, removals too.
/// - The first time (or after the iCloud account changes) local and iCloud values are merged:
///   iCloud wins for keys both have, except keys with a `merge` function (e.g. the server list,
///   which is a union), and local-only keys are uploaded. Nothing local is deleted by this step, so an
///   empty iCloud store (new account, not downloaded yet) never wipes the settings.
public final class SettingsSync {
    public let local: KeyValueStore
    public let cloud: KeyValueStore
    private let isSynced: (String) -> Bool
    private let merge: [String: (_ local: Any, _ cloud: Any) -> Any]
    /// Local-only flag: the initial merge has been done for the current iCloud account.
    private let initializedKey: String

    public init(local: KeyValueStore, cloud: KeyValueStore, isSynced: @escaping (String) -> Bool,
                merge: [String: (_ local: Any, _ cloud: Any) -> Any] = [:],
                initializedKey: String = "iCloudSyncInitialized") {
        self.local = local
        self.cloud = cloud
        self.isSynced = isSynced
        self.merge = merge
        self.initializedKey = initializedKey
    }

    public var isInitialized: Bool { local.setting(forKey: initializedKey) as? Bool ?? false }

    /// Call at launch (after the cloud store's `synchronize()`). Returns the local keys that changed.
    @discardableResult
    public func start() -> Set<String> {
        if !isInitialized || !cloud.settingKeys.contains(where: isSynced) {
            return initialMerge()
        }
        // Already merged before: iCloud holds everything this device wrote, so take what it has.
        // Removals made elsewhere arrive as change notifications.
        var changed: Set<String> = []
        for key in cloud.settingKeys where isSynced(key) {
            if copy(key, from: cloud, to: local) { changed.insert(key) }
        }
        return changed
    }

    /// Merge local settings with iCloud (first run, or a different iCloud account).
    @discardableResult
    public func initialMerge() -> Set<String> {
        var changed: Set<String> = []
        let localKeys = Set(local.settingKeys.filter(isSynced))
        let cloudKeys = Set(cloud.settingKeys.filter(isSynced))
        for key in localKeys.union(cloudKeys) {
            let l = local.setting(forKey: key), c = cloud.setting(forKey: key)
            switch (l, c) {
            case (let l?, let c?):
                let value = merge[key].map { $0(l, c) } ?? c
                if !equal(value, l) { local.setSetting(value, forKey: key); changed.insert(key) }
                if !equal(value, c) { cloud.setSetting(value, forKey: key) }
            case (let l?, nil):
                cloud.setSetting(l, forKey: key)
            case (nil, let c?):
                local.setSetting(c, forKey: key)
                changed.insert(key)
            case (nil, nil):
                break
            }
        }
        local.setSetting(true, forKey: initializedKey)
        return changed
    }

    /// A synced setting was written locally: send it to iCloud.
    public func localDidSet(_ key: String) {
        guard isSynced(key) else { return }
        let value = local.setting(forKey: key)
        if !equal(value, cloud.setting(forKey: key)) { cloud.setSetting(value, forKey: key) }
    }

    /// Keys changed on another device (`NSUbiquitousKeyValueStoreChangedKeysKey`). Returns the local
    /// keys that changed.
    public func cloudDidChange(keys: [String]) -> Set<String> {
        var changed: Set<String> = []
        for key in keys where isSynced(key) {
            if copy(key, from: cloud, to: local) { changed.insert(key) }
        }
        return changed
    }

    /// The iCloud account changed: forget the old merge and merge with the new account's store.
    public func accountDidChange() -> Set<String> {
        local.setSetting(nil, forKey: initializedKey)
        return initialMerge()
    }

    private func copy(_ key: String, from: KeyValueStore, to: KeyValueStore) -> Bool {
        let value = from.setting(forKey: key)
        guard !equal(value, to.setting(forKey: key)) else { return false }
        to.setSetting(value, forKey: key)
        return true
    }

    private func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a as NSObject, let b as NSObject): return a.isEqual(b)
        default: return false
        }
    }
}
