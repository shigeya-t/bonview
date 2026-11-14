import AppKit
import MediaCore

/// Shown at launch when the FFmpeg libraries cannot be loaded: normally they are bundled in
/// Contents/Frameworks, so this means a damaged copy or a build against another FFmpeg
/// (FFMPEG_PREFIX) that is gone. The app quits afterwards: nothing can be decoded without them
/// (and the weak-linked symbols are NULL).
enum FFmpegMissingAlert {
    static let projectURL = URL(string: "https://github.com/shigeya-t/bonview")!

    /// Returns normally when FFmpeg is available; otherwise shows the alert and exits.
    static func checkOrExit() {
        let missing = FFmpegAvailability.missingLibraries
        guard !missing.isEmpty else { return }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "FFmpeg を読み込めません"
        alert.informativeText = """
            BonView は映像・音声のデコードに FFmpeg を使います。\
            アプリに同梱の FFmpeg が見つからないか、壊れています。
            （読み込めないライブラリ: \(missing.joined(separator: ", "))）
            """
        alert.accessoryView = makeAccessoryView()
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "GitHub を開く")

        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(projectURL)
        }
        exit(1)
    }

    /// Recovery steps with a clickable link to the project page and selectable commands.
    private static func makeAccessoryView() -> NSView {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let text = NSMutableAttributedString()
        func add(_ s: String, font: NSFont = body, link: URL? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link { attrs[.link] = link }
            text.append(NSAttributedString(string: s, attributes: attrs))
        }
        add("直し方\n", font: .boldSystemFont(ofSize: NSFont.smallSystemFontSize))
        add("・ダウンロードした BonView の場合は、アプリを入れ直してください。\n")
        add("・ソースからビルドした場合は、リポジトリで次を実行して作り直してください（FFmpeg も一緒にビルドして同梱します）:\n")
        add("    scripts/bundle.sh\n", font: mono)
        add("・FFMPEG_PREFIX で Homebrew の FFmpeg を指定してビルドした場合は、それがインストールされているか確認してください:\n")
        add("    brew install ffmpeg\n\n", font: mono)
        add("詳しくは ")
        add(projectURL.absoluteString, link: projectURL)
        add(" を参照してください。")

        let field = NSTextField(labelWithAttributedString: text)
        // Selectable + editable attributes make the .link runs clickable in a label.
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.lineBreakMode = .byWordWrapping
        field.preferredMaxLayoutWidth = 360
        field.frame.size = field.fittingSize
        field.frame.size.width = 360
        return field
    }
}
