import Foundation

// ARIB STD-B24 captions (字幕), carried as synchronized PES (stream_id 0xBD, data_identifier 0x80)
// or asynchronous PES (0xBF, 0x81) on the stream with component_tag 0x30–0x37.
//
// PES_data_packet:
//   data_identifier(8) private_stream_id(8) reserved(4) PES_data_packet_header_length(4) header bytes
//   data_group:
//     data_group_id(6) data_group_version(2) link_number(8) last_link_number(8) data_group_size(16)
//     data_group_data_byte[size] CRC_16 (CCITT, over data_group_id … CRC → 0)
//   data_group_id & 0x0F: 0 = caption management data, 1–8 = caption statement for language 1–8
//   (0x20 added for the B set).
// caption_management_data:
//   TMD(2) reserved(6) [OTM(36) reserved(4) if TMD == 0b10] num_languages(8)
//   per language: language_tag(3) reserved(1) DMF(4) [DC(8) if DMF ∈ 0b1100…0b1110] ISO_639(24)
//                 format(4) TCS(2) rollup_mode(2)
//   data_unit_loop_length(24) data_unit()*
// caption_data (statement):
//   TMD(2) reserved(6) [STM(36) reserved(4) if TMD ∈ {0b01, 0b10}] data_unit_loop_length(24) data_unit()*
// data_unit: unit_separator(0x1F) data_unit_parameter(8) data_unit_size(24) bytes
//   parameter 0x20 = statement body (8-unit code), 0x30/0x31 = DRCS, 0x35 = bitmap.

public struct CaptionLanguage: Equatable, Sendable {
    /// language_tag (0–7); statement data_group number = tag + 1.
    public var tag: Int
    /// ISO 639-2 code, e.g. "jpn".
    public var code: String
}

public struct CaptionDataUnit: Equatable, Sendable {
    public var parameter: UInt8
    public var data: [UInt8]
}

public struct CaptionDataGroup: Equatable, Sendable {
    /// 0 = management, 1–8 = statement for language tag 0–7.
    public var number: Int
    public var timingMode: UInt8
    public var languages: [CaptionLanguage]
    /// Display format per language from the management data, as SWF parameter numbers.
    public var formats: [Int] = []
    public var units: [CaptionDataUnit]

    public var isManagement: Bool { number == 0 }

    /// Parses the PES payload (after the PES header).
    public init?<D: Collection>(pesPayload: D) where D.Element == UInt8 {
        let p = Array(pesPayload)
        guard p.count >= 3, p[0] == 0x80 || p[0] == 0x81, p[1] == 0xFF else { return nil }
        var i = 3 + Int(p[2] & 0x0F)
        guard i + 5 <= p.count else { return nil }
        let groupStart = i
        let groupID = Int(p[i] >> 2)
        let size = Int(p[i + 3]) << 8 | Int(p[i + 4])
        i += 5
        guard i + size + 2 <= p.count, CRC16.ccitt(p[groupStart..<(i + size + 2)]) == 0 else { return nil }
        let end = i + size
        number = groupID & 0x0F
        guard number <= 8 else { return nil }
        guard i < end else { return nil }
        timingMode = p[i] >> 6
        i += 1
        languages = []
        if number == 0 {
            if timingMode == 0b10 { i += 5 }
            guard i < end else { return nil }
            let count = Int(p[i]); i += 1
            for _ in 0..<count {
                guard i + 5 <= end else { return nil }
                let tag = Int(p[i] >> 5)
                let dmf = p[i] & 0x0F
                i += 1
                if (0b1100...0b1110).contains(dmf) { i += 1 }
                guard i + 4 <= end else { return nil }
                let code = String(decoding: p[i..<(i + 3)], as: UTF8.self)
                // Format(4) uses the SWF numbering: 7 = 960×540 horizontal, 5 = 1920×1080, 9 = 720×480…
                formats.append(Int(p[i + 3] >> 4))
                i += 4
                languages.append(CaptionLanguage(tag: tag, code: code))
            }
        } else if timingMode == 0b01 || timingMode == 0b10 {
            i += 5
        }
        guard i + 3 <= end else { return nil }
        let loopLength = Int(p[i]) << 16 | Int(p[i + 1]) << 8 | Int(p[i + 2])
        i += 3
        let loopEnd = min(end, i + loopLength)
        units = []
        while i + 5 <= loopEnd, p[i] == 0x1F {
            let param = p[i + 1]
            let n = Int(p[i + 2]) << 16 | Int(p[i + 3]) << 8 | Int(p[i + 4])
            i += 5
            guard i + n <= loopEnd else { break }
            units.append(CaptionDataUnit(parameter: param, data: Array(p[i..<(i + n)])))
            i += n
        }
    }
}

enum CRC16 {
    static func ccitt<C: Collection>(_ data: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0
        for b in data {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}

// MARK: - Rendering model

public struct CaptionColor: Hashable, Sendable {
    public var r, g, b, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var isTransparent: Bool { a == 0 }

    /// ARIB default CLUT (STD-B24 vol.1 part 2, Table 7-?). Indices 0–15 are the standard set
    /// (8 = transparent); 16–63 fill the remaining 0/85/170/255 RGB grid in order; 64–127 repeat
    /// 0–63 at half opacity. Only 0–15 and the half-opacity black/colours are common in practice.
    public static let clut: [CaptionColor] = {
        let full: [CaptionColor] = [
            .init(0, 0, 0), .init(255, 0, 0), .init(0, 255, 0), .init(255, 255, 0),
            .init(0, 0, 255), .init(255, 0, 255), .init(0, 255, 255), .init(255, 255, 255),
            .init(0, 0, 0, 0), .init(170, 0, 0), .init(0, 170, 0), .init(170, 170, 0),
            .init(0, 0, 170), .init(170, 0, 170), .init(0, 170, 170), .init(170, 170, 170),
        ]
        var t = full
        let levels: [UInt8] = [0, 85, 170, 255]
        outer: for r in levels { for g in levels { for b in levels {
            let c = CaptionColor(r, g, b)
            if t.contains(c) { continue }
            t.append(c)
            if t.count == 64 { break outer }
        } } }
        while t.count < 64 { t.append(.init(0, 0, 0)) }
        t += t.map { $0.a == 0 ? $0 : CaptionColor($0.r, $0.g, $0.b, 128) }
        return t
    }()
}

/// DRCS (downloaded character) pattern. `pixels` holds one gradation level per pixel,
/// 0 (background) … `depth + 1` (full foreground), row-major.
public struct CaptionDRCS: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int
    public var pixels: [UInt8]

    /// Parses a DRCS data unit (parameter 0x30 = 1-byte sets, 0x31 = DRCS-0) into code → pattern.
    /// Only uncompressed patterns (mode 0/1) are supported; geometric ones are skipped.
    static func parseUnit(_ d: [UInt8]) -> [UInt16: CaptionDRCS] {
        var out: [UInt16: CaptionDRCS] = [:]
        guard !d.isEmpty else { return out }
        var i = 1
        for _ in 0..<Int(d[0]) {
            guard i + 3 <= d.count else { break }
            let code = UInt16(d[i]) << 8 | UInt16(d[i + 1])
            let fonts = Int(d[i + 2])
            i += 3
            for _ in 0..<fonts {
                guard i < d.count else { return out }
                let mode = d[i] & 0x0F
                i += 1
                if mode <= 1 {
                    guard i + 3 <= d.count else { return out }
                    let depth = Int(d[i]), w = Int(d[i + 1]), h = Int(d[i + 2])
                    i += 3
                    var bits = 1
                    while (1 << bits) < depth + 2 { bits += 1 }
                    if mode == 0 { bits = 1 } // 2-level pattern
                    let size = (w * h * bits + 7) / 8
                    guard i + size <= d.count else { return out }
                    var px = [UInt8](repeating: 0, count: w * h)
                    for n in 0..<(w * h) {
                        var v = 0
                        for k in 0..<bits {
                            let bit = n * bits + k
                            v = v << 1 | Int(d[i + bit / 8] >> (7 - bit % 8) & 1)
                        }
                        px[n] = UInt8(mode == 0 ? v * (depth + 1) : v)
                    }
                    i += size
                    if out[code] == nil { out[code] = CaptionDRCS(width: w, height: h, depth: mode == 0 ? max(depth, 0) : depth, pixels: px) }
                } else {
                    guard i + 4 <= d.count else { return out }
                    let len = Int(d[i + 2]) << 8 | Int(d[i + 3])
                    i += 4 + len
                }
            }
        }
        return out
    }
}

/// One character cell placed on the caption plane.
public struct CaptionGlyph: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case text(String)
        case drcs(CaptionDRCS)
    }

    public var content: Content
    /// Cell rectangle (character + spacing) in plane dots, top-left origin.
    public var x, y, width, height: Double
    /// Character box inside the cell (cell minus spacing; centred horizontally, at the bottom).
    public var charWidth, charHeight: Double
    public var foreground: CaptionColor
    public var background: CaptionColor
    public var underline: Bool
    /// HLC bits: 1 bottom, 2 right, 4 top, 8 left.
    public var enclosure: Int
    /// Small-size (ruby) text.
    public var isSmall: Bool

    public var text: String {
        switch content {
        case .text(let s): return s
        case .drcs: return "〓"
        }
    }
}

/// What to draw: the caption plane size and the glyphs on it.
public struct CaptionFrame: Hashable, Sendable {
    public var planeWidth: Double = 960
    public var planeHeight: Double = 540
    public var glyphs: [CaptionGlyph] = []

    public init() {}

    public var isEmpty: Bool { glyphs.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// Plain text rows, top to bottom (ruby dropped) — for the simple display style and tests.
    public var lines: [String] {
        let rows = Dictionary(grouping: glyphs.filter { !$0.isSmall }) { Int(($0.y + $0.height).rounded()) }
        return rows.keys.sorted().compactMap { key in
            let s = rows[key]!.sorted { $0.x < $1.x }.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
    }
}

// MARK: - Layout

/// The caption plane: interprets statement bodies (positioning, sizes, colours, DRCS) into
/// glyphs, following ARIB STD-B24 vol.1 part 3 chapter 8 / part 2 chapter 7. Vertical writing,
/// flashing, scrolling and TIME waits are not modelled.
public struct CaptionScreen: Equatable, Sendable {
    public private(set) var frame = CaptionFrame()
    /// DRCS patterns received so far, by character code.
    public var drcs: [UInt16: CaptionDRCS] = [:]
    /// Plane format from the management data (SWF parameter numbering), used until SWF arrives.
    public var defaultFormat = 7

    // Writing format (reset at each statement).
    private var areaX = 0.0, areaY = 0.0, areaW = 960.0, areaH = 540.0
    private var charW = 36.0, charH = 36.0, hSpace = 4.0, vSpace = 24.0
    private var x = 0.0, y = 0.0 // active position: lower-left of the cell
    private var hasPosition = false
    private var size = ARIBString.CharacterSize.normal
    private var palette = 0
    private var fg = CaptionColor.clut[7], bg = CaptionColor.clut[8]
    private var underline = false, enclosure = 0
    private var repeatCount = 1

    public init() {}

    public var lines: [String] { frame.lines }

    public mutating func clear() {
        frame.glyphs.removeAll()
        hasPosition = false
    }

    // MARK: Formats

    private mutating func setFormat(_ p: Int) {
        switch p {
        case 5, 6: setPlane(1920, 1080)          // 1920×1080 horizontal / vertical
        case 9, 10: setPlane(720, 480)
        case 11, 12: setPlane(1280, 720)
        default: setPlane(960, 540)              // 7, 8 and anything unknown
        }
    }

    private mutating func setPlane(_ w: Double, _ h: Double) {
        frame.planeWidth = w
        frame.planeHeight = h
        areaX = 0; areaY = 0; areaW = w; areaH = h
        let k = h / 540
        charW = 36 * k; charH = 36 * k; hSpace = 4 * k; vSpace = 24 * k
        if w == 720 { vSpace = 16 } // SD default
        hasPosition = false
    }

    private var scale: (Double, Double) {
        switch size {
        case .small: return (0.5, 0.5)
        case .medium: return (0.5, 1)
        case .tiny: return (0.25, 0.25)
        case .doubleHeight: return (1, 2)
        case .doubleWidth: return (2, 1)
        case .doubleBoth: return (2, 2)
        case .normal: return (1, 1)
        }
    }

    private var cellW: Double { (charW + hSpace) * scale.0 }
    private var cellH: Double { (charH + vSpace) * scale.1 }

    private mutating func ensurePosition() {
        if !hasPosition { x = areaX; y = areaY + cellH; hasPosition = true }
    }

    private mutating func newLine() {
        ensurePosition()
        x = areaX
        y += cellH
    }

    private func color(_ index: Int) -> CaptionColor {
        let i = palette * 16 + index
        return CaptionColor.clut.indices.contains(i) ? CaptionColor.clut[i] : CaptionColor.clut[7]
    }

    // MARK: Statements

    /// Applies one statement body (data unit 0x20). The writing format is initialised first.
    public mutating func apply(_ statement: [UInt8]) {
        setFormatKeepingGlyphs(defaultFormat)
        size = .normal; palette = 0; fg = CaptionColor.clut[7]; bg = CaptionColor.clut[8]; underline = false; enclosure = 0; repeatCount = 1
        var d = ARIBString.Decoder.caption()
        _ = d.run(statement)
        for token in d.finishTokens() {
            switch token {
            case .text(let s): put(.text(s))
            case .drcs(let code):
                if let p = drcs[code] { put(.drcs(p)) } else { put(.text("〓")) }
            case .control(let c): control(c)
            }
        }
    }

    private mutating func setFormatKeepingGlyphs(_ p: Int) {
        let glyphs = frame.glyphs
        setFormat(p)
        frame.glyphs = glyphs
    }

    private mutating func control(_ c: ARIBString.Control) {
        switch c {
        case .clearScreen: clear()
        case .newLine: newLine()
        case .down: ensurePosition(); y += cellH
        case .up: ensurePosition(); y -= cellH
        case .back:
            ensurePosition()
            x -= cellW
            if x < areaX { x = areaX + areaW - cellW; y -= cellH }
        case .forward(let n):
            for _ in 0..<max(n, 0) { advance() }
        case .position(let row, let col):
            x = areaX + Double(col) * cellW
            y = areaY + Double(row + 1) * cellH
            hasPosition = true
        case .cancelLine:
            ensurePosition()
            let top = y - cellH, x0 = x
            frame.glyphs.removeAll { $0.y + $0.height > top + 0.5 && $0.y < y - 0.5 && $0.x >= x0 - 0.5 }
        case .size(let s): size = s
        // Colours are resolved against the palette in effect at designation time.
        case .foreground(let i): fg = color(i)
        case .background(let i): bg = color(i)
        case .palette(let p): palette = p
        case .underline(let on): underline = on
        case .enclosure(let e): enclosure = e
        case .repeatNext(let n): repeatCount = n
        case .csi(let f, let p):
            func v(_ k: Int) -> Double { p.indices.contains(k) ? Double(p[k]) : 0 }
            switch f {
            case 0x53: setFormatKeepingGlyphs(p.first ?? 7)                      // SWF
            case 0x56: areaW = v(0); areaH = v(1); hasPosition = false           // SDF
            case 0x5F: areaX = v(0); areaY = v(1); hasPosition = false           // SDP
            case 0x57: charW = v(0); charH = v(1)                                // SSM
            case 0x58: hSpace = v(0)                                             // SHS
            case 0x59: vSpace = v(0)                                             // SVS
            case 0x61: x = v(0); y = v(1); hasPosition = true                    // ACPS
            default: break
            }
        }
    }

    private mutating func advance() {
        ensurePosition()
        x += cellW
        if x + 0.5 > areaX + areaW { newLine() }
    }

    private mutating func put(_ content: CaptionGlyph.Content) {
        let times = repeatCount == 0 ? Int.max : max(repeatCount, 1)
        repeatCount = 1
        var n = 0
        while n < times {
            ensurePosition()
            if x + cellW > areaX + areaW + 0.5 { newLine() }
            let (sx, sy) = scale
            let g = CaptionGlyph(content: content, x: x, y: y - cellH, width: cellW, height: cellH,
                                 charWidth: charW * sx, charHeight: charH * sy,
                                 foreground: fg, background: bg,
                                 underline: underline, enclosure: enclosure, isSmall: size == .small)
            // Writing over an occupied cell replaces it.
            frame.glyphs.removeAll { abs($0.x - g.x) < 0.5 && abs($0.y - g.y) < 0.5 }
            frame.glyphs.append(g)
            let row = y
            advance()
            n += 1
            if times == .max && y != row { break } // RPC 0: to the end of the line
        }
    }
}

/// Stateful caption decoder for one caption (or superimpose) ES: tracks the management data
/// (languages, format) and applies statements of the selected language to a `CaptionScreen`.
public struct CaptionDecoder: Sendable {
    public private(set) var languages: [CaptionLanguage] = []
    public private(set) var screen = CaptionScreen()
    /// Index into `languages` (0 = first language).
    public var languageIndex = 0 {
        didSet { if oldValue != languageIndex { screen.clear() } }
    }

    public init() {}

    public var frame: CaptionFrame { screen.frame }

    public mutating func reset() {
        languages = []
        screen = CaptionScreen()
    }

    /// Feeds one caption PES payload. Returns true when the display changed.
    @discardableResult
    public mutating func feed<D: Collection>(_ pesPayload: D) -> Bool where D.Element == UInt8 {
        guard let group = CaptionDataGroup(pesPayload: pesPayload) else { return false }
        if group.isManagement {
            languages = group.languages
            if let f = group.formats.first { screen.defaultFormat = f }
            return false
        }
        let wanted = languages.indices.contains(languageIndex) ? languages[languageIndex].tag + 1 : 1
        guard group.number == wanted else { return false }
        let before = screen.frame
        for unit in group.units {
            switch unit.parameter {
            case 0x30, 0x31: screen.drcs.merge(CaptionDRCS.parseUnit(unit.data)) { _, new in new }
            case 0x20: screen.apply(unit.data)
            default: break
            }
        }
        return screen.frame != before
    }
}
