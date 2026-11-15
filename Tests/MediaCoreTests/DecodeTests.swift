import CoreVideo
import Foundation
import Testing
@testable import MediaCore
import TSCore

/// Generates broadcast-like TS with the ffmpeg CLI (skipped when ffmpeg is not installed) and
/// runs it through demux + decode.
@Suite(.serialized) struct DecodeTests {
    /// `FFMPEG_CLI` overrides the Homebrew locations (the CLI only generates test streams).
    static let ffmpeg = [ProcessInfo.processInfo.environment["FFMPEG_CLI"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }

    static func makeTS(_ name: String, _ args: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bonview-\(name).ts")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg!)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args + ["-f", "mpegts", url.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return url
    }

    /// FFmpeg built without GPL parts has no libx264; the VideoToolbox encoder works as well here.
    static func hasEncoder(_ name: String) -> Bool {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: ffmpeg!)
        p.arguments = ["-hide_banner", "-encoders"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.contains(" \(name) ")
    }

    struct Result {
        var frames = 0
        var size = CGSize.zero
        var par: (Int, Int)?
        var audioFrames = 0
        var audioRate = 0
        var audioMissingPTS = 0
        var audioGaps = 0
        var nextAudioPTS: Int64?
        var firstVideoPTS: Int64?
        var lastVideoPTS: Int64?
        var videoCodec = ""
        var pixelFormat: OSType = 0
        var matrix: String?
        /// Held pictures (like the display layer's queue) whose content changed after delivery.
        var overwrittenFrames = 0
    }

    /// Sparse luma checksum, enough to tell pictures of a moving test pattern apart.
    static func checksum(_ pb: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        var sum: UInt64 = 0
        for y in Swift.stride(from: 0, to: h, by: 17) {
            for x in Swift.stride(from: 0, to: w, by: 11) { sum = sum &* 31 &+ UInt64(base[y * stride + x]) }
        }
        return sum
    }

    static func decode(_ url: URL, hardware: Bool, deinterlace: DeinterlaceMode, gpu: Bool = false) throws -> Result {
        let data = try Data(contentsOf: url)
        let demux = TSDemuxer()
        var video: MediaDecoder?
        var audio: MediaDecoder?
        var r = Result()
        // Keep the latest pictures alive for a while, as the presenter's display queue does.
        var held: [(CVPixelBuffer, UInt64)] = []
        demux.onSelectionChanged = { sel in
            guard let sel else { return }
            if let v = sel.video {
                video = MediaDecoder(streamType: v.streamType, pid: v.pid, hardware: hardware, deinterlace: deinterlace, gpuDeinterlace: gpu)
                video?.onVideo = { pb, pts in
                    r.frames += 1
                    r.size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
                    if let d = CVBufferCopyAttachment(pb, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Int] {
                        r.par = (d[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] ?? 0,
                                 d[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] ?? 0)
                    }
                    held.append((pb, Self.checksum(pb)))
                    if held.count > 60 {
                        let (old, sum) = held.removeFirst()
                        if Self.checksum(old) != sum { r.overwrittenFrames += 1 }
                    }
                    r.pixelFormat = CVPixelBufferGetPixelFormatType(pb)
                    r.matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
                    if r.firstVideoPTS == nil { r.firstVideoPTS = pts }
                    r.lastVideoPTS = pts
                }
                r.videoCodec = video?.description ?? ""
            }
            if let a = sel.audio {
                audio = MediaDecoder(streamType: a.streamType, pid: a.pid, hardware: false, deinterlace: .off)
                audio?.onAudio = { _, frames, ch, rate, pts in
                    #expect(ch == 2)
                    if let pts {
                        if let n = r.nextAudioPTS, abs(pts - n) > 90 { r.audioGaps += 1 }
                        r.nextAudioPTS = pts + Int64(frames) * 90000 / Int64(rate)
                    } else {
                        r.audioMissingPTS += 1
                    }
                    r.audioFrames += frames
                    r.audioRate = rate
                }
            }
        }
        demux.onPES = { track, _, pes in
            switch track {
            case .video: video?.feed(pes.payload, pts: pes.pts, dts: pes.dts)
            case .audio: audio?.feed(pes.payload, pts: pes.pts, dts: pes.dts)
            case .caption, .superimpose: break
            }
        }
        var i = 0
        while i < data.count {
            let n = min(188 * 100, data.count - i)
            demux.feed(data.subdata(in: i..<(i + n)))
            i += n
        }
        if let video { r.videoCodec = video.description } // names the deinterlacer once it ran
        r.overwrittenFrames += held.filter { Self.checksum($0.0) != $0.1 }.count
        return r
    }

    @Test(.enabled(if: ffmpeg != nil)) func mpeg2InterlacedDeinterlacedToFieldRate() throws {
        let url = try Self.makeTS("mpeg2i", [
            "-f", "lavfi", "-i", "testsrc2=size=1440x1080:rate=30000/1001",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3",
            "-vf", "setsar=4/3,setfield=tff", "-c:v", "mpeg2video", "-b:v", "12M", "-flags", "+ilme+ildct",
            "-c:a", "aac", "-ac", "2",
        ])
        let r = try Self.decode(url, hardware: true, deinterlace: .fieldRate)
        #expect(r.videoCodec.hasPrefix("mpeg2video"))
        #expect(r.size == CGSize(width: 1440, height: 1080))
        #expect(r.par.map { $0.0 * 3 == $0.1 * 4 } == true, "PAR \(String(describing: r.par))")
        // 3 s at 29.97 fps → ~180 fields after bwdif send_field (minus decoder/parser tail)
        #expect(r.frames > 150, "frames: \(r.frames)")
        if let a = r.firstVideoPTS, let b = r.lastVideoPTS {
            let fps = Double(r.frames - 1) / (Double(b - a) / 90000)
            #expect(abs(fps - 59.94) < 1, "fps \(fps)")
        }
        #expect(r.audioRate == 48000)
        #expect(r.audioFrames > 48000 * 2)
        // ffmpeg (like broadcasters) packs several AAC frames into one PES; every frame needs a PTS.
        #expect(r.audioMissingPTS == 0)
        #expect(r.audioGaps == 0)
    }

    @Test(.enabled(if: ffmpeg != nil)) func mpeg2InterlacedDeinterlacedToFrameRate() throws {
        let url = try Self.makeTS("mpeg2i-30p", [
            "-f", "lavfi", "-i", "testsrc2=size=1440x1080:rate=30000/1001", "-t", "3",
            "-vf", "setsar=4/3,setfield=tff", "-c:v", "mpeg2video", "-b:v", "12M", "-flags", "+ilme+ildct",
        ])
        let r = try Self.decode(url, hardware: true, deinterlace: .frameRate)
        #expect(r.size == CGSize(width: 1440, height: 1080))
        // bwdif send_frame: one picture per frame (~90 in 3 s), not one per field.
        #expect(r.frames > 75 && r.frames < 100, "frames: \(r.frames)")
        if let a = r.firstVideoPTS, let b = r.lastVideoPTS {
            let fps = Double(r.frames - 1) / (Double(b - a) / 90000)
            #expect(abs(fps - 29.97) < 1, "fps \(fps)")
        }
    }

    static func interlacedMPEG2() throws -> URL {
        try makeTS("mpeg2i-video", [
            "-f", "lavfi", "-i", "testsrc2=size=1440x1080:rate=30000/1001", "-t", "3",
            "-vf", "setsar=4/3,setfield=tff", "-c:v", "mpeg2video", "-b:v", "12M", "-flags", "+ilme+ildct",
        ])
    }

    @Test(.enabled(if: ffmpeg != nil && DeinterlaceMode.gpuAvailable), arguments: [DeinterlaceMode.fieldRate, .frameRate])
    func mpeg2DeinterlacedWithMetal(_ mode: DeinterlaceMode) throws {
        let r = try Self.decode(try Self.interlacedMPEG2(), hardware: true, deinterlace: mode, gpu: true)
        #expect(r.videoCodec.hasSuffix("+ yadif (Metal)"), "\(r.videoCodec)")
        #expect(r.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(r.size == CGSize(width: 1440, height: 1080))
        #expect(r.par.map { $0.0 * 3 == $0.1 * 4 } == true, "PAR \(String(describing: r.par))")
        #expect(r.matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
        // Pictures must not be recycled while still held downstream (FFmpeg's VideoToolbox pool does).
        #expect(r.overwrittenFrames == 0, "overwritten: \(r.overwrittenFrames)")
        let expected = mode == .fieldRate ? 59.94 : 29.97
        #expect(Double(r.frames) > expected * 3 * 0.8, "frames: \(r.frames)")
        if let a = r.firstVideoPTS, let b = r.lastVideoPTS {
            let fps = Double(r.frames - 1) / (Double(b - a) / 90000)
            #expect(abs(fps - expected) < 1, "fps \(fps)")
        }
    }

    @Test(.enabled(if: ffmpeg != nil)) func mpeg2CPUDeinterlaceWhenGPUOff() throws {
        let r = try Self.decode(try Self.interlacedMPEG2(), hardware: true, deinterlace: .fieldRate, gpu: false)
        #expect(r.videoCodec.hasSuffix("+ bwdif"), "\(r.videoCodec)")
        #expect(r.overwrittenFrames == 0, "overwritten: \(r.overwrittenFrames)")
    }

    @Test(.enabled(if: ffmpeg != nil)) func h264ViaVideoToolbox() throws {
        let url = try Self.makeTS("h264", [
            "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30000/1001",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-t", "3",
            "-c:v", Self.hasEncoder("libx264") ? "libx264" : "h264_videotoolbox", "-pix_fmt", "yuv420p", "-c:a", "aac",
        ])
        let r = try Self.decode(url, hardware: true, deinterlace: .fieldRate)
        #expect(r.videoCodec == "h264 (VideoToolbox)")
        #expect(r.size == CGSize(width: 1920, height: 1080))
        #expect(r.frames > 80, "frames: \(r.frames)")
    }

    @Test func ptsUnwrap() {
        var u = PTSUnwrapper()
        let wrap: Int64 = 1 << 33
        let a = u.seconds(wrap - 90000)
        let b = u.seconds(45000) // crossed the 33-bit wrap
        #expect(abs((b - a) - 1.5) < 1e-9)
    }
}
