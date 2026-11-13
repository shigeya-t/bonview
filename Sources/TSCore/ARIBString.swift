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
        case mosaic, drcs(Int), macro, unknown(Int)

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

    /// Caption-relevant control functions (ARIB STD-B24 vol.1 part 2, 7.2.5). Others are skipped.
    enum Control: Equatable {
        case clearScreen                // CS
        case newLine                    // APR
        case down, up, back, forward    // APD, APU, APB, APF
        case position(row: Int, column: Int) // APS
        case dotPosition(x: Int, y: Int)     // CSI ACPS
        case cancelLine                 // CAN
        case size(CharacterSize)        // SSZ / MSZ / NSZ
    }

    enum CharacterSize: Equatable { case small, medium, normal }

    enum Token: Equatable {
        case text(String)
        case control(Control)
    }

    struct Decoder {
        var g: [Charset] = [.kanji, .alnum, .hiragana, .katakana]
        var gl = 0
        var gr = 2
        var out = ""
        /// Caption mode: control functions become tokens instead of being folded into `out`.
        var captionMode = false
        var tokens: [Token] = []
        private var macroDepth = 0

        /// Initial state for caption statements: G3 holds the macro set (ARIB STD-B24 vol.1 part 3, 8.2.1).
        static func caption() -> Decoder {
            var d = Decoder()
            d.g = [.kanji, .alnum, .hiragana, .macro]
            d.captionMode = true
            return d
        }

        mutating func control(_ c: Control) {
            if !out.isEmpty { tokens.append(.text(out)); out = "" }
            tokens.append(.control(c))
        }

        mutating func finishTokens() -> [Token] {
            if !out.isEmpty { tokens.append(.text(out)); out = "" }
            defer { tokens = [] }
            return tokens
        }

        mutating func run(_ b: [UInt8]) -> String {
            var i = 0
            var single: Int? = nil // single shift (SS2/SS3)
            while i < b.count {
                let c = b[i]
                if captionMode, let n = captionControl(b, i) { i += n; continue }
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
                    g[n] = b[i] == 0x70 ? .macro : .drcs(1)
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

        /// Handles caption control codes; returns the consumed length, or nil if `b[i]` is not one.
        mutating func captionControl(_ b: [UInt8], _ i: Int) -> Int? {
            func param(_ k: Int) -> Int? { i + k < b.count ? Int(b[i + k] & 0x3F) : nil }
            switch b[i] {
            case 0x0C: control(.clearScreen); return 1
            case 0x0D: control(.newLine); return 1
            case 0x0A: control(.down); return 1
            case 0x0B: control(.up); return 1
            case 0x08: control(.back); return 1
            case 0x09: control(.forward); return 1
            case 0x18: control(.cancelLine); return 1
            case 0x1C:
                if let r = param(1), let c = param(2) { control(.position(row: r, column: c)) }
                return 3
            case 0x88: control(.size(.small)); return 1
            case 0x89: control(.size(.medium)); return 1
            case 0x8A: control(.size(.normal)); return 1
            case 0x9B:
                let n = c1Length(b, i)
                // CSI P1 ; P2 0x20 F  — ACPS (F = 0x61) sets the active position in dots.
                if i + n - 1 < b.count, b[i + n - 1] == 0x61 {
                    let params = String(decoding: b[(i + 1)..<(i + n - 2)], as: UTF8.self).split(separator: ";").compactMap { Int($0) }
                    if params.count >= 2 { control(.dotPosition(x: params[0], y: params[1])) }
                }
                return n
            default: return nil
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
            case 0x8B: return 2 // SZX
            case 0x92: // CDC
                return i + 1 < b.count && b[i + 1] == 0x20 ? 3 : 2
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
            case .macro:
                if let m = ARIBString.defaultMacros[c1], macroDepth < 2 {
                    macroDepth += 1
                    _ = run(m)
                    macroDepth -= 1
                }
                return 1
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

    // MARK: Default macros (ARIB STD-B24 vol.1 part 3, default macro statements 0x60–0x6F)

    /// Each re-designates G0–G3, then LS0 + LS2R.
    static let defaultMacros: [UInt8: [UInt8]] = {
        let tail: [UInt8] = [0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D]
        let heads: [[UInt8]] = [
            [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x4A, 0x1B, 0x2A, 0x30],
            [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x31, 0x1B, 0x2A, 0x30],
            [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x41, 0x1B, 0x2A, 0x30],
            [0x1B, 0x28, 0x32, 0x1B, 0x29, 0x34, 0x1B, 0x2A, 0x35],
            [0x1B, 0x28, 0x32, 0x1B, 0x29, 0x33, 0x1B, 0x2A, 0x35],
            [0x1B, 0x28, 0x32, 0x1B, 0x29, 0x20, 0x41, 0x1B, 0x2A, 0x35],
            [0x1B, 0x28, 0x20, 0x41, 0x1B, 0x29, 0x20, 0x42, 0x1B, 0x2A, 0x20, 0x43],
            [0x1B, 0x28, 0x20, 0x44, 0x1B, 0x29, 0x20, 0x45, 0x1B, 0x2A, 0x20, 0x46],
            [0x1B, 0x28, 0x20, 0x47, 0x1B, 0x29, 0x20, 0x48, 0x1B, 0x2A, 0x20, 0x49],
            [0x1B, 0x28, 0x20, 0x4A, 0x1B, 0x29, 0x20, 0x4B, 0x1B, 0x2A, 0x20, 0x4C],
            [0x1B, 0x28, 0x20, 0x4D, 0x1B, 0x29, 0x20, 0x4E, 0x1B, 0x2A, 0x20, 0x4F],
            [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x42, 0x1B, 0x2A, 0x30],
            [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x43, 0x1B, 0x2A, 0x30],
            [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x44, 0x1B, 0x2A, 0x30],
            [0x1B, 0x28, 0x31, 0x1B, 0x29, 0x30, 0x1B, 0x2A, 0x4A],
            [0x1B, 0x28, 0x4A, 0x1B, 0x29, 0x32, 0x1B, 0x2A, 0x20, 0x41],
        ]
        var m: [UInt8: [UInt8]] = [:]
        for (n, h) in heads.enumerated() { m[0x60 + UInt8(n)] = h + tail }
        return m
    }()

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
