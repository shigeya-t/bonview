import CFFmpeg
import CoreVideo
import Foundation

/// Swift wrapper over the C decoder (libavcodec + VideoToolbox + bwdif + swresample).
final class MediaDecoder {
    private let raw: OpaquePointer
    let streamType: UInt8
    let pid: UInt16

    /// Decoded picture and its PTS (90 kHz, 33-bit). Called synchronously from `feed`.
    var onVideo: ((CVPixelBuffer, Int64?) -> Void)?
    /// Interleaved float32 stereo PCM: samples, frames, channels, sampleRate, PTS.
    var onAudio: ((UnsafePointer<Float>, Int, Int, Int, Int64?) -> Void)?

    init?(streamType: UInt8, pid: UInt16, hardware: Bool, deinterlace: Bool) {
        guard let d = tv_decoder_create(Int32(streamType), hardware ? 1 : 0, deinterlace ? 1 : 0) else { return nil }
        raw = d
        self.streamType = streamType
        self.pid = pid
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        tv_decoder_set_video_callback(raw, { ctx, pb, pts, _, _ in
            guard let ctx, let pb else { return }
            let me = Unmanaged<MediaDecoder>.fromOpaque(ctx).takeUnretainedValue()
            me.onVideo?(pb, pts == Int64.min ? nil : pts)
        }, ctx)
        tv_decoder_set_audio_callback(raw, { ctx, samples, frames, channels, rate, pts in
            guard let ctx, let samples else { return }
            let me = Unmanaged<MediaDecoder>.fromOpaque(ctx).takeUnretainedValue()
            me.onAudio?(samples, Int(frames), Int(channels), Int(rate), pts == Int64.min ? nil : pts)
        }, ctx)
    }

    deinit { tv_decoder_destroy(raw) }

    var description: String { String(cString: tv_decoder_description(raw)) }

    func setDualMonoMode(_ mode: DualMonoMode) { tv_decoder_set_dual_mono_mode(raw, mode.rawValue) }

    func feed(_ data: Data, pts: Int64?, dts: Int64?) {
        data.withUnsafeBytes { buf in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = tv_decoder_feed(raw, base, Int32(buf.count), pts ?? Int64.min, dts ?? Int64.min)
        }
    }

    func flush() { tv_decoder_flush(raw) }
}

/// 二重音声 (dual-mono) output selection.
public enum DualMonoMode: Int32, CaseIterable, Sendable {
    case both = 0
    case main = 1
    case sub = 2

    public var label: String {
        switch self {
        case .both: return "主+副"
        case .main: return "主音声"
        case .sub: return "副音声"
        }
    }
}
