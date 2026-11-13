import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import MediaCore

struct FrameHistoryTests {
    @Test func picksFrameDueAtClockAndPrunesOlder() {
        var h = FrameHistory<Int>()
        h.append(1, seconds: 10.0, clock: 9.5)
        h.append(2, seconds: 10.1, clock: 9.6)
        h.append(3, seconds: 10.2, clock: 10.15)
        // Frame 1 is older than frame 2 (on screen at 10.15) and is dropped.
        #expect(h.entries.map(\.frame) == [2, 3])
        #expect(h.current(clock: 10.15) == 2)
        #expect(h.current(clock: 10.25) == 3)
        // Nothing due yet: the oldest frame is the best guess.
        #expect(h.current(clock: 5) == 2)
    }

    @Test func flushKeepsOnlyDisplayedFrame() {
        var h = FrameHistory<Int>()
        for i in 0..<5 { h.append(i, seconds: Double(i), clock: 0) }
        h.keepCurrent(clock: 2.5)
        #expect(h.entries.map(\.frame) == [2])
        // After a flush the clock is stopped (nil): the frozen picture is returned.
        #expect(h.current(clock: nil) == 2)
        // A new, earlier timeline (channel change) replaces it once its frames come due.
        h.append(10, seconds: 0.1, clock: 0.2)
        #expect(h.current(clock: 0.2) == 10)
        #expect(h.entries.map(\.frame) == [10])
    }

    @Test func boundedWhenClockStalls() {
        var h = FrameHistory<Int>()
        h.limit = 10
        for i in 0..<50 { h.append(i, seconds: Double(i), clock: -1) }
        #expect(h.entries.count == 10)
        #expect(h.entries.first?.frame == 40)
    }
}

struct FrameSnapshotTests {
    /// 1440×1080 NV12 with SAR 4:3 becomes a 1920×1080 image.
    @Test func appliesPixelAspectRatio() throws {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, 1440, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            memset(base, plane == 0 ? 180 : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let par: [CFString: Any] = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 4,
                                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: 3]
        CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, par as CFDictionary, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        let image = try #require(FrameSnapshot.cgImage(from: buffer))
        #expect(image.width == 1920)
        #expect(image.height == 1080)

        for format in FrameSnapshot.Format.allCases {
            let data = try #require(FrameSnapshot.encode(image, as: format))
            let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            #expect(props[kCGImagePropertyPixelWidth] as? Int == 1920)
            #expect(props[kCGImagePropertyPixelHeight] as? Int == 1080)
        }
    }

    @Test func squarePixelsUnchanged() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        let buffer = try #require(pb)
        let image = try #require(FrameSnapshot.cgImage(from: buffer))
        #expect(image.width == 1280 && image.height == 720)
    }
}
