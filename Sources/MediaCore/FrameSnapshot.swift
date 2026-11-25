import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Recently enqueued video frames, so the one on screen can be captured.
///
/// The display layer queues frames ahead of the clock and offers no way to read back the
/// picture it shows. We keep references to the same pixel buffers (the renderer holds the
/// queued ones anyway) and drop everything older than the newest frame due at the clock, so
/// at most one extra frame is retained.
struct FrameHistory<Frame> {
    private(set) var entries: [(seconds: Double, frame: Frame)] = []
    /// Safety bound in case the clock stops advancing while frames keep coming. Frames are only
    /// added while the clock runs and at most `AVPresenter.maxBuffered + latency` (≈ 3 s) ahead,
    /// i.e. about 180 at 59.94 fps; a 1080 NV12 frame is 3 MB, so don't keep many more.
    var limit = 240

    mutating func append(_ frame: Frame, seconds t: Double, clock: Double?) {
        entries.append((t, frame))
        prune(clock: clock)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// The frame shown at `clock` (nil: not running, i.e. the frozen picture after a flush).
    func current(clock: Double?) -> Frame? {
        currentIndex(clock: clock).map { entries[$0].frame }
    }

    /// Keep only the frame on screen (flush keeps the displayed image).
    mutating func keepCurrent(clock: Double?) {
        if let i = currentIndex(clock: clock) { entries = [entries[i]] }
    }

    private func currentIndex(clock: Double?) -> Int? {
        guard !entries.isEmpty else { return nil }
        guard let clock else { return entries.count - 1 }
        return entries.lastIndex(where: { $0.seconds <= clock }) ?? 0
    }

    mutating func removeAll() { entries.removeAll() }

    private mutating func prune(clock: Double?) {
        guard let clock, let i = entries.lastIndex(where: { $0.seconds <= clock }), i > 0 else { return }
        entries.removeFirst(i)
    }
}

/// Converts decoded pictures to still images.
public enum FrameSnapshot {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// RGB image at the display size: clean aperture (e.g. 1920×1088 → 1920×1080) and pixel
    /// aspect ratio (e.g. 1440×1080 → 1920×1080) applied.
    public static func cgImage(from pb: CVPixelBuffer) -> CGImage? {
        let crop = visibleRect(pb)
        var image = CIImage(cvPixelBuffer: pb).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let size = displaySize(pb)
        if size.width != crop.width {
            // Clamp first so linear sampling does not fade the left and right edges.
            image = image.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: size.width / crop.width, y: 1))
                .samplingLinear()
        }
        return context.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Output size of `cgImage(from:)`.
    static func displaySize(_ pb: CVPixelBuffer) -> CGSize {
        let crop = visibleRect(pb)
        let width = min((crop.width * pixelAspectRatio(pb)).rounded(), maxWidth)
        return CGSize(width: max(width, 1), height: crop.height)
    }

    /// Upper bound for the output width (a broken aspect ratio must not allocate a huge image).
    static let maxWidth: CGFloat = 8192

    /// The clean aperture in Core Image coordinates (origin bottom left), or the whole buffer.
    static func visibleRect(_ pb: CVPixelBuffer) -> CGRect {
        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        // Already bottom-left based, like Core Image (a 1920×1088 frame with offset -4 → y = 8).
        let clean = CVImageBufferGetCleanRect(pb).integral
        guard clean.width >= 1, clean.height >= 1, full.contains(clean) else { return full }
        return clean
    }

    /// Horizontal / vertical pixel spacing, limited to 1/4…4 (ISDB uses 4:3 and 1:1; anything
    /// outside that range is a broken stream).
    static func pixelAspectRatio(_ pb: CVPixelBuffer) -> CGFloat {
        guard let dict = CVBufferCopyAttachment(pb, kCVImageBufferPixelAspectRatioKey, nil) as? [CFString: Any],
              let hs = (dict[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? NSNumber)?.doubleValue,
              let vs = (dict[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? NSNumber)?.doubleValue,
              hs > 0, vs > 0, (hs / vs).isFinite else { return 1 }
        return CGFloat(min(max(hs / vs, 0.25), 4))
    }

    public enum Format: String, CaseIterable, Sendable {
        case png, jpeg

        public var fileExtension: String { self == .png ? "png" : "jpg" }
        var type: UTType { self == .png ? .png : .jpeg }
    }

    /// Encodes `image` as PNG / JPEG (quality 0.92).
    public static func encode(_ image: CGImage, as format: Format) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
