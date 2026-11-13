@testable import ChannelScan
import Foundation
import Testing

@Suite struct StationHomepageTests {
    private func host(_ name: String) -> String? { StationHomepage.url(for: name)?.host }

    @Test func terrestrialNames() {
        #expect(host("NHK総合1・東京") == "www.nhk.or.jp")
        #expect(host("ＮＨＫＥテレ１東京") == "www.nhk.or.jp")
        #expect(host("日テレ1") == "www.ntv.co.jp")
        #expect(host("テレビ朝日") == "www.tv-asahi.co.jp")
        #expect(host("TBS1") == "www.tbs.co.jp")
        #expect(host("テレ東1") == "www.tv-tokyo.co.jp")
        #expect(host("フジテレビ") == "www.fujitv.co.jp")
        #expect(host("TOKYO MX1") == "s.mxtv.jp")
        #expect(host("ｔｖｋ") == "www.tvk-yokohama.com")
    }

    @Test func bsBeatsTerrestrialPrefix() {
        #expect(host("BS日テレ") == "www.bs4.jp")
        #expect(host("BS-TBS") == "bs.tbs.co.jp")
        #expect(host("ＢＳフジ・１８１") == "www.bsfuji.tv")
        #expect(host("BS10スターチャンネル") == "www.star-ch.jp")
        #expect(host("WOWOWプライム") == "www.wowow.co.jp")
    }

    @Test func unknownFallsBackToSearch() {
        #expect(StationHomepage.url(for: "テスト放送") == nil)
        #expect(StationHomepage.url(for: "") == nil)
        let s = StationHomepage.searchURL(for: "テスト放送")!
        #expect(s.host == "www.google.com")
        #expect(URLComponents(url: s, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "テスト放送 公式サイト")
    }
}
