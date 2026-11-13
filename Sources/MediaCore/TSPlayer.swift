import CoreVideo
import Foundation
import TSCore

/// Unwraps 33-bit 90 kHz timestamps into a monotonic timeline (seconds).
struct PTSUnwrapper {
    private var offset: Int64 = 0
    private var last: Int64?
    private static let wrap: Int64 = 1 << 33

    mutating func reset() { offset = 0; last = nil }

    mutating func seconds(_ raw: Int64) -> Double {
        var v = (raw & (Self.wrap - 1)) + offset
        if let l = last {
            if v - l < -(Self.wrap / 2) { offset += Self.wrap; v += Self.wrap }
            else if v - l > Self.wrap / 2 { offset -= Self.wrap; v -= Self.wrap }
        }
        last = v
        return Double(v) / 90000.0
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

    public init() {}
}

/// TS → demux → decode → present. All processing happens on `queue`; callbacks are
/// delivered on the main queue.
public final class TSPlayer: @unchecked Sendable {
    public let presenter = AVPresenter()

    public var onServicesChanged: (([ServiceInfo]) -> Void)?
    public var onSelectionChanged: ((StreamSelection?) -> Void)?
    public var onEventChanged: ((EventInfo?, EventInfo?) -> Void)?
    public var onTime: ((Date) -> Void)?
    public var onStatus: ((PlayerStatus) -> Void)?
    public var onVideoSizeChanged: ((CGSize) -> Void)?
    /// Caption lines to show now (top to bottom; empty = nothing). Timed against the presenter clock.
    public var onCaption: (([String]) -> Void)?

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
    /// Decoded caption states waiting for their presentation time.
    private var pendingCaptions: [(time: Double, lines: [String])] = []
    private var shownCaption: [String] = []
    private var captionPID: UInt16?

    // Options (read on the player queue).
    private var hardwareDecoding = true
    private var deinterlace = true
    private var dualMono: DualMonoMode = .both

    public init() {
        demuxer.onServicesChanged = { [weak self] s in self?.main { $0.onServicesChanged?(s) } }
        demuxer.onEventChanged = { [weak self] p, f in self?.main { $0.onEventChanged?(p, f) } }
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
            status = PlayerStatus()
        }
    }

    public func stop() {
        queue.async { [self] in
            demuxer.reset()
            video = nil
            audio = nil
            unwrap.reset()
            presenter.clear()
            resetCaptions()
            status = PlayerStatus()
            let s = status
            main { $0.onStatus?(s) }
        }
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
            audio?.setDualMonoMode(mode)
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

    public func setDeinterlace(_ on: Bool) {
        queue.async { [self] in
            guard deinterlace != on else { return }
            deinterlace = on
            video = nil
            if let sel = demuxer.selection { makeDecoders(sel) }
        }
    }

    // MARK: - Pipeline

    private func selectionChanged(_ sel: StreamSelection?) {
        if let sel { makeDecoders(sel) } else { video = nil; audio = nil; captionPID = nil; resetCaptions() }
        main { $0.onSelectionChanged?(sel) }
    }

    private func makeDecoders(_ sel: StreamSelection) {
        if sel.caption?.pid != captionPID {
            captionPID = sel.caption?.pid
            resetCaptions()
        }
        var flushed = false
        if let v = sel.video {
            if video?.pid != v.pid || video?.streamType != v.streamType {
                video = MediaDecoder(streamType: v.streamType, pid: v.pid, hardware: hardwareDecoding, deinterlace: deinterlace)
                video?.onVideo = { [weak self] pb, pts in self?.presentVideo(pb, pts) }
                flushed = true
            }
        } else {
            video = nil
        }
        if let a = sel.audio {
            if audio?.pid != a.pid || audio?.streamType != a.streamType {
                audio = MediaDecoder(streamType: a.streamType, pid: a.pid, hardware: false, deinterlace: false)
                audio?.setDualMonoMode(dualMono)
                audio?.onAudio = { [weak self] s, f, c, r, pts in self?.presentAudio(s, f, c, r, pts) }
                flushed = true
            }
        } else {
            audio = nil
        }
        presenter.setExpectsAudio(audio != nil)
        if flushed { presenter.flush() }
        status.videoCodec = video?.description ?? (sel.video.map { "\($0.codecName) (未対応)" } ?? "")
        status.audioCodec = audio?.description ?? ""
    }

    private func handlePES(_ track: TSDemuxer.Track, _ info: ElementaryStreamInfo, _ pes: PESPacket) {
        switch track {
        case .video:
            guard let v = video, v.pid == info.pid else { droppedPES += 1; return }
            v.feed(pes.payload, pts: pes.pts, dts: pes.dts)
        case .audio:
            guard let a = audio, a.pid == info.pid else { droppedPES += 1; return }
            a.feed(pes.payload, pts: pes.pts, dts: pes.dts)
        case .caption:
            guard captions.feed(pes.payload) else { return }
            // No PTS (asynchronous PES) → show as soon as possible.
            let t = pes.pts.map { unwrap.seconds($0) } ?? -.infinity
            pendingCaptions.append((t, captions.screen.lines))
            if pendingCaptions.count > 64 { pendingCaptions.removeFirst(pendingCaptions.count - 64) }
        }
    }

    // MARK: - Captions

    private func resetCaptions() {
        captions.reset()
        pendingCaptions.removeAll()
        if !shownCaption.isEmpty {
            shownCaption = []
            main { $0.onCaption?([]) }
        }
    }

    /// Hands captions whose time has come to the main queue. Called after every input chunk.
    private func deliverCaptions() {
        guard !pendingCaptions.isEmpty, let clock = presenter.clockSeconds else { return }
        var latest: [String]?
        while let first = pendingCaptions.first,
              first.time <= clock || first.time > clock + 10 { // > 10 s ahead: bogus PTS, show now
            latest = first.lines
            pendingCaptions.removeFirst()
        }
        guard let latest, latest != shownCaption else { return }
        shownCaption = latest
        main { $0.onCaption?(latest) }
    }

    private func presentVideo(_ pb: CVPixelBuffer, _ pts: Int64?) {
        guard let pts else { return }
        presenter.enqueueVideo(pb, seconds: unwrap.seconds(pts))
    }

    private func presentAudio(_ s: UnsafePointer<Float>, _ frames: Int, _ ch: Int, _ rate: Int, _ pts: Int64?) {
        guard let pts else { return }
        presenter.enqueueAudio(s, frames: frames, channels: ch, sampleRate: rate, seconds: unwrap.seconds(pts))
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
