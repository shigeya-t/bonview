import CoreVideo
import Foundation
import Testing
@testable import MediaCore
import TSCore

/// Generates broadcast-like TS with the ffmpeg CLI (skipped when ffmpeg is not installed) and
/// runs it through demux + decode.
@Suite(.serialized) struct DecodeTests {
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

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
    }

    static func decode(_ url: URL, hardware: Bool, deinterlace: Bool) throws -> Result {
        let data = try Data(contentsOf: url)
        let demux = TSDemuxer()
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
                    r.lastVideoPTS = pts
                }
                r.videoCodec = video?.description ?? ""
            }
            if let a = sel.audio {
                audio = MediaDecoder(streamType: a.streamType, pid: a.pid, hardware: false, deinterlace: false)
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
        return r
    }

    @Test(.enabled(if: ffmpeg != nil)) func mpeg2InterlacedDeinterlacedToFieldRate() throws {
        let url = try Self.makeTS("mpeg2i", [
            "-f", "lavfi", "-i", "testsrc2=size=1440x1080:rate=30000/1001",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3",
            "-vf", "setsar=4/3,setfield=tff", "-c:v", "mpeg2video", "-b:v", "12M", "-flags", "+ilme+ildct",
            "-c:a", "aac", "-ac", "2",
        ])
        let r = try Self.decode(url, hardware: true, deinterlace: true)
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

    @Test(.enabled(if: ffmpeg != nil)) func h264ViaVideoToolbox() throws {
        let url = try Self.makeTS("h264", [
            "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30000/1001",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-t", "3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
        ])
        let r = try Self.decode(url, hardware: true, deinterlace: true)
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
