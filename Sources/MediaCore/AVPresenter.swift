import AVFoundation
import CoreMedia
import Foundation

/// Presents decoded video/audio in sync using AVSampleBufferRenderSynchronizer.
///
/// The synchronizer's timebase runs in stream PTS (seconds). It is anchored to the first
/// sample (audio preferred) minus `latency`, and re-anchored when the live buffer underruns
/// or grows too large (source/clock drift, network stalls).
public final class AVPresenter: @unchecked Sendable {
    public let displayLayer = AVSampleBufferDisplayLayer()
    public let audioRenderer = AVSampleBufferAudioRenderer()
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
    private var lastAudioEnd: Double?
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
        // The system flushes the audio renderer itself on output route changes (AirPlay, headphones)
        // and interruptions. Re-anchor so the clock does not run on without audio.
        flushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: audioRenderer, queue: nil
        ) { [weak self] n in
            let time = (n.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            self?.automaticallyFlushed(at: time)
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

    /// An automatic flush. AirPlay reports these late and also after our own flush / rate change
    /// (channel change): re-anchoring for those flushed again and could loop, leaving the audio
    /// silent. Ignore flushes from before the current anchor, and re-anchor at most once every few
    /// seconds; audio enqueued afterwards plays anyway, a skipped re-anchor only costs a short gap.
    private func automaticallyFlushed(at time: CMTime?) {
        lock.lock(); defer { lock.unlock() }
        guard anchored else { return }
        if let time, time.isNumeric, let start = anchorTime, time.seconds < start - 0.1 { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if let last = lastAutoReanchor, uptime - last < Self.autoReanchorInterval { return }
        lastAutoReanchor = uptime
        needsReanchor = true
    }

    private static let autoReanchorInterval: TimeInterval = 5
    /// Media time the clock started from at the last anchor.
    private var anchorTime: Double?
    private var lastAutoReanchor: TimeInterval?

    public var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = newValue }
    }

    public var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue }
    }

    /// Whether the current stream has an audio track (anchoring waits for audio if so).
    public func setExpectsAudio(_ value: Bool) {
        lock.lock(); hasAudio = value; lock.unlock()
    }

    /// Drop everything queued and stop the clock (channel change / discontinuity).
    public func flush() {
        lock.lock()
        frames.keepCurrent(clock: anchored ? now : nil)
        anchored = false
        needsReanchor = false
        lastAudioEnd = nil
        lock.unlock()
        synchronizer.setRate(0, time: .zero)
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        audioRenderer.flush()
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
        return anchored ? now : nil
    }

    private func anchorIfNeeded(at t: Double, isAudio: Bool) {
        if anchored { return }
        if hasAudio && !isAudio { return }
        anchored = true
        anchorTime = t - _latency
        synchronizer.setRate(1, time: CMTime(seconds: t - _latency, preferredTimescale: 90000))
    }

    // MARK: - Video

    /// `seconds`: unwrapped stream time.
    public func enqueueVideo(_ pb: CVPixelBuffer, seconds t: Double) {
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
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 90000),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        lock.lock()
        var jumped = false
        if anchored && !hasAudio {
            // Video-only stream: nothing else re-anchors, so handle underrun / overrun / jumps here.
            let clock = now
            if t < clock || t - clock > _maxBuffered + _latency {
                anchored = false
                jumped = abs(t - clock) > 1.0
                if jumped { frames.keepCurrent(clock: clock) }
            }
        }
        if !anchored && jumped {
            lock.unlock()
            synchronizer.setRate(0, time: .zero)
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
            lock.lock()
        }
        anchorIfNeeded(at: t, isAudio: false)
        let ok = anchored
        if ok { frames.append(pb, seconds: t, clock: now) }
        lock.unlock()
        if ok {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sb)
        }
    }

    // MARK: - Audio

    public func enqueueAudio(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Int, seconds t: Double) {
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

        let end = t + Double(frames) / Double(sampleRate)
        lock.lock()
        if anchored {
            let clock = now
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
                if jumped { self.frames.keepCurrent(clock: clock) }
                lock.unlock()
                synchronizer.setRate(0, time: .zero)
                audioRenderer.flush()
                if jumped { displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil) }
                lock.lock()
            }
        }
        needsReanchor = false
        anchorIfNeeded(at: t, isAudio: true)
        lastAudioEnd = end
        lock.unlock()
        if audioRenderer.status == .failed { audioRenderer.flush() }
        audioRenderer.enqueue(sb)
    }

    /// Seconds of audio queued ahead of the clock (for the status bar).
    public var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard anchored, let e = lastAudioEnd else { return 0 }
        return max(0, e - now)
    }
}
