import Foundation

/// BonDriverProxy wire protocol (BdpPacket.h).
///
/// Every message is an 8-byte header followed by `bodyLength` bytes:
///
///     +0 sync (0xFF) | +1 command | +2 reserved (option bits) | +3 reserved | +4 bodyLength (UInt32 BE)
///
/// Integers are big-endian. Strings sent by the client are NUL-terminated multibyte strings;
/// strings returned by the server (EnumTuningSpace / EnumChannelName) are NUL-terminated
/// UTF-16LE (Windows WCHAR), with a lone NUL meaning "no more entries".
public enum ProxyCommand: UInt8, Sendable {
    case selectBonDriver = 0
    case createBonDriver
    case openTuner
    case closeTuner
    case setChannel1
    case getSignalLevel
    case waitTsStream
    case getReadyCount
    case getTsStream
    case purgeTsStream
    case release

    case getTunerName
    case isTunerOpening
    case enumTuningSpace
    case enumChannelName
    case setChannel2
    case getCurSpace
    case getCurChannel

    case getTotalDeviceNum
    case getActiveDeviceNum
    case setLnbPower

    case getClientInfo
}

public struct ProxyPacket: Sendable, Equatable {
    public static let syncByte: UInt8 = 0xFF
    public static let headerSize = 8

    /// HaijinW BonDriverProxyEx: option bits in the first reserved header byte.
    /// Bit 0 (`eDesireToUseB25`) asks the server to descramble; it is read on SetChannel2.
    /// Original BonDriverProxy servers ignore this byte.
    public static let optionDesireToUseB25: UInt8 = 0x01

    public var command: UInt8
    public var option: UInt8
    public var body: Data

    public init(command: UInt8, option: UInt8 = 0, body: Data = Data()) {
        self.command = command
        self.option = option
        self.body = body
    }

    public init(_ command: ProxyCommand, body: Data = Data()) {
        self.init(command: command.rawValue, body: body)
    }

    public var proxyCommand: ProxyCommand? { ProxyCommand(rawValue: command) }

    public func encoded() -> Data {
        var d = Data(capacity: Self.headerSize + body.count)
        d.append(contentsOf: [Self.syncByte, command, option, 0])
        d.appendBE(UInt32(body.count))
        d.append(body)
        return d
    }

    // MARK: body builders

    public static func string(_ cmd: ProxyCommand, _ s: String) -> ProxyPacket {
        var body = Data(s.utf8)
        body.append(0)
        return ProxyPacket(cmd, body: body)
    }

    public static func bool(_ cmd: ProxyCommand, _ b: Bool) -> ProxyPacket {
        ProxyPacket(cmd, body: Data([b ? 1 : 0]))
    }

    public static func dwords(_ cmd: ProxyCommand, _ values: UInt32..., trailingByte: UInt8? = nil) -> ProxyPacket {
        var body = Data()
        for v in values { body.appendBE(v) }
        if let b = trailingByte { body.append(b) }
        return ProxyPacket(cmd, body: body)
    }

    // MARK: body readers

    /// Single BYTE response (BOOL). Malformed → false, as in the original client.
    public var boolValue: Bool { body.count == 1 && body[body.startIndex] != 0 }

    /// Single DWORD response. Malformed → nil.
    public var dwordValue: UInt32? { body.count == 4 ? body.readBE32(at: 0) : nil }

    /// UTF-16LE NUL-terminated string. A body of a single NUL WCHAR means "none".
    public var wideStringValue: String? {
        if body.count <= 2 { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(body.count / 2)
        var i = body.startIndex
        while i + 1 < body.endIndex {
            let u = UInt16(body[i]) | (UInt16(body[i + 1]) << 8)
            if u == 0 { break }
            units.append(u)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// GetTsStream payload: `[size][signal level float bits][TS bytes]`.
    public var tsPayload: (signal: Float, data: Data)? {
        guard body.count >= 8, let size = body.readBE32(at: 0), let bits = body.readBE32(at: 4),
              Int(size) == body.count - 8 else { return nil }
        return (Float(bitPattern: bits), body.subdata(in: (body.startIndex + 8)..<body.endIndex))
    }

    public static func tsStream(signal: Float, data: Data) -> ProxyPacket {
        var body = Data(capacity: data.count + 8)
        body.appendBE(UInt32(data.count))
        body.appendBE(signal.bitPattern)
        body.append(data)
        return ProxyPacket(.getTsStream, body: body)
    }

    public static func wideString(_ cmd: ProxyCommand, _ s: String?) -> ProxyPacket {
        var body = Data()
        for u in (s ?? "").utf16 { body.append(UInt8(u & 0xFF)); body.append(UInt8(u >> 8)) }
        body.append(contentsOf: [0, 0])
        return ProxyPacket(cmd, body: body)
    }
}

extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    func readBE32(at offset: Int) -> UInt32? {
        let i = startIndex + offset
        guard i + 4 <= endIndex else { return nil }
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
