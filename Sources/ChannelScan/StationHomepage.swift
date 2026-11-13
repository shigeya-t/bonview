import Foundation

/// Broadcaster homepages, looked up from the service name broadcast in the SDT.
///
/// SI carries no homepage URL, so this is a small built-in table of well-known Japanese
/// broadcasters (key stations, major regional stations, BS and some CS). Names are matched by
/// prefix after normalisation (NFKC, upper case, spaces and punctuation removed), longest key
/// first, so "BS日テレ" wins over "日テレ" and "BS10スターチャンネル" over "BS10".
/// Unknown stations fall back to a web search (`searchURL`).
public enum StationHomepage {
    /// (name prefixes, homepage).
    static let table: [([String], String)] = [
        // Terrestrial: NHK and Kanto key stations.
        (["NHK"], "https://www.nhk.or.jp/"),
        (["日テレ", "日本テレビ"], "https://www.ntv.co.jp/"),
        (["テレビ朝日", "テレ朝"], "https://www.tv-asahi.co.jp/"),
        (["TBS"], "https://www.tbs.co.jp/"),
        (["テレビ東京", "テレ東"], "https://www.tv-tokyo.co.jp/"),
        (["フジテレビ"], "https://www.fujitv.co.jp/"),
        (["TOKYOMX"], "https://s.mxtv.jp/"),
        (["TVK", "テレビ神奈川"], "https://www.tvk-yokohama.com/"),
        (["テレ玉", "テレビ埼玉"], "https://www.teletama.jp/"),
        (["チバテレ", "千葉テレビ"], "https://www.chiba-tv.com/"),
        // Kansai.
        (["MBS", "毎日放送"], "https://www.mbs.jp/"),
        (["ABC", "朝日放送"], "https://www.asahi.co.jp/"),
        (["関西テレビ", "カンテレ"], "https://www.ktv.jp/"),
        (["読売テレビ", "YTV"], "https://www.ytv.co.jp/"),
        (["テレビ大阪"], "https://www.tv-osaka.co.jp/"),
        (["サンテレビ"], "https://sun-tv.co.jp/"),
        (["KBS京都"], "https://www.kbs-kyoto.co.jp/"),
        // Chukyo.
        (["東海テレビ"], "https://www.tokai-tv.com/"),
        (["CBC"], "https://hicbc.com/"),
        (["中京テレビ"], "https://www.ctv.co.jp/"),
        (["メテレ", "名古屋テレビ"], "https://www.nagoyatv.com/"),
        (["テレビ愛知"], "https://tv-aichi.co.jp/"),
        // BS.
        (["BS日テレ"], "https://www.bs4.jp/"),
        (["BS朝日"], "https://www.bs-asahi.co.jp/"),
        (["BSTBS"], "https://bs.tbs.co.jp/"),
        (["BSテレ東", "BSテレビ東京"], "https://www.bs-tvtokyo.co.jp/"),
        (["BSフジ"], "https://www.bsfuji.tv/"),
        (["BS11"], "https://www.bs11.jp/"),
        (["BS12", "トゥエルビ"], "https://www.twellv.co.jp/"),
        (["WOWOW"], "https://www.wowow.co.jp/"),
        (["スターチャンネル", "BS10スター"], "https://www.star-ch.jp/"),
        (["放送大学"], "https://www.ouj.ac.jp/"),
        (["BSよしもと"], "https://www.bs-yoshimoto.co.jp/"),
        (["BSアニマックス", "アニマックス"], "https://www.animax.co.jp/"),
        (["BS釣りビジョン", "釣りビジョン"], "https://www.fishing-v.jp/"),
        (["グリーンチャンネル"], "https://www.greenchannel.jp/"),
        (["JSPORTS"], "https://www.jsports.co.jp/"),
        (["ショップチャンネル"], "https://www.shopch.jp/"),
        (["QVC"], "https://qvc.jp/"),
    ]

    /// Normalised (key, URL) pairs, longest key first.
    private static let entries: [(String, URL)] = table
        .flatMap { keys, url in keys.map { (normalize($0), URL(string: url)!) } }
        .sorted { $0.0.count > $1.0.count }

    /// Homepage of the station broadcasting `serviceName`, if known.
    public static func url(for serviceName: String) -> URL? {
        let n = normalize(serviceName)
        guard !n.isEmpty else { return nil }
        return entries.first { n.hasPrefix($0.0) }?.1
    }

    /// Web search for the station's official site.
    public static func searchURL(for serviceName: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(serviceName) 公式サイト")]
        return c.url
    }

    /// NFKC (full-width → half-width), upper case, without spaces and separators.
    static func normalize(_ s: String) -> String {
        let dropped = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "・-‐−_~〜～.･"))
        return String(String.UnicodeScalarView(
            s.precomposedStringWithCompatibilityMapping.uppercased().unicodeScalars.filter { !dropped.contains($0) }))
    }
}
