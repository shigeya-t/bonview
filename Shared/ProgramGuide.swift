import BonDriver
import ChannelScan
import Foundation
import os
import TSCore

/// Progress of a background programme guide grab.
struct EPGGrabProgress: Equatable {
    var index = 0
    var total = 0
    var current = ""
    var completeChannels = 0
    var lockedChannels = 0
    var finished = false
    var cancelled = false
    var error: String?

    var isRunning: Bool { !finished }
}

/// Programme guide: background acquisition on a second BonDriver connection, persistence and
/// lookups for the guide window and the channel list.
extension AppModel {
    /// Re-grab automatically when the last full grab is older than this.
    static let epgAutoGrabInterval: TimeInterval = 6 * 3600
    /// Minimum time between merges of new guide data into `epg` (see `epgPending`).
    static let epgPublishInterval: TimeInterval = 10

    /// Queue guide updates; they reach `epg` on the next `publishEPG`.
    func queueEPG(_ updates: EPGStore) {
        guard !updates.isEmpty else { return }
        epgPending.merge(updates)
        epgDirty = true
    }

    /// Merge queued updates into `epg` when `epgPublishInterval` has passed (or `force`).
    func publishEPG(force: Bool = false) {
        guard !epgPending.isEmpty, force || Date().timeIntervalSince(epgLastPublish) >= Self.epgPublishInterval else { return }
        epg.merge(epgPending)
        epgPending = EPGStore()
        epgLastPublish = Date()
    }

    func epgKey(_ e: ScannedEntry) -> EPGServiceKey? {
        epg.key(originalNetworkID: e.channel.originalNetworkID, transportStreamID: e.channel.transportStreamID,
                serviceID: e.service.serviceID)
    }

    /// Physical channels to visit: those of the visible channel list entries, in list order,
    /// each limited to its visible services (hidden sub-channels often carry no schedule).
    private func epgChannels() -> [ScannedChannel] {
        var order: [String] = []
        var byID: [String: ScannedChannel] = [:]
        for e in visibleEntries {
            if byID[e.channel.id] == nil {
                order.append(e.channel.id)
                var ch = e.channel
                ch.services = []
                byID[e.channel.id] = ch
            }
            byID[e.channel.id]!.services.append(e.service)
        }
        return order.compactMap { byID[$0] }
    }

    /// Open a second connection to the server and walk every channel collecting EIT schedule.
    /// Viewing continues on the main connection. The background connection asks for the lowest
    /// channel-lock priority so it never takes the tuner away from a viewer.
    func startEPGGrab() {
        guard let profile = currentProfile, state == .connected, !isGrabbingEPG, !isScanning else { return }
        let channels = epgChannels()
        guard !channels.isEmpty else {
            epgGrab = EPGGrabProgress(finished: true, error: "チャンネルスキャンを行ってください")
            return
        }
        var background = profile
        background.config.channelLock = 0
        let grabber = EPGGrabber()
        epgGrabber = grabber
        epgGrab = EPGGrabProgress(total: channels.count, current: "接続中…")
        epgGeneration += 1
        let gen = epgGeneration
        epgQueue.async { [weak self] in
            var failure: String?
            // A lost connection stops the grab like a cancel, but is reported as an error.
            let connectionError = OSAllocatedUnfairLock<String?>(initialState: nil)
            do {
                let d = try background.makeDriver()
                defer { d.release() }
                d.tsHandler = { grabber.feed($0) }
                d.errorHandler = { e in
                    connectionError.withLock { $0 = $0 ?? e.description }
                    grabber.cancel()
                }
                try d.openTuner()
                try grabber.grab(d, channels: channels) { ev in
                    DispatchQueue.main.async { self?.handleGrabEvent(ev, generation: gen) }
                }
            } catch {
                failure = String(describing: error)
            }
            if let lost = connectionError.withLock({ $0 }) { failure = failure ?? lost }
            let cancelled = grabber.isCancelled && failure == nil
            DispatchQueue.main.async {
                guard let self, self.epgGeneration == gen else { return }
                self.epgGrabber = nil
                self.epgGrabTSID = nil
                guard var p = self.epgGrab else { return }
                p.finished = true
                p.index = p.total
                p.current = ""
                p.cancelled = cancelled
                if let failure {
                    p.error = failure
                } else if p.lockedChannels > 0 && p.lockedChannels == p.total {
                    p.error = "空きチューナーがないため、チャンネルを切り替えられませんでした"
                }
                self.epgGrab = p
                if failure == nil && !cancelled && p.error == nil, let id = self.epgProfileID {
                    self.epgLastGrab = Date()
                    Preferences.setEPGLastGrab(Date(), for: id)
                }
                self.saveEPG()
            }
        }
    }

    private func handleGrabEvent(_ ev: EPGGrabber.Event, generation gen: Int) {
        guard epgGeneration == gen, var p = epgGrab else { return }
        switch ev {
        case .started(let ch, let i, let total):
            p.index = i
            p.total = total
            p.current = ch.services.first?.displayName ?? ch.channelName
            epgGrabTSID = ch.transportStreamID
        case .skipped:
            p.completeChannels += 1
        case .locked:
            p.lockedChannels += 1
        case .finished(_, let complete):
            if complete { p.completeChannels += 1 }
        case .updates(let u):
            queueEPG(u)
        }
        epgGrab = p
    }

    func cancelEPGGrab() {
        epgGrabber?.cancel()
        if epgGrabber != nil {
            epgGeneration += 1
            epgGrabber = nil
            epgGrabTSID = nil
            if var p = epgGrab {
                p.finished = true
                p.cancelled = true
                epgGrab = p
            }
        }
    }

    /// Called every second from the main timer.
    func epgTick() {
        queueEPG(passiveEPG.takeUpdates())
        publishEPG()
        checkTunerSharing()
        if epgDirty, Date().timeIntervalSince(epgLastSave) > 300 { saveEPG() }
        // Automatic grabs: once per connection, then every few hours; not again after an error or a cancel.
        if epgAutoGrab, state == .connected, !isGrabbingEPG, !isScanning, !scannedChannels.isEmpty,
           epgGrab.map({ $0.error == nil && !$0.cancelled }) ?? true,
           Date().timeIntervalSince(epgLastGrab ?? .distantPast) > Self.epgAutoGrabInterval {
            startEPGGrab()
        }
    }

    /// With a single tuner (or equal channel-lock priorities) the server may move the viewer's
    /// tuner when the background connection changes channel. If the stream being watched turns
    /// into the channel being grabbed, stop grabbing and tune back.
    private func checkTunerSharing() {
        guard isGrabbingEPG, let grabbing = epgGrabTSID, !isTuning, let cur = currentChannel,
              let watching = scannedChannels.first(where: { $0.space == cur.space && $0.channel == cur.index })?.transportStreamID,
              watching != grabbing, passiveEPG.actualTransportStreamID == grabbing else { return }
        cancelEPGGrab()
        epgGrab?.error = "視聴中のチューナーが使われたため番組表の取得を中止しました (空きチューナーが必要です)"
        let service = selection?.serviceID
        currentChannel = nil
        tune(cur, service: service)
    }

    // MARK: - Persistence

    /// Reads, writes and removals of guide files, in order (a load never overtakes a save or a
    /// clear of the same file).
    static let epgFileQueue = DispatchQueue(label: "bonview.epg-files", qos: .utility)

    /// Empty guide for `profile`, dropping a load in flight and what the viewing stream collected
    /// so far (it may belong to the previous profile).
    func resetEPG(profile: UUID?) {
        epg = EPGStore()
        epgPending = EPGStore()
        epgDirty = false
        epgGrab = nil
        epgProfileID = profile
        epgLoaded = true
        epgLoadToken += 1
        passiveEPG.resetStream()
        _ = passiveEPG.takeUpdates()
    }

    func loadEPG(_ profile: ServerProfile) {
        resetEPG(profile: profile.id)
        epgLastGrab = Preferences.epgLastGrab(for: profile.id)
        epgLoaded = false
        let url = Preferences.epgURL(for: profile.id)
        let token = epgLoadToken
        Self.epgFileQueue.async { [weak self] in
            let result = Self.readEPG(url)
            if case .stale = result {
                // Saved by an older text decoder (e.g. before gaiji support): drop it and re-grab.
                try? FileManager.default.removeItem(at: url)
            }
            DispatchQueue.main.async {
                guard let self, self.epgLoadToken == token else { return }
                self.epgLoaded = true
                switch result {
                case .stale:
                    Preferences.setEPGLastGrab(nil, for: profile.id)
                    self.epgLastGrab = nil
                case .loaded(var store):
                    store.merge(self.epg)
                    self.epg = store
                case .none:
                    break
                }
            }
        }
    }

    private enum EPGFile {
        case none, stale, loaded(EPGStore)
    }

    private static func readEPG(_ url: URL) -> EPGFile {
        guard let data = try? Data(contentsOf: url) else { return .none }
        do {
            var store = try JSONDecoder().decode(EPGStore.self, from: data)
            store.prune(before: Date().addingTimeInterval(-3 * 3600))
            return .loaded(store)
        } catch is EPGStore.StaleData {
            return .stale
        } catch {
            return .none
        }
    }

    func saveEPG() {
        guard epgDirty, let id = epgProfileID else { return }
        publishEPG(force: true)
        epgDirty = false
        epgLastSave = Date()
        var store = epg
        let mergeIntoFile = !epgLoaded
        let url = Preferences.epgURL(for: id)
        Self.epgFileQueue.async {
            if mergeIntoFile, case .loaded(var saved) = Self.readEPG(url) {
                // The saved guide was not loaded yet (disconnected right after connecting).
                saved.merge(store)
                store = saved
            }
            store.prune(before: Date().addingTimeInterval(-3 * 3600))
            guard let data = try? JSONEncoder().encode(store) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func clearEPG() {
        guard let id = epgProfileID ?? currentProfile?.id else { return }
        cancelEPGGrab()
        resetEPG(profile: id)
        epgLastGrab = nil
        Preferences.setEPGLastGrab(nil, for: id)
        Self.removeEPGFile(for: id)
    }

    static func removeEPGFile(for profile: UUID) {
        let url = Preferences.epgURL(for: profile)
        epgFileQueue.async { try? FileManager.default.removeItem(at: url) }
    }
}

extension Preferences {
    /// ~/Library/Application Support/BonView/EPG/<profile>.json
    static func epgURL(for profile: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("BonView/EPG/\(profile.uuidString).json")
    }

    static func epgLastGrab(for profile: UUID) -> Date? {
        UserDefaults.standard.object(forKey: "epgLastGrab.\(profile)") as? Date
    }

    static func setEPGLastGrab(_ date: Date?, for profile: UUID) {
        UserDefaults.standard.set(date, forKey: "epgLastGrab.\(profile)")
    }
}
