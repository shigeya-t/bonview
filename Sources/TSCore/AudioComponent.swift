import Foundation

/// ARIB audio component descriptor (0xC4, carried in the EIT): describes one audio ES of an
/// event, matched to the PMT by component_tag.
public struct AudioComponent: Equatable, Sendable, Codable {
    public var componentTag: UInt8
    /// 0x01 mono, 0x02 dual mono (1/0+1/0), 0x03 stereo, … 0x09 5.1.
    public var componentType: UInt8
    public var isMainComponent: Bool
    /// ISO 639-2 codes, e.g. ["jpn"] or ["jpn", "eng"] (ES_multi_lingual_flag: dual mono).
    public var languages: [String]
    /// text_char, e.g. "主音声", "解説", "日本語\\n英語".
    public var text: String

    public init(componentTag: UInt8, componentType: UInt8, isMainComponent: Bool = false,
                languages: [String], text: String = "") {
        self.componentTag = componentTag
        self.componentType = componentType
        self.isMainComponent = isMainComponent
        self.languages = languages
        self.text = text
    }

    /// Parses the descriptor body (after tag and length).
    public init?(descriptor b: [UInt8]) {
        guard b.count >= 9 else { return nil }
        componentType = b[1]
        componentTag = b[2]
        let multiLingual = b[5] & 0x80 != 0
        isMainComponent = b[5] & 0x40 != 0
        func lang(_ i: Int) -> String { String(decoding: b[i..<(i + 3)], as: UTF8.self) }
        languages = [lang(6)]
        var t = 9
        if multiLingual, b.count >= 12 { languages.append(lang(9)); t = 12 }
        text = ARIBString.decode(b[t...])
    }

    public var isDualMono: Bool { componentType == 0x02 }

    /// Japanese name of an ISO 639-2 code ("jpn" → "日本語"); unknown codes are shown as is.
    public static func languageName(_ code: String) -> String {
        switch code.lowercased() {
        case "jpn": return "日本語"
        case "eng": return "英語"
        case "deu", "ger": return "ドイツ語"
        case "fra", "fre": return "フランス語"
        case "ita": return "イタリア語"
        case "spa": return "スペイン語"
        case "por": return "ポルトガル語"
        case "rus": return "ロシア語"
        case "zho", "chi": return "中国語"
        case "kor": return "韓国語"
        case "etc": return "その他"
        default: return code.uppercased()
        }
    }

    /// Button labels for the audio ES of a service: the component text, else the language when the
    /// streams differ in language, else "音声N".
    public static func labels(for streams: [ElementaryStreamInfo], components: [AudioComponent]) -> [String] {
        let matched = streams.map { s in components.first { s.componentTag != nil && $0.componentTag == s.componentTag } }
        let langs = matched.map { $0?.languages.first }
        let languagesDiffer = Set(langs.compactMap { $0 }).count > 1
        return streams.indices.map { i in
            if let c = matched[i] {
                let text = c.text.split(whereSeparator: \.isNewline).joined(separator: "/")
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
                if languagesDiffer, let l = langs[i] { return languageName(l) }
            }
            return "音声\(i + 1)"
        }
    }

    /// Labels for the 主/副 dual-mono switch, from the two languages when they differ.
    public var dualMonoNames: (main: String, sub: String)? {
        guard isDualMono, languages.count == 2, languages[0] != languages[1] else { return nil }
        return (Self.languageName(languages[0]), Self.languageName(languages[1]))
    }
}
