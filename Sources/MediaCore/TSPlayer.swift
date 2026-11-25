import CoreVideo
import Foundation
import TSCore

/// Unwraps 33-bit 90 kHz timestamps into a continuous 64-bit timeline. Applied to PES
/// timestamps before decoding, so the decoders and filters (bwdif interpolates field times)
/// never see the wrap.
struct PTSUnwrapper {
    private var offset: Int64 = 0
    private var last: Int64?
    static let wrap: Int64 = 1 << 33

    mutating func reset() { offset = 0; last = nil }

    /// Unwraps an audio/video PTS and moves the timeline along.
    mutating func ticks(_ raw: Int64) -> Int64 {
        let v = peek(raw)
        offset = v - (raw & (Self.wrap - 1))
        last = v
        return v
    }

    /// The unwrapped value nearest the timeline, without moving it (DTS, caption PTS: a bogus
    /// value there cannot shift audio and video).
    func peek(_ raw: Int64) -> Int64 {
        var v = (raw & (Self.wrap - 1)) + offset
        if let l = last {
            if v - l < -(Self.wrap / 2) { v += Self.wrap }
            else if v - l > Self.wrap / 2 { v -= Self.wrap }
        }
        return v
    }
}

public struct PlayerStatus: Sendable, Equatable {
    public var bitrateMbps: Double = 0
    public var packets = 0
    public var errorPackets = 0
    public var continuityErrors = 0
    public var scrambledPackets = 0
    /// The selected service's video/audio was scrambled during the last second.
    public var isScrambled = false
    public var droppedPES = 0
    public var bufferedSeconds: Double = 0
    public var videoCodec = ""
    public var audioCodec = ""
    /// The current audio is 二重音声 (two mono programmes, ADTS AAC only).
    public var isDualMono = false

    public init() {}
}

/// TS → demux → decode → present. All processing happens on `queue`; callbacks are
/// delivered on the main queue.
public final class TSPlayer: @unchecked Sendable {
    public let presenter = AVPresenter()

    public var onServicesChanged: (([ServiceInfo]) -> Void)?
    public var onSelectionChanged: ((StreamSelection?) -> Void)?
    public var onEventChanged: ((EventInfo?, EventInfo?) -> Void)?
    /// Present / following events of any service (EIT p/f actual and other), on the main thread.
    public var onServiceEvent: ((ServiceEventUpdate) -> Void)?
    public var onTime: ((Date) -> Void)?
    public var onStatus: ((PlayerStatus) -> Void)?
    public var onVideoSizeChanged: ((CGSize) -> Void)?
    /// Caption plane to show now. Timed against the presenter clock.
    public var onCaption: ((CaptionFrame) -> Void)?
    /// Superimpose (文字スーパー) plane to show now.
    public var onSuperimpose: ((CaptionFrame) -> Void)?
    /// Caption languages from the management data (empty until received / no captions).
    public var onCaptionLanguages: (([CaptionLanguage]) -> Void)?

    private let queue = DispatchQueue(label: "bonview.player", qos: .userInteractive)
    private let demuxer = TSDemuxer()
    private var video: MediaDecoder?
    private var audio: MediaDecoder?
    private var unwrap = PTSUnwrapper()
    private var status = PlayerStatus()
    private var bytesWindow = 0
    private var windowStart = Date()
    private var droppedPES = 0
    private var lastScrambledSelected = 0
    private var pendingBytes = 0
    private let pendingLock = NSLock()
    private var captions = CaptionDecoder()
    private var superimpose = CaptionDecoder()
    private var captionLanguage = 0
    /// Decoded caption states waiting for their presentation time.
    private var pendingCaptions: [(time: Double, superimpose: Bool, frame: CaptionFrame)] = []
    private var shownCaption = CaptionFrame()
    private var shownSuperimpose = CaptionFrame()
    private var captionPID: UInt16?
    private var superimposePID: UInt16?

    // Options (read on the player queue).
    private var hardwareDecoding = true
    /// False while nothing is on screen (iOS background audio): video PES are dropped undecoded.
    private var videoEnabled = true
    private var deinterlace = DeinterlaceMode.fieldRate
    private var dualMono: DualMonoMode = .both
    /// Dual-mono detection with hysteresis: the flag flips after this many agreeing frames.
    private var dualMonoVotes = 0
    private static let dualMonoVotesNeeded = 3

    public init() {
        demuxer.onServicesChanged = { [weak self] s in self?.main { $0.onServicesChanged?(s) } }
        demuxer.onEventChanged = { [weak self] p, f in self?.main { $0.onEventChanged?(p, f) } }
        demuxer.onServiceEvent = { [weak self] u in self?.main { $0.onServiceEvent?(u) } }
        demuxer.onTime = { [weak self] t in self?.main { $0.onTime?(t) } }
        demuxer.onSelectionChanged = { [weak self] sel in self?.selectionChanged(sel) }
        demuxer.onPES = { [weak self] track, info, pes in self?.handlePES(track, info, pes) }
        presenter.onVideoSizeChanged = { [weak self] size in self?.main { $0.onVideoSizeChanged?(size) } }
    }

    private func main(_ body: @escaping (TSPlayer) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { body(self) } }
    }

    // MARK: - Input

    /// Feed raw TS bytes (any thread). If the decoder falls far behind, input is dropped
    /// rather than queued without bound.
    public func feed(_ data: Data) {
        pendingLock.lock()
        if pendingBytes > 32 << 20 {
            pendingLock.unlock()
            return
        }
        pendingBytes += data.count
        pendingLock.unlock()
        queue.async { [self] in
            pendingLock.lock(); pendingBytes -= data.count; pendingLock.unlock()
            demuxer.feed(data)
            deliverCaptions()
            bytesWindow += data.count
            tickStatus()
        }
    }

    /// Call when switching channels: forget tables and flush decoders/presenter.
    public func reset() {
        queue.async { [self] in
            demuxer.reset()
            video = nil
            audio = nil
            unwrap.reset()
            presenter.flush()
            resetCaptions()
            resetStatus()
            dualMonoVotes = 0
        }
    }

    public func stop() {
        queue.async { [self] in
            demuxer.reset()
            video = nil
            audio = nil
            // The next stream (another server, a file) starts with the default service and audio.
            demuxer.preferredServiceID = nil
            demuxer.audioIndex = 0
            unwrap.reset()
            presenter.clear()
            resetCaptions()
            resetStatus()
            dualMonoVotes = 0
            let s = status
            main { $0.onStatus?(s) }
        }
    }

    /// No more input (end of a file): keep presenting the captions decoded but not yet due.
    public func finishInput() {
        queue.async { [self] in drainCaptions(until: Date().addingTimeInterval(15)) }
    }

    private func drainCaptions(until deadline: Date) {
        deliverCaptions()
        guard !pendingCaptions.isEmpty, Date() < deadline else { return }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.drainCaptions(until: deadline) }
    }

    private func resetStatus() {
        status = PlayerStatus()
        bytesWindow = 0
        windowStart = Date()
        droppedPES = 0
        lastScrambledSelected = 0
    }

    // MARK: - Options

    public func selectService(_ id: UInt16?) {
        queue.async { [self] in demuxer.preferredServiceID = id }
    }

    public func selectAudio(index: Int) {
        queue.async { [self] in demuxer.audioIndex = index }
    }

    public func setDualMono(_ mode: DualMonoMode) {
        queue.async { [self] in
            dualMono = mode
            applyDualMono()
        }
    }

    public func setHardwareDecoding(_ on: Bool) {
        queue.async { [self] in
            guard hardwareDecoding != on else { return }
            hardwareDecoding = on
            video = nil // re-created on the next selection/PES
            if let sel = demuxer.selection { makeDecoders(sel) }
        }
    }

    /// Stop / resume decoding video (audio and captions continue). Resuming waits for the next
    /// key frame without disturbing the audio clock.
    public func setVideoEnabled(_ on: Bool) {
        queue.async { [self] in
            guard videoEnabled != on else { return }
            videoEnabled = on
            if let sel = demuxer.selection { makeDecoders(sel, keepClock: true) }
        }
    }

    /// Re-anchor the presentation clock (audio interruption, output route change).
    public func resync() {
        queue.async { [self] in presenter.flush() }
    }

    public func setDeinterlace(_ mode: DeinterlaceMode) {
        queue.async { [self] in
            guard deinterlace != mode else { return }
            deinterlace = mode
            video = nil
            if let sel = demuxer.selection { makeDecoders(sel) }
        }
    }

    // MARK: - Pipeline

    private func selectionChanged(_ sel: StreamSelection?) {
        if let sel { makeDecoders(sel) } else { video = nil; audio = nil; captionPID = nil; superimposePID = nil; resetCaptions() }
        main { $0.onSelectionChanged?(sel) }
    }

    private func makeDecoders(_ sel: StreamSelection, keepClock: Bool = false) {
        if sel.caption?.pid != captionPID || sel.superimpose?.pid != superimposePID {
            captionPID = sel.caption?.pid
            superimposePID = sel.superimpose?.pid
            resetCaptions()
        }
        var flushed = false
        if let v = sel.video, videoEnabled {
            if video?.pid != v.pid || video?.streamType != v.streamType {
                video = MediaDecoder(streamType: v.streamType, pid: v.pid, hardware: hardwareDecoding, deinterlace: deinterlace)
                video?.onVideo = { [weak self] pb, pts in self?.presentVideo(pb, pts) }
                flushed = !keepClock
            }
        } else {
            video = nil
        }
        if let a = sel.audio {
            if audio?.pid != a.pid || audio?.streamType != a.streamType {
                audio = MediaDecoder(streamType: a.streamType, pid: a.pid, hardware: false, deinterlace: .off)
                setDualMonoDetected(false)
                audio?.onAudio = { [weak self] s, f, c, r, pts in self?.presentAudio(s, f, c, r, pts) }
                flushed = true
            }
        } else {
            audio = nil
            setDualMonoDetected(false)
        }
        presenter.setExpectsAudio(audio != nil)
        if flushed { presenter.flush() }
        if videoEnabled {
            status.videoCodec = video?.description ?? (sel.video.map { "\($0.codecName) (未対応)" } ?? "")
        }
        status.audioCodec = audio?.description ?? ""
    }

    private func handlePES(_ track: TSDemuxer.Track, _ info: ElementaryStreamInfo, _ pes: PESPacket) {
        switch track {
        case .video:
            if !videoEnabled { return }
            guard let v = video, v.pid == info.pid else { droppedPES += 1; return }
            let (pts, dts) = unwrapTimestamps(pes)
            v.feed(pes.payload, pts: pts, dts: dts)
        case .audio:
            guard let a = audio, a.pid == info.pid else { droppedPES += 1; return }
            if a.streamType == 0x0F, let mode = AACChannelMode.detect(adts: pes.payload) {
                observeChannelMode(mode == .dualMono)
            }
            let (pts, dts) = unwrapTimestamps(pes)
            a.feed(pes.payload, pts: pts, dts: dts)
        case .caption:
            let languages = captions.languages
            let changed = captions.feed(pes.payload)
            if captions.languages != languages {
                let l = captions.languages
                main { $0.onCaptionLanguages?(l) }
            }
            guard changed else { return }
            enqueueCaption(pes, superimpose: false, captions.frame)
        case .superimpose:
            guard superimpose.feed(pes.payload) else { return }
            enqueueCaption(pes, superimpose: true, superimpose.frame)
        }
    }

    private func unwrapTimestamps(_ pes: PESPacket) -> (Int64?, Int64?) {
        let pts = pes.pts.map { unwrap.ticks($0) }
        return (pts, pes.dts.map { unwrap.peek($0) })
    }

    // MARK: - Dual mono

    private func observeChannelMode(_ isDual: Bool) {
        guard isDual != status.isDualMono else { dualMonoVotes = 0; return }
        dualMonoVotes += 1
        if dualMonoVotes >= Self.dualMonoVotesNeeded { setDualMonoDetected(isDual) }
    }

    private func setDualMonoDetected(_ value: Bool) {
        dualMonoVotes = 0
        let changed = status.isDualMono != value
        status.isDualMono = value
        applyDualMono()
        if changed {
            let s = status
            main { $0.onStatus?(s) }
        }
    }

    /// The 主/副 choice only applies to dual-mono audio; ordinary stereo is always played as is.
    private func applyDualMono() {
        audio?.setDualMonoMode(status.isDualMono ? dualMono : .both)
    }

    private func enqueueCaption(_ pes: PESPacket, superimpose: Bool, _ frame: CaptionFrame) {
        // No PTS (asynchronous PES, usual for superimpose) → show as soon as possible.
        let t = pes.pts.map { Double(unwrap.peek($0)) / 90000 } ?? -.infinity
        pendingCaptions.append((t, superimpose, frame))
        if pendingCaptions.count > 64 { pendingCaptions.removeFirst(pendingCaptions.count - 64) }
    }

    // MARK: - Captions

    public func selectCaptionLanguage(index: Int) {
        queue.async { [self] in
            captionLanguage = index
            captions.languageIndex = index
            pendingCaptions.removeAll { !$0.superimpose }
            shownCaption = CaptionFrame()
            main { $0.onCaption?(CaptionFrame()) }
        }
    }

    private func resetCaptions() {
        captions.reset()
        superimpose.reset()
        captions.languageIndex = captionLanguage
        pendingCaptions.removeAll()
        main { $0.onCaptionLanguages?([]) }
        if shownCaption != CaptionFrame() {
            shownCaption = CaptionFrame()
            main { $0.onCaption?(CaptionFrame()) }
        }
        if shownSuperimpose != CaptionFrame() {
            shownSuperimpose = CaptionFrame()
            main { $0.onSuperimpose?(CaptionFrame()) }
        }
    }

    /// Hands captions whose time has come to the main queue. Called after every input chunk.
    private func deliverCaptions() {
        guard !pendingCaptions.isEmpty, let clock = presenter.clockSeconds else { return }
        var caption: CaptionFrame?, sup: CaptionFrame?
        // Per plane, deliver the due prefix (latest state wins); the planes don't block each other.
        // > 10 s ahead: bogus PTS, show now.
        var blocked = (caption: false, superimpose: false)
        pendingCaptions.removeAll { e in
            let isBlocked = e.superimpose ? blocked.superimpose : blocked.caption
            guard !isBlocked, e.time <= clock || e.time > clock + 10 else {
                if e.superimpose { blocked.superimpose = true } else { blocked.caption = true }
                return false
            }
            if e.superimpose { sup = e.frame } else { caption = e.frame }
            return true
        }
        if let caption, caption != shownCaption {
            shownCaption = caption
            main { $0.onCaption?(caption) }
        }
        if let sup, sup != shownSuperimpose {
            shownSuperimpose = sup
            main { $0.onSuperimpose?(sup) }
        }
    }

    private func presentVideo(_ pb: CVPixelBuffer, _ pts: Int64?) {
        guard let pts else { return }
        presenter.enqueueVideo(pb, seconds: Double(pts) / 90000) // already unwrapped
    }

    private func presentAudio(_ s: UnsafePointer<Float>, _ frames: Int, _ ch: Int, _ rate: Int, _ pts: Int64?) {
        guard let pts else { return }
        presenter.enqueueAudio(s, frames: frames, channels: ch, sampleRate: rate, seconds: Double(pts) / 90000)
    }

    private func tickStatus() {
        let now = Date()
        let dt = now.timeIntervalSince(windowStart)
        guard dt >= 1 else { return }
        let st = demuxer.stats
        status.bitrateMbps = Double(bytesWindow) * 8 / dt / 1_000_000
        status.packets = st.packets
        status.errorPackets = st.errorPackets
        status.continuityErrors = st.continuityErrors
        status.scrambledPackets = st.scrambledPackets
        if st.scrambledSelectedPackets < lastScrambledSelected { lastScrambledSelected = 0 }
        status.isScrambled = st.scrambledSelectedPackets - lastScrambledSelected > 0
        lastScrambledSelected = st.scrambledSelectedPackets
        status.droppedPES = droppedPES
        status.bufferedSeconds = presenter.bufferedSeconds
        bytesWindow = 0
        windowStart = now
        let s = status
        main { $0.onStatus?(s) }
    }
}
