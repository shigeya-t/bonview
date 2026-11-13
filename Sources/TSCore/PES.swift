import Foundation

public struct PESPacket: Sendable {
    public var streamID: UInt8
    /// 90 kHz, 33-bit (not unwrapped).
    public var pts: Int64?
    public var dts: Int64?
    /// Elementary stream bytes.
    public var payload: Data
}

/// Reassembles PES packets for one PID.
public struct PESAssembler {
    private var buffer = Data()
    private var expected: Int? // total PES size when PES_packet_length != 0
    private var active = false

    public init() {}

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        expected = nil
        active = false
    }

    public mutating func push(_ payload: UnsafeRawBufferPointer, unitStart: Bool, _ emit: (PESPacket) -> Void) {
        if unitStart {
            if active, let p = Self.parse(buffer) { emit(p) }
            buffer.removeAll(keepingCapacity: true)
            buffer.append(contentsOf: payload)
            active = true
            if buffer.count >= 6 {
                let len = Int(buffer[4]) << 8 | Int(buffer[5])
                expected = len == 0 ? nil : len + 6
            } else {
                expected = nil
            }
        } else {
            guard active else { return }
            buffer.append(contentsOf: payload)
        }
        if let e = expected, buffer.count >= e {
            if let p = Self.parse(buffer.prefix(e)) { emit(p) }
            reset()
        }
    }

    static func parse(_ d: Data) -> PESPacket? {
        let b = d.startIndex
        guard d.count >= 9, d[b] == 0, d[b + 1] == 0, d[b + 2] == 1 else { return nil }
        let sid = d[b + 3]
        // stream_ids without the optional header: program_stream_map, padding, private_stream_2, ECM, EMM, directory...
        if [0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xFF, 0xF2, 0xF8].contains(sid) {
            return PESPacket(streamID: sid, pts: nil, dts: nil, payload: d.subdata(in: (b + 6)..<d.endIndex))
        }
        let flags = d[b + 7]
        let hlen = Int(d[b + 8])
        guard d.count >= 9 + hlen else { return nil }
        var pts: Int64? = nil, dts: Int64? = nil
        if flags & 0x80 != 0, hlen >= 5 { pts = timestamp(d, b + 9) }
        if flags & 0xC0 == 0xC0, hlen >= 10 { dts = timestamp(d, b + 14) }
        return PESPacket(streamID: sid, pts: pts, dts: dts, payload: d.subdata(in: (b + 9 + hlen)..<d.endIndex))
    }

    static func timestamp(_ d: Data, _ i: Int) -> Int64 {
        Int64((d[i] >> 1) & 0x07) << 30 | Int64(d[i + 1]) << 22 | Int64(d[i + 2] >> 1) << 15 | Int64(d[i + 3]) << 7 | Int64(d[i + 4] >> 1)
    }
}
