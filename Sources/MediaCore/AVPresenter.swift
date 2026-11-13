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
    public var latency: Double = 0.4
    /// If more than this is buffered ahead of the clock, skip forward.
    public var maxBuffered: Double = 2.5

    private let lock = NSLock()
    private var anchored = false
    private var hasAudio = false
    private var lastAudioEnd: Double?
    private var audioFormat: CMAudioFormatDescription?
    private var audioFormatKey: (Int, Int) = (0, 0)
    private var videoFormat: CMVideoFormatDescription?
    private var frames = FrameHistory<CVPixelBuffer>()

    public private(set) var videoDisplaySize: CGSize = .zero
    public var onVideoSizeChanged: ((CGSize) -> Void)?

    public init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

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
        synchronizer.setRate(1, time: CMTime(seconds: t - latency, preferredTimescale: 90000))
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
                if size != videoDisplaySize {
                    videoDisplaySize = size
                    onVideoSizeChanged?(size)
                }
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
            if end < clock {
                // Underrun: the clock overtook our data (network stall). Re-buffer from here.
                anchored = false
            } else if t - clock > maxBuffered + latency {
                // Too far ahead (sender clock faster than ours / burst). Jump forward.
                anchored = false
            }
            if !anchored {
                lock.unlock()
                synchronizer.setRate(0, time: .zero)
                audioRenderer.flush()
                lock.lock()
            }
        }
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
