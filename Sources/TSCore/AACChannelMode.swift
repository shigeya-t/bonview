import Foundation

/// Channel arrangement of an ADTS AAC frame, as far as it matters for 二重音声 (dual mono).
///
/// ISDB carries dual-mono programmes as two single-channel elements (SCE + SCE) instead of one
/// channel-pair element (CPE). Japanese broadcasts signal this either with
/// `channel_configuration = 2` / `0` and an SCE as the first syntactic element (no PCE), or with a
/// program_config_element whose front channels are exactly two SCEs. Only the first element needs
/// to be looked at, so no spectral data is parsed.
public enum AACChannelMode: Equatable, Sendable {
    case dualMono
    case other

    /// Inspects the first ADTS frame in `data` (normally an audio PES payload). Returns nil when no
    /// ADTS header is found near the start.
    public static func detect(adts data: Data) -> AACChannelMode? {
        data.withUnsafeBytes { raw -> AACChannelMode? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            // PES payloads are frame-aligned in practice; tolerate a little leading junk.
            var i = 0
            while i + 1 < min(n, 64), !(b[i] == 0xFF && b[i + 1] & 0xF6 == 0xF0) { i += 1 }
            guard i + 7 <= n, b[i] == 0xFF, b[i + 1] & 0xF6 == 0xF0 else { return nil }
            let protectionAbsent = b[i + 1] & 1 == 1
            let chanConfig = Int((b[i + 2] & 0x01) << 2 | b[i + 3] >> 6)
            let rawBlocks = Int(b[i + 6] & 0x03)
            var start = i + 7
            if !protectionAbsent { start += 2 + (rawBlocks > 0 ? 2 * rawBlocks : 0) }
            guard start < n else { return nil }

            var bits = BitReader(b, byteOffset: start)
            guard let id = bits.read(3) else { return nil }
            switch (chanConfig, id) {
            case (0, Element.sce), (2, Element.sce):
                return .dualMono
            case (0, Element.pce):
                guard bits.skip(4) else { return nil }               // element_instance_tag
                return parsePCEFront(&bits)
            default:
                return .other
            }
        }
    }

    private enum Element {
        static let sce: UInt32 = 0
        static let pce: UInt32 = 5
    }

    /// Reads a PCE (after its instance tag) and reports dual mono when the only full-band channels
    /// are two front SCEs.
    private static func parsePCEFront(_ r: inout BitReader) -> AACChannelMode? {
        guard r.skip(2 + 4),                                         // object_type, sampling_frequency_index
              let front = r.read(4), let side = r.read(4), let back = r.read(4),
              r.skip(2 + 3 + 4) else { return nil }                  // lfe, assoc_data, valid_cc
        // mono_mixdown (element_number 4), stereo_mixdown (4), matrix_mixdown (idx 2 + pseudo_surround 1)
        for width in [4, 4, 3] {
            guard let present = r.read(1) else { return nil }
            if present == 1 { guard r.skip(width) else { return nil } }
        }
        guard front == 2, side == 0, back == 0 else { return .other }
        var cpes = 0
        for _ in 0..<front {
            guard let isCPE = r.read(1), r.skip(4) else { return nil }
            cpes += Int(isCPE)
        }
        return cpes == 0 ? .dualMono : .other
    }
}

/// MSB-first bit reader over a byte buffer.
struct BitReader {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var pos: Int

    init(_ bytes: UnsafeBufferPointer<UInt8>, byteOffset: Int) {
        self.bytes = bytes
        pos = byteOffset * 8
    }

    mutating func read(_ count: Int) -> UInt32? {
        guard pos + count <= bytes.count * 8 else { return nil }
        var v: UInt32 = 0
        for _ in 0..<count {
            v = v << 1 | UInt32(bytes[pos >> 3] >> (7 - UInt8(pos & 7)) & 1)
            pos += 1
        }
        return v
    }

    mutating func skip(_ count: Int) -> Bool {
        guard pos + count <= bytes.count * 8 else { return false }
        pos += count
        return true
    }
}
