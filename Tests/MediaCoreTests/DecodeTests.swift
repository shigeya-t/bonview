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
        /// Video frames whose PTS did not move forward by less than a second.
        var videoJumps = 0
        var videoCodec = ""
    }

    /// Timestamps are unwrapped before decoding, as `TSPlayer` does.
    static func decode(_ url: URL, hardware: Bool, deinterlace: DeinterlaceMode) throws -> Result {
        let data = try Data(contentsOf: url)
        let demux = TSDemuxer()
        var unwrap = PTSUnwrapper()
        var video: MediaDecoder?
        var audio: MediaDecoder?
        var r = Result()
        demux.onSelectionChanged = { sel in
            guard let sel else { return }
            if let v = sel.video {
                video = MediaDecoder(streamType: v.streamType, pid: v.pid, hardware: hardware, deinterlace: deinterlace)
                video?.onVideo = { pb, pts in
                    r.frames += 1
                    r.size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
                    if let d = CVBufferCopyAttachment(pb, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Int] {
                        r.par = (d[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] ?? 0,
                                 d[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] ?? 0)
                    }
                    if r.firstVideoPTS == nil { r.firstVideoPTS = pts }
                    if let last = r.lastVideoPTS, let pts, !(pts > last && pts - last < 90000) { r.videoJumps += 1 }
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
            case .video: video?.feed(pes.payload, pts: pes.pts.map { unwrap.ticks($0) }, dts: pes.dts.map { unwrap.peek($0) })
            case .audio: audio?.feed(pes.payload, pts: pes.pts.map { unwrap.ticks($0) }, dts: pes.dts.map { unwrap.peek($0) })
            case .caption, .superimpose: break
            }
        }
        var i = 0
        while i < data.count {
            let n = min(188 * 100, data.count - i)
            demux.feed(data.subdata(in: i..<(i + n)))
            i += n
        }
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

    @Test(.enabled(if: ffmpeg != nil)) func timestampsAcross33BitWrap() throws {
        // Starts 0.3 s before the 33-bit PTS wrap (2^33 / 90 kHz ≈ 95443.7 s; the muxer adds 1.4 s).
        // bwdif's field times are interpolated between frames, which used to straddle the wrap.
        let url = try Self.makeTS("mpeg2wrap", [
            "-f", "lavfi", "-i", "testsrc2=size=720x480:rate=30000/1001",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2",
            "-vf", "setfield=tff", "-c:v", "mpeg2video", "-b:v", "4M", "-flags", "+ilme+ildct",
            "-c:a", "aac", "-ac", "2", "-output_ts_offset", "95442",
        ])
        let r = try Self.decode(url, hardware: false, deinterlace: .fieldRate)
        #expect(r.frames > 100, "frames: \(r.frames)")
        #expect(r.videoJumps == 0)
        #expect(r.audioGaps == 0)
        #expect((r.lastVideoPTS ?? 0) > PTSUnwrapper.wrap, "the stream crossed the wrap")
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
        let wrap = PTSUnwrapper.wrap
        let a = u.ticks(wrap - 90000)
        let b = u.ticks(45000) // crossed the 33-bit wrap
        #expect(b - a == 135000)
        // Reordered frames and a DTS just before the wrap stay on the same timeline.
        #expect(u.ticks(wrap - 3003) == wrap - 3003)
        #expect(u.peek(wrap - 6006) == wrap - 6006)
        #expect(u.ticks(48000) == wrap + 48000)
        // A bogus caption PTS half a wrap away does not move the timeline.
        _ = u.peek(wrap / 2 + 48000)
        #expect(u.ticks(51000) == wrap + 51000)
    }
}
