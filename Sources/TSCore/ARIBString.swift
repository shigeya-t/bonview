import Foundation

/// ARIB STD-B24 8-unit character code → String (used by SI: service names, EPG text).
///
/// Supports the G0–G3 designation / invocation machinery, Kanji (JIS X 0208 via EUC-JP),
/// alphanumeric, hiragana, katakana, JIS X 0201 katakana, JIS compatible kanji planes and
/// the common additional symbols (rows 90–94). DRCS and mosaic sets are rendered as "〓".
/// Alphanumerics are emitted as half-width ASCII.
public enum ARIBString {
    enum Charset: Equatable {
        case kanji, alnum, hiragana, katakana, jisKatakana, symbols, jisKanji1, jisKanji2
        case mosaic, drcs(Int), unknown(Int)

        var bytes: Int {
            switch self {
            case .kanji, .symbols, .jisKanji1, .jisKanji2: return 2
            case .drcs(let n), .unknown(let n): return n
            default: return 1
            }
        }

        static func graphic(_ f: UInt8, twoByte: Bool) -> Charset {
            switch f {
            case 0x42: return .kanji
            case 0x4A, 0x36: return .alnum
            case 0x30, 0x37: return .hiragana
            case 0x31, 0x38: return .katakana
            case 0x49: return .jisKatakana
            case 0x39: return .jisKanji1
            case 0x3A: return .jisKanji2
            case 0x3B: return .symbols
            case 0x32, 0x33, 0x34, 0x35: return .mosaic
            default: return .unknown(twoByte ? 2 : 1)
            }
        }
    }

    public static func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var d = Decoder()
        return d.run(Array(bytes))
    }

    struct Decoder {
        var g: [Charset] = [.kanji, .alnum, .hiragana, .katakana]
        var gl = 0
        var gr = 2
        var out = ""

        mutating func run(_ b: [UInt8]) -> String {
            var i = 0
            var single: Int? = nil // single shift (SS2/SS3)
            while i < b.count {
                let c = b[i]
                switch c {
                case 0x0F: gl = 0; i += 1           // LS0
                case 0x0E: gl = 1; i += 1           // LS1
                case 0x19: single = 2; i += 1       // SS2
                case 0x1D: single = 3; i += 1       // SS3
                case 0x1B:                          // ESC
                    i = escape(b, i + 1)
                case 0x0D, 0x0A: out += "\n"; i += 1
                case 0x20, 0xA0: out += " "; i += 1
                case 0x00..<0x20:
                    i += controlLength(b, i)
                case 0x80..<0xA0:
                    i += c1Length(b, i)
                case 0x21..<0x7F:
                    let set = g[single ?? gl]
                    single = nil
                    i += emit(set, b, i, mask: 0x7F)
                case 0xA1..<0xFF:
                    i += emit(g[gr], b, i, mask: 0x7F)
                default:
                    i += 1
                }
            }
            return out
        }

        /// Returns index after the escape sequence.
        mutating func escape(_ b: [UInt8], _ start: Int) -> Int {
            var i = start
            guard i < b.count else { return i }
            let c = b[i]
            switch c {
            case 0x6E: gl = 2; return i + 1                         // LS2
            case 0x6F: gl = 3; return i + 1                         // LS3
            case 0x7E: gr = 1; return i + 1                         // LS1R
            case 0x7D: gr = 2; return i + 1                         // LS2R
            case 0x7C: gr = 3; return i + 1                         // LS3R
            case 0x28, 0x29, 0x2A, 0x2B:                            // 1-byte G set
                let n = Int(c - 0x28)
                i += 1
                guard i < b.count else { return i }
                if b[i] == 0x20 {                                   // DRCS
                    i += 1
                    guard i < b.count else { return i }
                    g[n] = .drcs(1)
                    return i + 1
                }
                g[n] = Charset.graphic(b[i], twoByte: false)
                return i + 1
            case 0x24:                                              // 2-byte G set
                i += 1
                guard i < b.count else { return i }
                var n = 0
                if (0x29...0x2B).contains(b[i]) || b[i] == 0x28 {
                    n = Int(b[i] - 0x28)
                    i += 1
                    guard i < b.count else { return i }
                }
                if b[i] == 0x20 {
                    i += 1
                    guard i < b.count else { return i }
                    g[n] = .drcs(2)
                    return i + 1
                }
                g[n] = Charset.graphic(b[i], twoByte: true)
                return i + 1
            default:
                return i + 1
            }
        }

        func controlLength(_ b: [UInt8], _ i: Int) -> Int {
            switch b[i] {
            case 0x16: return 2 // PAPF
            case 0x1C: return 3 // APS
            default: return 1
            }
        }

        func c1Length(_ b: [UInt8], _ i: Int) -> Int {
            switch b[i] {
            case 0x90: // COL
                return i + 1 < b.count && b[i + 1] == 0x20 ? 3 : 2
            case 0x91, 0x93, 0x94, 0x97: return 2 // FLC, POL, WMM, HLC
            case 0x95: // MACRO
                var j = i + 2
                while j + 1 < b.count && !(b[j] == 0x95 && b[j + 1] == 0x4F) { j += 1 }
                return j + 2 - i
            case 0x98: return 2 // RPC
            case 0x9D: // TIME
                return i + 1 < b.count && b[i + 1] == 0x20 ? 3 : 2
            case 0x9B: // CSI: parameters terminated by a final byte 0x40–0x7E (after 0x20)
                var j = i + 1
                while j < b.count && !(b[j] >= 0x40 && b[j] <= 0x7E && j > i + 1 && b[j - 1] == 0x20) { j += 1 }
                return j + 1 - i
            default: return 1
            }
        }

        mutating func emit(_ set: Charset, _ b: [UInt8], _ i: Int, mask: UInt8) -> Int {
            let c1 = b[i] & mask
            switch set {
            case .alnum:
                switch c1 {
                case 0x5C: out += "¥"
                case 0x7E: out += "‾"
                default: out.unicodeScalars.append(Unicode.Scalar(c1))
                }
                return 1
            case .hiragana:
                out += kana(c1, base: 0x3041, last: 0x73, tail: ["ゝ", "ゞ", "ー", "。", "「", "」", "、", "・"])
                return 1
            case .katakana:
                out += kana(c1, base: 0x30A1, last: 0x76, tail: ["ヽ", "ヾ", "ー", "。", "「", "」", "、", "・"])
                return 1
            case .jisKatakana:
                if (0x21...0x5F).contains(c1) { out.unicodeScalars.append(Unicode.Scalar(0xFF61 + UInt32(c1) - 0x21)!) }
                return 1
            case .kanji, .jisKanji1, .jisKanji2, .symbols:
                guard i + 1 < b.count else { return 1 }
                let c2 = b[i + 1] & mask
                out += kanji(c1, c2, plane2: set == .jisKanji2)
                return 2
            case .mosaic:
                out += " "
                return 1
            case .drcs(let n), .unknown(let n):
                out += "〓"
                return n
            }
        }

        func kana(_ c: UInt8, base: UInt32, last: UInt8, tail: [String]) -> String {
            if c >= 0x21 && c <= last { return String(Unicode.Scalar(base + UInt32(c) - 0x21)!) }
            if c >= 0x77 { return tail[Int(c - 0x77)] }
            return " "
        }

        func kanji(_ c1: UInt8, _ c2: UInt8, plane2: Bool) -> String {
            if !plane2, c1 >= 0x7A, let s = ARIBString.additionalSymbols[UInt16(c1) << 8 | UInt16(c2)] { return s }
            if plane2 || c1 >= 0x75 { return "〓" }
            return ARIBString.jisX0208(c1, c2) ?? "〓"
        }
    }

    // MARK: JIS X 0208

    nonisolated(unsafe) private static var kanjiCache: [UInt16: String] = [:]
    private static let kanjiLock = NSLock()

    static func jisX0208(_ c1: UInt8, _ c2: UInt8) -> String? {
        let key = UInt16(c1) << 8 | UInt16(c2)
        kanjiLock.lock()
        defer { kanjiLock.unlock() }
        if let s = kanjiCache[key] { return s }
        let s = String(bytes: [c1 | 0x80, c2 | 0x80], encoding: .japaneseEUC)
        if let s { kanjiCache[key] = s }
        return s
    }

    // MARK: Additional symbols (ARIB STD-B24 Table 7-19, row 90 subset)

    static let additionalSymbols: [UInt16: String] = {
        let row90: [String] = [
            "[HV]", "[SD]", "[P]", "[W]", "[MV]", "[手]", "[字]", "[双]", "[デ]", "[S]", "[二]", "[多]",
            "[解]", "[SS]", "[B]", "[N]", "■", "●", "[天]", "[交]", "[映]", "[無]", "[料]", "〓",
            "[前]", "[後]", "[再]", "[新]", "[初]", "[終]", "[生]", "[販]", "[声]", "[吹]", "[PPV]", "(秘)", "ほか",
        ]
        var m: [UInt16: String] = [:]
        for (n, s) in row90.enumerated() { m[0x7A50 + UInt16(n)] = s }
        return m
    }()
}
