import AppKit
import MediaCore
import SwiftUI
import TSCore

/// Saving / copying the picture on screen. Main thread (menu / toolbar actions).
@MainActor
extension AppModel {
    /// The current picture at its native display size, with captions drawn on top when they
    /// are shown and the setting allows it. Superimpose is always included, as on screen.
    func captureScreenshot() -> CGImage? {
        guard let pb = player.presenter.currentFrame(), let video = FrameSnapshot.cgImage(from: pb) else { return nil }
        let withCaptions = screenshotIncludesCaptions && showCaptions && !captionFrame.glyphs.isEmpty
        guard withCaptions || !superimposeFrame.glyphs.isEmpty else { return video }
        let size = CGSize(width: video.width, height: video.height)
        let content = ZStack {
            Image(decorative: video, scale: 1).resizable()
            if withCaptions {
                switch captionStyle {
                case .broadcast: CaptionPlaneView(frame: captionFrame, videoSize: size)
                case .simple: CaptionOverlay(lines: captionFrame.lines, videoSize: size)
                }
            }
            CaptionPlaneView(frame: superimposeFrame, videoSize: size)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage ?? video
    }

    func saveScreenshot() {
        guard let image = captureScreenshot() else { return showNotice("保存できる画像がありません") }
        let format = screenshotFormat
        let folder = screenshotFolder
        let name = ScreenshotName.make(title: screenshotTitle, date: Date(), ext: format.fileExtension)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    guard let data = FrameSnapshot.encode(image, as: format) else { throw CocoaError(.fileWriteUnknown) }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = ScreenshotName.unique(folder.appendingPathComponent(name))
                    try data.write(to: url, options: .withoutOverwriting)
                    return url
                }
            }.value
            switch result {
            case .success(let url): showNotice("保存しました: \(url.lastPathComponent)")
            case .failure(let e): showNotice("保存できませんでした: \(e.localizedDescription)")
            }
        }
    }

    /// Service name when known (also for files), else the channel / file name without extension.
    private var screenshotTitle: String {
        if let svc = services.first(where: { $0.serviceID == selection?.serviceID }), !svc.name.isEmpty { return svc.name }
        if case .playingFile(let file) = state { return (file as NSString).deletingPathExtension }
        return channelTitle
    }

    func copyScreenshot() {
        guard let image = captureScreenshot() else { return showNotice("コピーできる画像がありません") }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        showNotice("画像をコピーしました")
    }

    func revealScreenshotFolder() {
        try? FileManager.default.createDirectory(at: screenshotFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(screenshotFolder)
    }

    func showNotice(_ text: String) {
        noticeGeneration += 1
        let gen = noticeGeneration
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.noticeGeneration == gen { self?.notice = nil }
        }
    }
}

/// File names like `NHK総合1・東京_20261113-213045.png`.
enum ScreenshotName {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func make(title: String, date: Date, ext: String) -> String {
        // "/" and ":" are path separators (Finder shows ":" as "/"); also drop control characters.
        var name = String(title.unicodeScalars.map { s -> Character in
            if s == "/" || s == ":" || s == "\\" || CharacterSet.controlCharacters.contains(s) { return "_" }
            return Character(s)
        }).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        if name.isEmpty { name = "BonView" }
        return "\(name.prefix(80))_\(formatter.string(from: date)).\(ext)"
    }

    /// `name.png`, or `name-2.png`, `name-3.png`… if it already exists.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
