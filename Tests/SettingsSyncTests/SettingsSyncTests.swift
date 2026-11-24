import Foundation
import SettingsSync
import Testing

private final class MemoryStore: KeyValueStore {
    var values: [String: Any] = [:]
    var writes = 0
    func setting(forKey key: String) -> Any? { values[key] }
    func setSetting(_ value: Any?, forKey key: String) { values[key] = value; writes += 1 }
    var settingKeys: [String] { Array(values.keys) }
}

@Suite struct SettingsSyncTests {
    private func make(local: [String: Any] = [:], cloud: [String: Any] = [:],
                      merge: [String: (Any, Any) -> Any] = [:]) -> (SettingsSync, MemoryStore, MemoryStore) {
        let l = MemoryStore(), c = MemoryStore()
        l.values = local
        c.values = cloud
        let sync = SettingsSync(local: l, cloud: c, isSynced: { $0.hasPrefix("s.") }, merge: merge)
        return (sync, l, c)
    }

    @Test func firstRunUploadsLocalAndDownloadsCloud() {
        let (sync, l, c) = make(local: ["s.a": 1, "s.b": 2, "volume": 0.5], cloud: ["s.b": 3, "s.c": 4])
        let changed = sync.start()
        #expect(l.values["s.a"] as? Int == 1)
        #expect(l.values["s.b"] as? Int == 3) // iCloud wins
        #expect(l.values["s.c"] as? Int == 4)
        #expect(c.values["s.a"] as? Int == 1)
        #expect(c.values["volume"] == nil) // not a synced key
        #expect(changed == ["s.b", "s.c"])
        #expect(sync.isInitialized)
    }

    @Test func mergeFunctionCombinesBothSides() {
        let (sync, l, c) = make(local: ["s.list": ["x", "y"]], cloud: ["s.list": ["y", "z"]],
                                merge: ["s.list": { l, c in
                                    let a = c as! [String], b = l as! [String]
                                    return a + b.filter { !a.contains($0) }
                                }])
        sync.start()
        #expect(l.values["s.list"] as? [String] == ["y", "z", "x"])
        #expect(c.values["s.list"] as? [String] == ["y", "z", "x"])
    }

    @Test func emptyCloudNeverWipesLocalSettings() {
        let (sync, l, c) = make(local: ["s.a": 1, "iCloudSyncInitialized": true])
        sync.start() // e.g. signed in to a new account: merge again instead of trusting iCloud
        #expect(l.values["s.a"] as? Int == 1)
        #expect(c.values["s.a"] as? Int == 1)
    }

    @Test func laterLaunchTakesCloudValues() {
        let (sync, l, _) = make(local: ["s.a": 1, "s.b": 5, "iCloudSyncInitialized": true], cloud: ["s.a": 2])
        #expect(sync.start() == ["s.a"])
        #expect(l.values["s.a"] as? Int == 2)
        #expect(l.values["s.b"] as? Int == 5) // removals only come through notifications
    }

    @Test func localWritesAreMirroredOnlyWhenChanged() {
        let (sync, l, c) = make()
        sync.start()
        l.values["s.a"] = 1
        sync.localDidSet("s.a")
        #expect(c.values["s.a"] as? Int == 1)
        let writes = c.writes
        sync.localDidSet("s.a")
        #expect(c.writes == writes)
        l.values["volume"] = 0.3
        sync.localDidSet("volume")
        #expect(c.values["volume"] == nil)
        l.values["s.a"] = nil
        sync.localDidSet("s.a")
        #expect(c.values["s.a"] == nil)
    }

    @Test func remoteChangesAndRemovalsAreApplied() {
        let (sync, l, c) = make(local: ["s.a": 1, "s.b": 2])
        sync.start()
        c.values["s.a"] = 10
        c.values["s.b"] = nil
        c.values["volume"] = 0.1
        let changed = sync.cloudDidChange(keys: ["s.a", "s.b", "volume"])
        #expect(changed == ["s.a", "s.b"])
        #expect(l.values["s.a"] as? Int == 10)
        #expect(l.values["s.b"] == nil)
        #expect(l.values["volume"] == nil)
    }

    @Test func accountChangeMergesAgain() {
        let (sync, l, c) = make(local: ["s.a": 1])
        sync.start()
        c.values = ["s.z": 9] // another account's store
        let changed = sync.accountDidChange()
        #expect(changed == ["s.z"])
        #expect(c.values["s.a"] as? Int == 1)
        #expect(l.values["s.z"] as? Int == 9)
    }
}
