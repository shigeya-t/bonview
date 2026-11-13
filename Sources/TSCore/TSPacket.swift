import Foundation

public let tsPacketSize = 188

/// View over one 188-byte transport stream packet.
public struct TSPacket {
    public let bytes: UnsafeRawBufferPointer

    @inline(__always) public init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    @inline(__always) public var transportError: Bool { bytes[1] & 0x80 != 0 }
    @inline(__always) public var payloadUnitStart: Bool { bytes[1] & 0x40 != 0 }
    @inline(__always) public var pid: UInt16 { UInt16(bytes[1] & 0x1F) << 8 | UInt16(bytes[2]) }
    @inline(__always) public var scramblingControl: UInt8 { bytes[3] >> 6 }
    @inline(__always) public var adaptationFieldControl: UInt8 { (bytes[3] >> 4) & 0x03 }
    @inline(__always) public var continuityCounter: UInt8 { bytes[3] & 0x0F }
    @inline(__always) public var hasPayload: Bool { adaptationFieldControl & 0x01 != 0 }

    public var discontinuityIndicator: Bool {
        guard adaptationFieldControl & 0x02 != 0, bytes[4] > 0 else { return false }
        return bytes[5] & 0x80 != 0
    }

    /// Payload bytes, or nil if the packet carries none (or the adaptation field is broken).
    public var payload: UnsafeRawBufferPointer? {
        guard hasPayload else { return nil }
        var offset = 4
        if adaptationFieldControl & 0x02 != 0 {
            offset += 1 + Int(bytes[4])
        }
        guard offset < tsPacketSize else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes[offset..<tsPacketSize])
    }
}

/// Splits an arbitrary byte stream into aligned TS packets, re-synchronising on 0x47.
public struct TSPacketSplitter {
    private var carry: [UInt8] = []
    public private(set) var syncLossCount = 0

    public init() {}

    public mutating func reset() { carry.removeAll(keepingCapacity: true) }

    public mutating func split(_ data: Data, _ body: (TSPacket) -> Void) {
        if carry.isEmpty {
            data.withUnsafeBytes { consume($0, body) }
        } else {
            carry.append(contentsOf: data)
            let buf = carry
            carry.removeAll(keepingCapacity: true)
            buf.withUnsafeBytes { consume($0, body) }
        }
    }

    private mutating func consume(_ buf: UnsafeRawBufferPointer, _ body: (TSPacket) -> Void) {
        var i = 0
        let n = buf.count
        while i + tsPacketSize <= n {
            if buf[i] != 0x47 || (i + tsPacketSize < n && buf[i + tsPacketSize] != 0x47) {
                // Find the next position where two consecutive sync bytes line up.
                syncLossCount += 1
                var j = i + 1
                while j < n {
                    if buf[j] == 0x47 && (j + tsPacketSize >= n || buf[j + tsPacketSize] == 0x47) { break }
                    j += 1
                }
                i = j
                continue
            }
            body(TSPacket(UnsafeRawBufferPointer(rebasing: buf[i..<(i + tsPacketSize)])))
            i += tsPacketSize
        }
        if i < n { carry.append(contentsOf: buf[i..<n]) }
    }
}
