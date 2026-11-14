import AppKit
import MediaCore

/// Shown at launch when the Homebrew FFmpeg libraries cannot be loaded. The app quits afterwards:
/// nothing can be decoded without them (and the weak-linked symbols are NULL).
enum FFmpegMissingAlert {
    static let projectURL = URL(string: "https://github.com/shigeya-t/bonview")!
    static let homebrewURL = URL(string: "https://brew.sh/ja/")!
    static let installCommand = "brew install ffmpeg"

    /// Returns normally when FFmpeg is available; otherwise shows the alert and exits.
    static func checkOrExit() {
        let missing = FFmpegAvailability.missingLibraries
        guard !missing.isEmpty else { return }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "FFmpeg が見つかりません"
        alert.informativeText = """
            BonView は映像・音声のデコードに Homebrew の FFmpeg を使います。\
            FFmpeg がインストールされていないか、BonView のビルド時とバージョンが異なります。
            （読み込めないライブラリ: \(missing.joined(separator: ", "))）
            """
        alert.accessoryView = makeAccessoryView()
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "コマンドをコピーして終了")
        alert.addButton(withTitle: "GitHub を開く")

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(installCommand, forType: .string)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(projectURL)
        default:
            break
        }
        exit(1)
    }

    /// Install steps with clickable links (Homebrew, the project page) and a selectable command.
    private static func makeAccessoryView() -> NSView {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let text = NSMutableAttributedString()
        func add(_ s: String, font: NSFont = body, link: URL? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link { attrs[.link] = link }
            text.append(NSAttributedString(string: s, attributes: attrs))
        }
        add("インストール方法\n", font: .boldSystemFont(ofSize: NSFont.smallSystemFontSize))
        add("1. Homebrew をインストールします（未導入の場合）: ")
        add(homebrewURL.absoluteString, link: homebrewURL)
        add("\n2. ターミナルで次のコマンドを実行します:\n")
        add("    \(installCommand)\n", font: mono)
        add("3. BonView を起動し直します。\n\n")
        add("FFmpeg を更新した後にこの画面が出る場合は、BonView をビルドし直してください。\n")
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
