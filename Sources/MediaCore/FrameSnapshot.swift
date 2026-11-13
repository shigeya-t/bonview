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
    /// Safety bound in case the clock stops advancing while frames keep coming.
    var limit = 600

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

    /// RGB image at the display size (pixel aspect ratio applied, e.g. 1440×1080 → 1920×1080).
    public static func cgImage(from pb: CVPixelBuffer) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pb)
        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        let par = pixelAspectRatio(pb)
        if par != 1 {
            let target = (w * par).rounded()
            image = image.transformed(by: CGAffineTransform(scaleX: target / w, y: 1))
                .samplingLinear()
        }
        let rect = CGRect(x: 0, y: 0, width: (w * par).rounded(), height: h)
        return context.createCGImage(image, from: rect, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func pixelAspectRatio(_ pb: CVPixelBuffer) -> CGFloat {
        guard let dict = CVBufferCopyAttachment(pb, kCVImageBufferPixelAspectRatioKey, nil) as? [CFString: Any],
              let hs = (dict[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? NSNumber)?.doubleValue,
              let vs = (dict[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? NSNumber)?.doubleValue,
              hs > 0, vs > 0 else { return 1 }
        return CGFloat(hs / vs)
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
