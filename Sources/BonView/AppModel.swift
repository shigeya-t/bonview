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
        var id: String { "\(channel.id)-\(service.serviceID)" }
        var tuningChannel: TuningSpace.Channel {
            TuningSpace.Channel(space: channel.space, index: channel.channel, name: channel.channelName)
        }
    }

    var scannedEntries: [ScannedEntry] {
        scannedChannels.flatMap { ch in ch.services.filter(\.isViewable).map { ScannedEntry(channel: ch, service: $0) } }
    }

    var isScanning: Bool { scan.map { !$0.finished } ?? false }

    // MARK: Stream
    var services: [ServiceInfo] = []
    var selection: StreamSelection?
    var presentEvent: EventInfo?
    var followingEvent: EventInfo?
    var broadcastTime: Date?
    var status = PlayerStatus()
    var videoSize: CGSize = .zero

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
    var hardwareDecoding = Preferences.bool("hardwareDecoding", default: true) {
        didSet { player.setHardwareDecoding(hardwareDecoding); UserDefaults.standard.set(hardwareDecoding, forKey: "hardwareDecoding") }
    }
    var deinterlace = Preferences.bool("deinterlace", default: true) {
        didSet { player.setDeinterlace(deinterlace); UserDefaults.standard.set(deinterlace, forKey: "deinterlace") }
    }
    var showPanel = Preferences.bool("showPanel", default: true) {
        didSet { UserDefaults.standard.set(showPanel, forKey: "showPanel") }
    }

    @ObservationIgnored let player = TSPlayer()
    @ObservationIgnored private var driver: BonDriver?
    @ObservationIgnored private let driverQueue = DispatchQueue(label: "bonview.driver", qos: .userInitiated)
    @ObservationIgnored private var fileSource: TSFileSource?
    @ObservationIgnored private var signalTimer: Timer?
    @ObservationIgnored private var generation = 0
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
        player.onTime = { [weak self] in self?.broadcastTime = $0 }
        player.onStatus = { [weak self] in self?.status = $0 }
        player.onVideoSizeChanged = { [weak self] in
            self?.videoSize = $0
            self?.updateVideoScale()
        }
        let player = self.player
        router.set { player.feed($0) }

        signalTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let d = self.driver else { return }
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
                    let firstScanned = self.scannedEntries.first?.tuningChannel
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
        let entries = scannedEntries
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
            router.set { player.feed($0) }
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
                }
                // Back to watching: the channel we were on, else the first one found.
                self.currentChannel = nil
                if let ch = self.lastTunedChannel(profile) ?? self.scannedEntries.first?.tuningChannel ?? self.spaces.first?.channels.first {
                    self.tune(ch)
                }
            }
        }
    }

    func cancelScan() {
        scanner?.cancel()
    }

    func clearScanResult() {
        guard let profile = currentProfile else { return }
        scannedChannels = []
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

    static let videoScales: [Int] = [50, 75, 100, 150, 200]

    /// How large the picture is shown relative to its native size (rounded %), for the toolbar.
    var videoScalePercent: Int?
    @ObservationIgnored private weak var videoHost: VideoHostView?

    /// Native display size (pixel aspect applied, e.g. 1440×1080 SAR 4:3 → 1920×1080).
    /// 1920×1080 until a picture has been decoded.
    private var nativeVideoSize: CGSize {
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
    }

    /// Resize the window so the picture is shown at `percent` of its native size (1 px = 1 pt,
    /// like QuickTime's "Actual Size"). The panel and status bar keep their size; the window
    /// keeps its top-left corner and is shrunk to fit the screen if needed.
    func setVideoScale(_ percent: Int) {
        guard let host = videoHost, let window = host.window, !window.styleMask.contains(.fullScreen) else { return }
        let src = nativeVideoSize
        var target = CGSize(width: (src.width * CGFloat(percent) / 100).rounded(),
                            height: (src.height * CGFloat(percent) / 100).rounded())
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
