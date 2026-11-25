import Foundation
import TSCore

enum EventFormat {
    // Fixed formats: without a POSIX locale, "HH" follows the user's 12/24-hour setting on iOS.
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "M/d(E)"
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return f
    }()

    static func timeRange(_ ev: EventInfo) -> String {
        guard let s = ev.start else { return "" }
        let start = time.string(from: s)
        if let e = ev.end { return "\(start)〜\(time.string(from: e))" }
        return "\(start)〜"
    }
}
