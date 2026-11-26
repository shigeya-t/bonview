import AVFoundation
import CoreMedia
import Foundation
import os

/// Presenter diagnostics (anchoring, flushes, renderer errors). `log stream --predicate 'subsystem == "BonView"'`.
let presenterLog = Logger(subsystem: "BonView", category: "presenter")

/// Presents decoded video/audio in sync using AVSampleBufferRenderSynchronizer.
///
/// The synchronizer's timebase runs in stream PTS (seconds) plus `offset`. It is anchored to the
/// first sample (audio preferred) minus `latency`, and re-anchored when the live buffer underruns
/// or grows too large (source/clock drift, network stalls).
///
/// The timebase never moves backwards: every channel has its own PTS clock, and an AirPlay
/// receiver stays silent after the presentation time jumps back (local outputs do not mind).
/// When a stream starts (or jumps) behind the timeline so far, `offset` moves it past that.
public final class AVPresenter: @unchecked Sendable {
    public let displayLayer = AVSampleBufferDisplayLayer()
    /// Replaced on every flush (see `flush`). Read under `lock` off the player queue.
    private var audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()

    /// Initial buffering for jitter absorption.
    public var latency: Double {
        get { lock.lock(); defer { lock.unlock() }; return _latency }
        set { lock.lock(); _latency = newValue; lock.unlock() }
    }
    /// If more than this is buffered ahead of the clock, skip forward.
    public var maxBuffered: Double {
        get { lock.lock(); defer { lock.unlock() }; return _maxBuffered }
        set { lock.lock(); _maxBuffered = newValue; lock.unlock() }
    }

    // The synchronizer's rate is only changed on the thread that enqueues samples (the player
    // queue); other threads only flag a re-anchor, so a stop cannot land after a new anchor.
    private let lock = NSLock()
    private var _latency = 0.4
    private var _maxBuffered = 2.5
    private var needsReanchor = false
    private var anchored = false
    private var hasAudio = false
    /// Below: presentation time (stream time + `offset`).
    private var lastAudioEnd: Double?
    /// Stream time → presentation time. Changes only while not anchored.
    private var offset = 0.0
    /// Latest presentation time handed to a renderer or reached by the clock.
    private var highWater = -Double.infinity
    private var audioFormat: CMAudioFormatDescription?
    private var audioFormatKey: (Int, Int) = (0, 0)
    private var videoFormat: CMVideoFormatDescription?
    private var frames = FrameHistory<CVPixelBuffer>()

    public var videoDisplaySize: CGSize {
        lock.lock(); defer { lock.unlock() }
        return _videoDisplaySize
    }
    private var _videoDisplaySize: CGSize = .zero
    public var onVideoSizeChanged: ((CGSize) -> Void)?

    public init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        observeFlushes(of: audioRenderer)
    }

    /// The system flushes the audio renderer itself on output route changes (AirPlay, headphones)
    /// and interruptions. Re-anchor so the clock does not run on without audio.
    private func observeFlushes(of renderer: AVSampleBufferAudioRenderer) {
        if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
        flushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil
        ) { [weak self] _ in
            presenterLog.info("audio renderer flushed automatically")
            self?.reanchor()
        }
    }

    deinit {
        if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
    }

    private var flushObserver: NSObjectProtocol?

    /// Stop the clock and wait for the next audio to anchor again (keeps the picture and queued
    /// video). Any thread: done by the next `enqueueAudio`.
    private func reanchor() {
        lock.lock(); needsReanchor = true; lock.unlock()
    }

    public var volume: Float {
        get { lock.lock(); defer { lock.unlock() }; return _volume }
        set { lock.lock(); _volume = newValue; let r = audioRenderer; lock.unlock(); r.volume = newValue }
    }

    public var isMuted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isMuted }
        set { lock.lock(); _isMuted = newValue; let r = audioRenderer; lock.unlock(); r.isMuted = newValue }
    }

    private var _volume: Float = 1
    private var _isMuted = false

    /// Whether the current stream has an audio track (anchoring waits for audio if so).
    public func setExpectsAudio(_ value: Bool) {
        lock.lock(); hasAudio = value; lock.unlock()
    }

    /// Stop the clock where it is (lock held). The time is kept: moving it back would silence AirPlay.
    private func stopClockLocked() {
        let clock = now
        if clock.isFinite { highWater = max(highWater, clock) }
        synchronizer.setRate(0, time: synchronizer.currentTime())
    }

    /// Drop everything queued and stop the clock (channel change / discontinuity).
    public func flush() {
        lock.lock()
        frames.keepCurrent(clock: anchored ? now : nil)
        anchored = false
        needsReanchor = false
        lastAudioEnd = nil
        stopClockLocked()
        presenterLog.info("flush at \(self.now, privacy: .public)")
        // A new audio renderer rather than a flushed one: over AirPlay a renderer flushed and fed
        // again right away (channel change) kept playing silence. A new one starts like at launch.
        let old = audioRenderer
        let renderer = AVSampleBufferAudioRenderer()
        renderer.volume = _volume
        renderer.isMuted = _isMuted
        audioRenderer = renderer
        lock.unlock()
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        old.flush()
        synchronizer.removeRenderer(old, at: synchronizer.currentTime(), completionHandler: nil)
        synchronizer.addRenderer(renderer)
        observeFlushes(of: renderer)
    }

    /// Clear the picture too (tuner closed).
    public func clear() {
        flush()
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        lock.lock(); frames.removeAll(); lock.unlock()
    }

    /// The picture on screen now (nil before the first frame / after `clear`).
    public func currentFrame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return frames.current(clock: anchored ? now : nil)
    }

    private var now: Double { synchronizer.currentTime().seconds }

    /// Current presentation time in stream seconds, or nil while not anchored (buffering).
    public var clockSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        return anchored ? now - offset : nil
    }

    /// Presentation time of stream time `t` (lock held). While not anchored, a stream behind the
    /// timeline so far is moved past it, so the next anchor does not take the clock backwards.
    private func presentationTime(_ t: Double) -> Double {
        if !anchored, t + offset < highWater + 0.1 {
            // The new anchor (t − latency) lands half a second after anything presented before.
            let target = highWater + _latency + 0.5
            presenterLog.info("timeline moved: stream \(t, privacy: .public) → \(target, privacy: .public)")
            offset = target - t
        }
        return t + offset
    }

    private func anchorIfNeeded(at t: Double, isAudio: Bool) {
        if anchored { return }
        if hasAudio && !isAudio { return }
        anchored = true
        presenterLog.info("anchor at \(t, privacy: .public) (\(isAudio ? "audio" : "video", privacy: .public), latency \(self._latency, privacy: .public))")
        synchronizer.setRate(1, time: CMTime(seconds: t - _latency, preferredTimescale: 90000))
    }

    // MARK: - Video

    /// `seconds`: unwrapped stream time.
    public func enqueueVideo(_ pb: CVPixelBuffer, seconds streamTime: Double) {
        if videoFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(videoFormat!, imageBuffer: pb) {
            var fmt: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
            videoFormat = fmt
            if let fmt {
                let size = CMVideoFormatDescriptionGetPresentationDimensions(fmt, usePixelAspectRatio: true, useCleanAperture: true)
                lock.lock()
                let changed = size != _videoDisplaySize
                _videoDisplaySize = size
                lock.unlock()
                if changed { onVideoSizeChanged?(size) }
            }
        }
        guard let fmt = videoFormat else { return }
        lock.lock()
        var jumped = false
        if anchored && !hasAudio {
            // Video-only stream: nothing else re-anchors, so handle underrun / overrun / jumps here.
            let clock = now
            let t = streamTime + offset
            if t < clock || t - clock > _maxBuffered + _latency {
                anchored = false
                jumped = abs(t - clock) > 1.0
                if jumped { frames.keepCurrent(clock: clock) }
                stopClockLocked()
            }
        }
        if jumped {
            lock.unlock()
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
            lock.lock()
        }
        // With audio, video waits for the audio anchor (and its offset).
        let t = !anchored && hasAudio ? streamTime + offset : presentationTime(streamTime)
        anchorIfNeeded(at: t, isAudio: false)
        let ok = anchored
        if ok {
            frames.append(pb, seconds: t, clock: now)
            if !hasAudio { highWater = max(highWater, t) }
        }
        lock.unlock()
        guard ok else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 90000),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sb)
    }

    // MARK: - Audio

    public func enqueueAudio(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Int, seconds streamTime: Double) {
        guard frames > 0 else { return }
        if audioFormat == nil || audioFormatKey != (sampleRate, channels) {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            var fmt: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
            audioFormat = fmt
            audioFormatKey = (sampleRate, channels)
        }
        guard let fmt = audioFormat else { return }
        let duration = Double(frames) / Double(sampleRate)

        lock.lock()
        if anchored {
            let clock = now
            let t = streamTime + offset
            let end = t + duration
            // A jump in the audio timeline (discontinuity not signalled by the source): video
            // queued for the old timeline would hold the picture until the clock got there.
            let jumped = lastAudioEnd.map { abs(t - $0) > 1.0 } ?? false
            if needsReanchor {
                // The system flushed the audio renderer (route change, interruption).
                anchored = false
            } else if end < clock {
                // Underrun: the clock overtook our data (network stall). Re-buffer from here.
                anchored = false
            } else if t - clock > _maxBuffered + _latency {
                // Too far ahead (sender clock faster than ours / burst). Jump forward.
                anchored = false
            }
            if !anchored {
                presenterLog.info("re-anchor: t=\(t, privacy: .public) clock=\(clock, privacy: .public) system flush=\(self.needsReanchor, privacy: .public) jumped=\(jumped, privacy: .public)")
                if jumped { self.frames.keepCurrent(clock: clock) }
                stopClockLocked()
                let r = audioRenderer
                lock.unlock()
                r.flush()
                if jumped { displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil) }
                lock.lock()
            }
        }
        needsReanchor = false
        let t = presentationTime(streamTime)
        anchorIfNeeded(at: t, isAudio: true)
        lastAudioEnd = t + duration
        highWater = max(highWater, t + duration)
        let renderer = audioRenderer
        lock.unlock()

        let bytes = frames * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return }
        CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 90000), packetDescriptions: nil, sampleBufferOut: &sb)
        guard let sb else { return }
        if renderer.status == .failed {
            presenterLog.error("audio renderer failed: \(String(describing: renderer.error), privacy: .public)")
            renderer.flush()
        }
        renderer.enqueue(sb)
    }

    /// Seconds of audio queued ahead of the clock (for the status bar).
    public var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard anchored, let e = lastAudioEnd else { return 0 }
        return max(0, e - now)
    }
}
