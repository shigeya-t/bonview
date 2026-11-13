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

/// Text model of the caption plane: rows of text in display order. Layout (columns, colours,
/// exact sizes) is not modelled yet; small-size text (ruby) is dropped.
public struct CaptionScreen: Equatable, Sendable {
    /// Row key → text. Keys are character rows (APS) or dot positions (ACPS); only their order matters.
    private var rows: [Int: String] = [:]
    private var row = 0

    public init() {}

    /// Visible lines, top to bottom.
    public var lines: [String] {
        rows.sorted { $0.key < $1.key }
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public mutating func clear() {
        rows.removeAll()
        row = 0
    }

    /// Applies one statement body (data unit 0x20).
    public mutating func apply(_ statement: [UInt8]) {
        var d = ARIBString.Decoder.caption()
        _ = d.run(statement)
        var size = ARIBString.CharacterSize.normal
        for token in d.finishTokens() {
            switch token {
            case .text(let s):
                if size != .small { rows[row, default: ""] += s }
            case .control(let c):
                switch c {
                case .clearScreen: clear()
                case .newLine, .down: row += 1
                case .up: row -= 1
                case .position(let r, _): row = r
                // ×1000 so that APR/APD after ACPS still sorts between this line and the next one.
                case .dotPosition(_, let y): row = y * 1000
                case .cancelLine: rows[row] = nil
                case .forward: if rows[row]?.isEmpty == false { rows[row]! += " " }
                case .back: break
                case .size(let s): size = s
                }
            }
        }
    }
}

/// Stateful caption decoder for one caption ES: tracks the management data (languages) and
/// applies statements of the selected language to a `CaptionScreen`.
public struct CaptionDecoder: Sendable {
    public private(set) var languages: [CaptionLanguage] = []
    public private(set) var screen = CaptionScreen()
    /// Index into `languages` (0 = first language).
    public var languageIndex = 0

    public init() {}

    public mutating func reset() {
        languages = []
        screen.clear()
    }

    /// Feeds one caption PES payload. Returns true when the visible text changed.
    @discardableResult
    public mutating func feed<D: Collection>(_ pesPayload: D) -> Bool where D.Element == UInt8 {
        guard let group = CaptionDataGroup(pesPayload: pesPayload) else { return false }
        if group.isManagement {
            languages = group.languages
            return false
        }
        let wanted = languages.indices.contains(languageIndex) ? languages[languageIndex].tag + 1 : 1
        guard group.number == wanted else { return false }
        let before = screen.lines
        for unit in group.units where unit.parameter == 0x20 {
            screen.apply(unit.data)
        }
        return screen.lines != before
    }
}
