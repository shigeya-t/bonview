import AppKit
import BonDriver
import ChannelScan
import Foundation
import MediaCore
import Observation
import TSCore

/// Application state. Mutated on the main thread only; BonDriver calls run on `driverQueue`.
@Observable
final class AppModel {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case playingFile(String)
        case failed(String)
    }

    // MARK: Profiles
    var profiles: [ServerProfile] = Preferences.loadProfiles() {
        didSet { Preferences.saveProfiles(profiles) }
    }
    var currentProfileID: UUID? = Preferences.currentProfileID {
        didSet { Preferences.currentProfileID = currentProfileID }
    }
    var currentProfile: ServerProfile? { profiles.first { $0.id == currentProfileID } ?? profiles.first }

    // MARK: Tuner
    var state: ConnectionState = .idle
    var spaces: [TuningSpace] = []
    var currentChannel: TuningSpace.Channel?
    var isTuning = false
    var channelLocked = false
    var signalLevel: Float = 0

    // MARK: Channel scan
    /// Scan result of the current profile (empty = never scanned → list physical channels).
    var scannedChannels: [ScannedChannel] = []
    var showScanSheet = false
    var scan: ScanProgress?

    struct ScanProgress: Equatable {
        var index = 0
        var total = 0
        var current = ""
        var found: [ScannedChannel] = []
        var finished = false
        var cancelled = false
    }

    /// One entry of the scanned channel list (a viewable service on a physical channel).
    struct ScannedEntry: Identifiable, Hashable {
        var channel: ScannedChannel
        var service: ScannedService
        /// Stable across rescans: "<space>-<channel>-<service id>".
        var id: String { "\(channel.id)-\(service.serviceID)" }
        /// "081" etc., when known.
        var numberText: String? { channel.threeDigitNumber(for: service).map { String(format: "%03d", $0) } }
        var tuningChannel: TuningSpace.Channel {
            TuningSpace.Channel(space: channel.space, index: channel.channel, name: channel.channelName)
        }
    }

    /// User's channel-list order (entry IDs) and hidden entries, per profile.
    var channelOrder: [String] = []
    var hiddenEntries: Set<String> = []

    /// All viewable services found by the scan, in the user's order (new ones after known ones,
    /// in scan order).
    var scannedEntries: [ScannedEntry] {
        let all = scannedChannels.flatMap { ch in ch.services.filter(\.isViewable).map { ScannedEntry(channel: ch, service: $0) } }
        return ChannelListOrder.sorted(all, order: channelOrder, id: \.id)
    }

    /// Entries shown in the channel list and used by ⌘↑ / ⌘↓.
    var visibleEntries: [ScannedEntry] {
        scannedEntries.filter { !hiddenEntries.contains($0.id) }
    }

    /// Programme on air on a scanned service, from EIT p/f seen while watching, else the programme guide.
    func currentProgram(_ e: ScannedEntry) -> EventInfo? {
        let now = broadcastTime ?? Date()
        return programCache.currentEvent(originalNetworkID: e.channel.originalNetworkID, transportStreamID: e.channel.transportStreamID,
                                         serviceID: e.service.serviceID, at: now)
            ?? epgKey(e).flatMap { epg.event(for: $0, at: now) }
    }

    func isHidden(_ e: ScannedEntry) -> Bool { hiddenEntries.contains(e.id) }

    func setHidden(_ e: ScannedEntry, _ hidden: Bool) {
        if hidden { hiddenEntries.insert(e.id) } else { hiddenEntries.remove(e.id) }
        if let p = currentProfile { Preferences.setHiddenEntries(hiddenEntries, for: p.id) }
    }

    /// Reorder within one tuning space (`ids` is that space's visible list as displayed).
    func moveEntries(_ ids: [String], from source: IndexSet, to destination: Int) {
        let full = ChannelListOrder.move(ids, from: source, to: destination, in: scannedEntries.map(\.id))
        channelOrder = full
        if let p = currentProfile { Preferences.setChannelOrder(full, for: p.id) }
    }

    var isScanning: Bool { scan.map { !$0.finished } ?? false }

    // MARK: Stream
    var services: [ServiceInfo] = []
    var selection: StreamSelection?
    var presentEvent: EventInfo?
    var followingEvent: EventInfo?
    /// Present / following events of every service seen while watching (channel list).
    var programCache = ProgramCache()
    var broadcastTime: Date?
    var status = PlayerStatus()
    var videoSize: CGSize = .zero
    /// Caption plane currently on screen.
    var captionFrame = CaptionFrame()
    /// Superimpose (文字スーパー) plane currently on screen.
    var superimposeFrame = CaptionFrame()
    /// Caption languages of the current service (from the caption management data).
    var captionLanguages: [CaptionLanguage] = []
    var captionLanguageIndex = 0 {
        didSet { if oldValue != captionLanguageIndex { player.selectCaptionLanguage(index: captionLanguageIndex) } }
    }

    // MARK: Programme guide (see ProgramGuide.swift)
    /// Guide data of the current profile: EIT schedule from the background grab plus whatever
    /// the viewing stream carries.
    var epg = EPGStore()
    var epgGrab: EPGGrabProgress?
    /// When the last full grab of the current profile finished.
    var epgLastGrab: Date?
    var epgAutoGrab = Preferences.bool("epgAutoGrab", default: false) {
        didSet { UserDefaults.standard.set(epgAutoGrab, forKey: "epgAutoGrab") }
    }
    @ObservationIgnored var epgGrabber: EPGGrabber?
    @ObservationIgnored let epgQueue = DispatchQueue(label: "bonview.epg-driver", qos: .utility)
    /// EIT from the stream being watched (works with a single tuner, too).
    @ObservationIgnored let passiveEPG = EPGCollector()
    @ObservationIgnored var epgGeneration = 0
    @ObservationIgnored var epgDirty = false
    @ObservationIgnored var epgLastSave = Date()
    /// TSID of the channel the background grab is reading (tuner sharing check).
    @ObservationIgnored var epgGrabTSID: UInt16?

    // MARK: Audio / video options
    var volume: Double = Preferences.double("volume", default: 0.8) {
        didSet { player.presenter.volume = Float(volume); UserDefaults.standard.set(volume, forKey: "volume") }
    }
    var isMuted = false {
        didSet { player.presenter.isMuted = isMuted }
    }
    var dualMono: DualMonoMode = .both {
        didSet { player.setDualMono(dualMono) }
    }
    var audioIndex = 0 {
        didSet { player.selectAudio(index: audioIndex) }
    }

    /// Labels for the selected service's audio ES (EIT audio component text / language, else 音声N).
    var audioStreamLabels: [String] {
        guard let sel = selection else { return [] }
        return AudioComponent.labels(for: sel.audioStreams, components: presentEvent?.audioComponents ?? [])
    }

    /// Label of a 二重音声 choice; uses the languages from the EIT when they are known (日本語 / 英語).
    func dualMonoLabel(_ mode: DualMonoMode, short: Bool = false) -> String {
        let tag = selection?.audio?.componentTag
        let names = presentEvent?.audioComponents.first { $0.componentTag == tag && tag != nil }?.dualMonoNames
        switch (mode, names) {
        case (.main, let n?): return n.main
        case (.sub, let n?): return n.sub
        default: return short ? mode.shortLabel : mode.label
        }
    }
    var hardwareDecoding = Preferences.bool("hardwareDecoding", default: true) {
        didSet { player.setHardwareDecoding(hardwareDecoding); UserDefaults.standard.set(hardwareDecoding, forKey: "hardwareDecoding") }
    }
    var deinterlace = Preferences.bool("deinterlace", default: true) {
        didSet { player.setDeinterlace(deinterlace); UserDefaults.standard.set(deinterlace, forKey: "deinterlace") }
    }
    var showCaptions = Preferences.bool("showCaptions", default: true) {
        didSet { UserDefaults.standard.set(showCaptions, forKey: "showCaptions") }
    }
    var captionStyle = CaptionStyle(rawValue: UserDefaults.standard.string(forKey: "captionStyle") ?? "") ?? .broadcast {
        didSet { UserDefaults.standard.set(captionStyle.rawValue, forKey: "captionStyle") }
    }
    var showPanel = Preferences.bool("showPanel", default: true) {
        didSet { UserDefaults.standard.set(showPanel, forKey: "showPanel") }
    }

    // MARK: Screenshots (see Screenshot.swift)
    var screenshotFolder: URL = Preferences.screenshotFolder {
        didSet { UserDefaults.standard.set(screenshotFolder.path, forKey: "screenshotFolder") }
    }
    var screenshotFormat = FrameSnapshot.Format(rawValue: UserDefaults.standard.string(forKey: "screenshotFormat") ?? "") ?? .png {
        didSet { UserDefaults.standard.set(screenshotFormat.rawValue, forKey: "screenshotFormat") }
    }
    var screenshotIncludesCaptions = Preferences.bool("screenshotIncludesCaptions", default: true) {
        didSet { UserDefaults.standard.set(screenshotIncludesCaptions, forKey: "screenshotIncludesCaptions") }
    }
    /// Short message shown over the picture (e.g. "保存しました").
    var notice: String?
    @ObservationIgnored var noticeGeneration = 0

    @ObservationIgnored let player = TSPlayer()
    @ObservationIgnored private var driver: BonDriver?
    @ObservationIgnored private let driverQueue = DispatchQueue(label: "bonview.driver", qos: .userInitiated)
    @ObservationIgnored private var fileSource: TSFileSource?
    @ObservationIgnored private var signalTimer: Timer?
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private let router = TSRouter()
    @ObservationIgnored private var scanner: ChannelScanner?

    init() {
        player.presenter.volume = Float(volume)
        player.setHardwareDecoding(hardwareDecoding)
        player.setDeinterlace(deinterlace)

        player.onServicesChanged = { [weak self] in self?.services = $0 }
        player.onSelectionChanged = { [weak self] sel in
            guard let self else { return }
            self.selection = sel
            if let sel, let p = self.currentProfile, let ch = self.currentChannel {
                Preferences.setLastService(sel.serviceID, for: p.id, space: ch.space, channel: ch.index)
            }
        }
        player.onEventChanged = { [weak self] p, f in self?.presentEvent = p; self?.followingEvent = f }
        player.onServiceEvent = { [weak self] in self?.programCache.update($0) }
        player.onTime = { [weak self] in self?.broadcastTime = $0 }
        player.onStatus = { [weak self] in self?.status = $0 }
        player.onCaption = { [weak self] in self?.captionFrame = $0 }
        player.onSuperimpose = { [weak self] in self?.superimposeFrame = $0 }
        player.onCaptionLanguages = { [weak self] langs in
            guard let self else { return }
            self.captionLanguages = langs
            if !langs.isEmpty, !langs.indices.contains(self.captionLanguageIndex) { self.captionLanguageIndex = 0 }
        }
        player.onVideoSizeChanged = { [weak self] in
            self?.videoSize = $0
            self?.updateVideoScale()
        }
        let player = self.player
        let passive = passiveEPG
        router.set { player.feed($0); passive.feed($0) }

        signalTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.epgTick()
            guard let d = self.driver else { return }
            self.signalLevel = d.signalLevel
        }
    }

    // MARK: - Connection

    func connect(_ profile: ServerProfile? = nil) {
        guard let profile = profile ?? currentProfile else {
            state = .failed("サーバーが登録されていません。設定から追加してください。")
            return
        }
        disconnect()
        currentProfileID = profile.id
        state = .connecting
        generation += 1
        let gen = generation
        scannedChannels = Preferences.scanResult(for: profile.id)
        channelOrder = Preferences.channelOrder(for: profile.id)
        hiddenEntries = Preferences.hiddenEntries(for: profile.id)
        loadEPG(profile)
        let router = self.router
        driverQueue.async { [weak self] in
            do {
                let d = try profile.makeDriver()
                d.tsHandler = { router.feed($0) }
                d.errorHandler = { err in
                    DispatchQueue.main.async { self?.driverFailed(err, generation: gen) }
                }
                try d.openTuner()
                let spaces = d.enumerateChannels()
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { d.release(); return }
                    self.driver = d
                    self.spaces = spaces
                    self.state = .connected
                    let last = Preferences.lastChannel(for: profile.id)
                    let all = spaces.flatMap(\.channels)
                    let firstScanned = self.visibleEntries.first?.tuningChannel
                    if let ch = all.first(where: { $0.space == last?.0 && $0.index == last?.1 }) ?? firstScanned ?? all.first {
                        self.tune(ch)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.state = .failed(String(describing: error))
                }
            }
        }
    }

    func disconnect() {
        generation += 1
        cancelScan()
        cancelEPGGrab()
        saveEPG()
        fileSource?.stop()
        fileSource = nil
        if let d = driver {
            driver = nil
            driverQueue.async { d.release() }
        }
        player.stop()
        spaces = []
        currentChannel = nil
        services = []
        selection = nil
        presentEvent = nil
        followingEvent = nil
        signalLevel = 0
        channelLocked = false
        if case .failed = state {} else { state = .idle }
    }

    private func driverFailed(_ error: BonDriverError, generation gen: Int) {
        guard gen == generation else { return }
        driver = nil
        player.stop()
        state = .failed(error.description)
    }

    // MARK: - Tuning

    func tune(_ ch: TuningSpace.Channel, service: UInt16? = nil) {
        guard let d = driver, let profile = currentProfile, !isScanning else { return }
        if let service, ch == currentChannel, !isTuning, !channelLocked {
            // Same physical channel: just switch the service.
            selectService(service)
            return
        }
        currentChannel = ch
        isTuning = true
        channelLocked = false
        let preferred = service ?? Preferences.lastService(for: profile.id, space: ch.space, channel: ch.index)
        let player = self.player
        let gen = generation
        driverQueue.async { [weak self] in
            let result: Result<SetChannelResult, Error> = Result { try d.setChannel(space: ch.space, channel: ch.index) }
            if case .success(.tuned) = result {
                // Anything queued after this point belongs to the new channel.
                player.reset()
                self?.passiveEPG.resetStream()
                player.selectService(preferred)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.isTuning = false
                switch result {
                case .success(.tuned):
                    Preferences.setLastChannel((ch.space, ch.index), for: profile.id)
                case .success(.locked):
                    self.channelLocked = true
                case .failure(let e):
                    self.state = .failed(String(describing: e))
                }
            }
        }
    }

    /// Next/previous channel within the current tuning space (like ↑/↓ on a TV remote).
    func stepChannel(_ delta: Int) {
        let entries = visibleEntries
        if !entries.isEmpty {
            let i = entries.firstIndex { $0.tuningChannel == currentChannel && $0.service.serviceID == selection?.serviceID }
                ?? entries.firstIndex { $0.tuningChannel == currentChannel }
            let n = entries.count
            let next = i.map { ((($0 + delta) % n) + n) % n } ?? 0
            tune(entries[next].tuningChannel, service: entries[next].service.serviceID)
            return
        }
        guard let cur = currentChannel, let space = spaces.first(where: { $0.index == cur.space }),
              !space.channels.isEmpty, let i = space.channels.firstIndex(of: cur) else {
            if let first = spaces.first?.channels.first { tune(first) }
            return
        }
        let n = space.channels.count
        tune(space.channels[((i + delta) % n + n) % n])
    }

    func selectService(_ id: UInt16) {
        audioIndex = 0
        player.selectService(id)
    }

    // MARK: - Channel scan

    /// Scan the given tuning spaces. Results replace the previous ones for those spaces only.
    func startScan(spaces selected: Set<UInt32>) {
        guard let d = driver, let profile = currentProfile, !isScanning else { return }
        let targets = spaces.filter { selected.contains($0.index) }
        guard !targets.isEmpty else { return }
        let scanner = ChannelScanner()
        self.scanner = scanner
        scan = ScanProgress(total: targets.reduce(0) { $0 + $1.channels.count })
        player.stop()
        services = []
        selection = nil
        presentEvent = nil
        followingEvent = nil
        router.set { scanner.feed($0) }
        let gen = generation
        let player = self.player
        let router = self.router
        driverQueue.async { [weak self] in
            let result = scanner.scan(d, spaces: targets) { ev in
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    switch ev {
                    case .started(let ch, let i, let total):
                        self.scan?.index = i
                        self.scan?.total = total
                        self.scan?.current = ch.name
                    case .found(let c):
                        self.scan?.found.append(c)
                    case .empty:
                        break
                    }
                }
            }
            let passive = self?.passiveEPG
            router.set { player.feed($0); passive?.feed($0) }
            let cancelled = scanner.isCancelled
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanner = nil
                if var progress = self.scan {
                    progress.finished = true
                    progress.cancelled = cancelled
                    progress.index = progress.total
                    self.scan = progress
                }
                guard self.generation == gen else { return }
                if !cancelled {
                    let kept = self.scannedChannels.filter { !selected.contains($0.space) }
                    self.scannedChannels = (kept + result).sorted { ($0.space, $0.channel) < ($1.space, $1.channel) }
                    Preferences.setScanResult(self.scannedChannels, for: profile.id)
                    self.autoHideSubChannels(profile)
                }
                // Back to watching: the channel we were on, else the first one found.
                self.currentChannel = nil
                if let ch = self.lastTunedChannel(profile) ?? self.visibleEntries.first?.tuningChannel ?? self.spaces.first?.channels.first {
                    self.tune(ch)
                }
            }
        }
    }

    /// Hide multi-programming sub-channels (same name as the main service on the same channel)
    /// the first time they are found. Entries seen before keep whatever the user chose.
    private func autoHideSubChannels(_ profile: ServerProfile) {
        var known = Preferences.knownEntries(for: profile.id)
        for e in scannedEntries where !known.contains(e.id) {
            if e.channel.duplicateNameServiceIDs.contains(e.service.serviceID) { hiddenEntries.insert(e.id) }
            known.insert(e.id)
        }
        Preferences.setHiddenEntries(hiddenEntries, for: profile.id)
        Preferences.setKnownEntries(known, for: profile.id)
    }

    func cancelScan() {
        scanner?.cancel()
    }

    func clearScanResult() {
        guard let profile = currentProfile else { return }
        scannedChannels = []
        channelOrder = []
        hiddenEntries = []
        Preferences.setChannelOrder([], for: profile.id)
        Preferences.setHiddenEntries([], for: profile.id)
        Preferences.setKnownEntries([], for: profile.id)
        Preferences.setScanResult([], for: profile.id)
    }

    private func lastTunedChannel(_ profile: ServerProfile) -> TuningSpace.Channel? {
        let last = Preferences.lastChannel(for: profile.id)
        return spaces.flatMap(\.channels).first { $0.space == last?.0 && $0.index == last?.1 }
    }

    // MARK: - Files

    func openFile(_ url: URL) {
        disconnect()
        state = .playingFile(url.lastPathComponent)
        player.reset()
        let src = TSFileSource(url: url, player: player)
        src.onFinished = { [weak self] in
            if case .playingFile = self?.state { self?.state = .idle }
        }
        do {
            try src.start()
            fileSource = src
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Video size (50% / 100% / …)

    struct VideoScale: Hashable {
        var factor: Double
        var label: String
        var percent: Int { Int((factor * 100).rounded()) }
    }

    static let videoScales: [VideoScale] = [
        .init(factor: 0.2, label: "20%"),
        .init(factor: 0.25, label: "25%"),
        .init(factor: 1.0 / 3, label: "33% (1/3)"),
        .init(factor: 0.5, label: "50%"),
        .init(factor: 2.0 / 3, label: "67% (2/3)"),
        .init(factor: 0.75, label: "75%"),
        .init(factor: 1, label: "100%"),
        .init(factor: 1.5, label: "150%"),
        .init(factor: 2, label: "200%"),
    ]

    /// Toolbar text, e.g. "1920 x 1080 (100 %)".
    var videoScaleText: String {
        let pct = videoScalePercent.map { "\($0) %" } ?? "-- %"
        guard videoSize.width > 0 else { return "(\(pct))" }
        return "\(Int(videoSize.width)) x \(Int(videoSize.height)) (\(pct))"
    }

    /// How large the picture is shown relative to its native size (rounded %), for the toolbar.
    var videoScalePercent: Int?
    /// Whether the main window is in full-screen mode (updated on layout, which runs after every
    /// full-screen transition).
    var isFullScreen = false
    @ObservationIgnored private weak var videoHost: VideoHostView?

    /// Native display size (pixel aspect applied, e.g. 1440×1080 SAR 4:3 → 1920×1080).
    /// 1920×1080 until a picture has been decoded.
    var nativeVideoSize: CGSize {
        videoSize.width > 0 && videoSize.height > 0 ? videoSize : CGSize(width: 1920, height: 1080)
    }

    func videoHostDidLayout(_ host: VideoHostView) {
        videoHost = host
        updateVideoScale()
    }

    private func updateVideoScale() {
        guard let host = videoHost, host.bounds.width > 0, host.bounds.height > 0 else { return }
        let src = nativeVideoSize
        let fit = min(host.bounds.width / src.width, host.bounds.height / src.height)
        let pct = Int((fit * 100).rounded())
        if pct != videoScalePercent { videoScalePercent = pct }
        let full = host.window?.styleMask.contains(.fullScreen) ?? false
        if full != isFullScreen { isFullScreen = full }
    }

    func toggleFullScreen() {
        videoHost?.window?.toggleFullScreen(nil)
    }

    /// Resize the window so the picture is shown at `scale` of its native size (1 px = 1 pt,
    /// like QuickTime's "Actual Size"). The panel and status bar keep their size; the window
    /// keeps its top-left corner and is shrunk to fit the screen if needed.
    func setVideoScale(_ scale: VideoScale) {
        guard let host = videoHost, let window = host.window, !window.styleMask.contains(.fullScreen) else { return }
        let src = nativeVideoSize
        var target = CGSize(width: (src.width * scale.factor).rounded(),
                            height: (src.height * scale.factor).rounded())
        var frame = window.frame
        let extra = CGSize(width: frame.width - host.bounds.width, height: frame.height - host.bounds.height)
        if let visible = window.screen?.visibleFrame {
            let k = min(1, (visible.width - extra.width) / target.width, (visible.height - extra.height) / target.height)
            target = CGSize(width: (target.width * k).rounded(.down), height: (target.height * k).rounded(.down))
        }
        let size = CGSize(width: target.width + extra.width, height: target.height + extra.height)
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Display helpers

    var channelTitle: String {
        if case .playingFile(let name) = state { return name }
        let svc = services.first { $0.serviceID == selection?.serviceID }
        if let svc, !svc.name.isEmpty { return svc.name }
        return currentChannel?.name ?? "BonView"
    }

    var signalText: String { String(format: "%.2f dB", signalLevel) }
}

/// Routes TS from the driver's receive thread to the player or the channel scanner.
final class TSRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var target: ((Data) -> Void)?

    func set(_ target: @escaping (Data) -> Void) {
        lock.lock(); self.target = target; lock.unlock()
    }

    func feed(_ data: Data) {
        lock.lock(); let t = target; lock.unlock()
        t?(data)
    }
}

/// How captions are drawn.
enum CaptionStyle: String, CaseIterable {
    /// Position, size and colour as broadcast.
    case broadcast
    /// Plain text rows centred at the bottom of the picture.
    case simple

    var label: String {
        switch self {
        case .broadcast: return "放送どおりに表示"
        case .simple: return "下部にまとめて表示"
        }
    }
}

extension CaptionLanguage {
    var displayName: String {
        switch code {
        case "jpn": return "日本語"
        case "eng": return "英語"
        case "kor": return "韓国語"
        case "zho", "chi": return "中国語"
        default: return code
        }
    }
}
