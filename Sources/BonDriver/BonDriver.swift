import Foundation

/// Result of a channel change, matching BonDriverProxy's SetChannel2 reply codes.
public enum SetChannelResult: Sendable, Equatable {
    /// Tuned (reply 0x00).
    case tuned
    /// Another client holds a higher channel lock; the tuner stays on its current channel (reply 0x01).
    case locked
}

public enum BonDriverError: Error, CustomStringConvertible, Sendable {
    case connectionFailed(String)
    case disconnected
    case timeout(String)
    case rejected(String)
    case notOpen

    public var description: String {
        switch self {
        case .connectionFailed(let s): return "接続に失敗しました: \(s)"
        case .disconnected: return "サーバーとの接続が切断されました"
        case .timeout(let s): return "応答がありません: \(s)"
        case .rejected(let s): return "サーバーが要求を拒否しました: \(s)"
        case .notOpen: return "チューナーが開かれていません"
        }
    }
}

/// Swift counterpart of IBonDriver / IBonDriver2 / IBonDriver3.
///
/// Unlike the Windows interface (where the host polls `GetTsStream`), TS data is pushed to
/// `tsHandler`, because both BonDriverProxy and the decoder pipeline are push-oriented.
public protocol BonDriver: AnyObject {
    // IBonDriver
    func openTuner() throws
    func closeTuner()
    var signalLevel: Float { get }
    func purgeTsStream()
    func release()

    // IBonDriver2
    var tunerName: String { get }
    func enumTuningSpace(_ space: UInt32) -> String?
    func enumChannelName(space: UInt32, channel: UInt32) -> String?
    func setChannel(space: UInt32, channel: UInt32) throws -> SetChannelResult
    var currentSpace: UInt32? { get }
    var currentChannel: UInt32? { get }

    // IBonDriver3
    var totalDeviceNum: UInt32 { get }
    var activeDeviceNum: UInt32 { get }
    func setLnbPower(_ enable: Bool) -> Bool

    /// Receives TS chunks (multiples of 188 bytes are typical but not guaranteed). Called on a
    /// background thread; the handler must not block for long.
    var tsHandler: ((Data) -> Void)? { get set }
    /// Called once when the driver becomes unusable (e.g. network disconnect).
    var errorHandler: ((BonDriverError) -> Void)? { get set }
}

public struct TuningSpace: Sendable, Hashable, Identifiable {
    public var index: UInt32
    public var name: String
    public var channels: [Channel]
    public var id: UInt32 { index }

    public struct Channel: Sendable, Hashable, Identifiable {
        public var space: UInt32
        public var index: UInt32
        public var name: String
        public var id: String { "\(space)-\(index)" }

        public init(space: UInt32, index: UInt32, name: String) {
            self.space = space
            self.index = index
            self.name = name
        }
    }
}

extension BonDriver {
    /// Enumerate every tuning space and channel (the usual IBonDriver2 enumeration loop).
    public func enumerateChannels(maxSpaces: UInt32 = 64, maxChannels: UInt32 = 512) -> [TuningSpace] {
        var result: [TuningSpace] = []
        var space: UInt32 = 0
        while space < maxSpaces, let name = enumTuningSpace(space) {
            var channels: [TuningSpace.Channel] = []
            var ch: UInt32 = 0
            while ch < maxChannels, let chName = enumChannelName(space: space, channel: ch) {
                channels.append(.init(space: space, index: ch, name: chName))
                ch += 1
            }
            result.append(TuningSpace(index: space, name: name, channels: channels))
            space += 1
        }
        return result
    }
}
