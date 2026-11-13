import Foundation
import Testing
@testable import TSCore

@Suite struct AudioComponentTests {
    /// Audio component descriptor body. `text` is ASCII, sent via ESC ( J.
    static func body(tag: UInt8, type: UInt8, main: Bool = false, langs: [String], text: String = "") -> [UInt8] {
        let flags: UInt8 = (langs.count > 1 ? 0x80 : 0) | (main ? 0x40 : 0) | 0x3F
        var b: [UInt8] = [0xF2, type, tag, 0x0F, 0xFF, flags]
        for l in langs { b += Array(l.utf8) }
        if !text.isEmpty { b += [0x1B, 0x28, 0x4A] + Array(text.utf8) }
        return b
    }

    static func stream(_ tag: UInt8) -> ElementaryStreamInfo {
        ElementaryStreamInfo(streamType: 0x0F, pid: 0x110 + UInt16(tag), componentTag: tag)
    }

    @Test func parsesDescriptor() throws {
        let a = try #require(AudioComponent(descriptor: Self.body(tag: 0x10, type: 0x02, main: true, langs: ["jpn", "eng"], text: "BILINGUAL")))
        #expect(a.componentTag == 0x10 && a.isDualMono && a.isMainComponent)
        #expect(a.languages == ["jpn", "eng"])
        #expect(a.text == "BILINGUAL")
        #expect(a.dualMonoNames?.main == "日本語" && a.dualMonoNames?.sub == "英語")

        let s = try #require(AudioComponent(descriptor: Self.body(tag: 0x11, type: 0x03, langs: ["jpn"])))
        #expect(s.languages == ["jpn"] && s.text.isEmpty && !s.isDualMono && s.dualMonoNames == nil)
        #expect(AudioComponent(descriptor: [0xF2, 0x03]) == nil)
    }

    @Test func eitCarriesAudioComponents() throws {
        let d1 = Self.body(tag: 0x10, type: 0x03, langs: ["jpn"], text: "MAIN")
        let d2 = Self.body(tag: 0x11, type: 0x03, langs: ["jpn"], text: "AD")
        let descs = [0xC4, UInt8(d1.count)] + d1 + [0xC4, UInt8(d2.count)] + d2
        var body: [UInt8] = [0x7F, 0xE1, 0x7F, 0xE1, 0x01, 0x4E]
        body += [0x00, 0x01] + ProgramCacheTests.noon + [0x01, 0x00, 0x00]
            + [0x80 | UInt8(descs.count >> 8), UInt8(descs.count & 0xFF)] + descs
        let eit = try #require(EIT(TSBuilder.section(tableID: 0x4E, ext: 0x400, sectionNumber: 0, body: body)))
        #expect(eit.events.first?.audioComponents.map(\.text) == ["MAIN", "AD"])
    }

    @Test func labels() {
        let streams = [Self.stream(0x10), Self.stream(0x11)]
        // Component text wins.
        #expect(AudioComponent.labels(for: streams, components: [
            AudioComponent(componentTag: 0x10, componentType: 3, languages: ["jpn"], text: "MAIN"),
            AudioComponent(componentTag: 0x11, componentType: 3, languages: ["jpn"], text: "A\nB"),
        ]) == ["MAIN", "A/B"])
        // No text: language when the streams differ.
        #expect(AudioComponent.labels(for: streams, components: [
            AudioComponent(componentTag: 0x10, componentType: 3, languages: ["jpn"]),
            AudioComponent(componentTag: 0x11, componentType: 3, languages: ["eng"]),
        ]) == ["日本語", "英語"])
        // Same language / no EIT: numbered.
        #expect(AudioComponent.labels(for: streams, components: [
            AudioComponent(componentTag: 0x10, componentType: 3, languages: ["jpn"]),
            AudioComponent(componentTag: 0x11, componentType: 3, languages: ["jpn"]),
        ]) == ["音声1", "音声2"])
        #expect(AudioComponent.labels(for: streams, components: []) == ["音声1", "音声2"])
    }

    @Test func decodesOldStores() throws {
        let ev = EventInfo(serviceID: 1, eventID: 2, start: nil, duration: nil, title: "T", text: "")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ev)) as! [String: Any]
        json.removeValue(forKey: "audioComponents")
        let back = try JSONDecoder().decode(EventInfo.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.audioComponents.isEmpty && back.title == "T")
    }
}
