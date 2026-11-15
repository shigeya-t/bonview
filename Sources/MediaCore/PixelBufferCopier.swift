import CoreVideo
import Foundation
import Metal

/// Copies NV12 pixel buffers on the GPU (Metal blit) into buffers of its own CVPixelBufferPool.
///
/// The Metal deinterlacer's output comes from FFmpeg's VideoToolbox frame pool, which reuses a
/// buffer as soon as FFmpeg lets go of it, even while the display layer still has it queued.
/// A CVPixelBufferPool only reuses buffers nobody retains, so copies are safe to keep.
final class PixelBufferCopier {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType) = (0, 0, 0)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.device = device
        self.queue = queue
        self.cache = cache
    }

    /// A copy of `src` (8-bit NV12, video or full range) with its attachments, or nil.
    func copy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(src)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              let dst = makeBuffer(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src), format: format)
        else { return nil }
        let ok = autoreleasepool { () -> Bool in
            guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return false }
            // The CVMetalTextures must outlive the command buffer.
            var keep: [CVMetalTexture] = []
            for (plane, pixelFormat) in [(0, MTLPixelFormat.r8Unorm), (1, .rg8Unorm)] {
                guard let s = texture(src, plane: plane, pixelFormat), let d = texture(dst, plane: plane, pixelFormat),
                      let st = CVMetalTextureGetTexture(s), let dt = CVMetalTextureGetTexture(d) else {
                    blit.endEncoding()
                    return false
                }
                keep += [s, d]
                blit.copy(from: st, to: dt)
            }
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            withExtendedLifetime(keep) {}
            return cmd.status == .completed
        }
        guard ok else { return nil }
        CVBufferPropagateAttachments(src, dst)
        return dst
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, _ format: MTLPixelFormat) -> CVMetalTexture? {
        var tex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format,
                                                          CVPixelBufferGetWidthOfPlane(pb, plane),
                                                          CVPixelBufferGetHeightOfPlane(pb, plane), plane, &tex)
        return r == kCVReturnSuccess ? tex : nil
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if pool == nil || poolKey != (width, height, format) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolKey = (width, height, format)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        return CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess ? pb : nil
    }
}
