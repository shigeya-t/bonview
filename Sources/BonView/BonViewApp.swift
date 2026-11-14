import AppKit
import MediaCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct BonViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // FFmpeg is weak-linked: without it, explain how to install it and quit before anything decodes.
        FFmpegMissingAlert.checkOrExit()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("BonView", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 480, minHeight: 300)
                .onAppear {
                    AppDelegate.openURL = { [model] in model.openFile($0) }
                    // `BonView file.ts` plays the file; otherwise reconnect to the last BonDriver.
                    if let path = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".ts") || $0.hasSuffix(".m2ts") }) {
                        model.openFile(URL(fileURLWithPath: path))
                    } else if let url = AppDelegate.pendingURL {
                        model.openFile(url)
                    } else if model.currentProfile != nil, model.state == .idle {
                        model.connect()
                    }
                }
                // Closing the window stops playback (audio would otherwise keep going while the
                // app stays alive, e.g. with the Settings window open). Reopening reconnects.
                .onDisappear { model.disconnect() }
        }
        .defaultSize(width: 1240, height: 600)
        .commands { AppCommands(model: model) }

        Window("番組表", id: "guide") {
            ProgramGuideView()
                .environment(model)
                .frame(minWidth: 480, minHeight: 300)
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openURL: ((URL) -> Void)?
    static var pendingURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let open = Self.openURL { open(url) } else { Self.pendingURL = url }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also behave as a regular app when launched via `swift run` (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("TSファイルを開く…") { openFile() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("スクリーンショットを保存") { model.saveScreenshot() }.keyboardShortcut("s")
            Button("スクリーンショットをコピー") { model.copyScreenshot() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("スクリーンショットのフォルダを開く") { model.revealScreenshotFolder() }
        }
        CommandMenu("チューナー") {
            Button("接続") { model.connect() }.keyboardShortcut("k")
            Button("切断") { model.disconnect() }.keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("前のチャンネル") { model.stepChannel(-1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("次のチャンネル") { model.stepChannel(1) }.keyboardShortcut(.downArrow, modifiers: .command)
            Button("チャンネルスキャン…") { model.showScanSheet = true }
                .disabled(model.state != .connected || model.isScanning)
            if model.isGrabbingEPG {
                Button("番組表の取得を中止") { model.cancelEPGGrab() }
            } else {
                Button("番組表を取得") { model.startEPGGrab() }
                    .disabled(model.state != .connected || model.isScanning || model.scannedChannels.isEmpty)
            }
            Divider()
            Menu("BonDriver") {
                ForEach(model.profiles) { p in
                    Button(p.displayName) { model.connect(p) }
                }
            }
        }
        CommandMenu("音声") {
            Button(model.isMuted ? "消音を解除" : "消音") { model.isMuted.toggle() }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("音量を上げる") { model.volume = min(1, model.volume + 0.05) }.keyboardShortcut("=", modifiers: .command)
            Button("音量を下げる") { model.volume = max(0, model.volume - 0.05) }.keyboardShortcut("-", modifiers: .command)
            Divider()
            Picker("音声切替", selection: Binding(get: { model.audioIndex }, set: { model.audioIndex = $0 })) {
                let labels = model.audioStreamLabels
                ForEach(labels.indices, id: \.self) { Text(labels[$0]).tag($0) }
            }
            .disabled((model.selection?.audioStreams.count ?? 0) < 2)
            Picker("二重音声", selection: Binding(get: { model.dualMono }, set: { model.dualMono = $0 })) {
                ForEach([DualMonoMode.main, .sub, .both], id: \.self) { Text(model.dualMonoLabel($0)).tag($0) }
            }
            .disabled(!model.isDualMono)
        }
        CommandGroup(after: .toolbar) {
            Menu("画面サイズ") {
                ForEach(Array(AppModel.videoScales.enumerated()), id: \.offset) { i, scale in
                    Button(scale.label) { model.setVideoScale(scale) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }
        CommandGroup(after: .sidebar) {
            Button(model.showCaptions ? "字幕を隠す" : "字幕を表示") { model.showCaptions.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Menu("字幕") {
                Picker("表示方法", selection: Binding(get: { model.captionStyle }, set: { model.captionStyle = $0 })) {
                    ForEach(CaptionStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                if model.captionLanguages.count > 1 {
                    Divider()
                    Picker("言語", selection: Binding(get: { model.captionLanguageIndex }, set: { model.captionLanguageIndex = $0 })) {
                        ForEach(Array(model.captionLanguages.enumerated()), id: \.offset) { i, l in Text(l.displayName).tag(i) }
                    }
                    .pickerStyle(.inline)
                }
            }
            Button(model.showPanel ? "パネルを隠す" : "パネルを表示") { model.showPanel.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("番組表") { openWindow(id: "guide") }
                .keyboardShortcut("e")
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ts") ?? .data, UTType(filenameExtension: "m2ts") ?? .data, .mpeg2TransportStream]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { model.openFile(url) }
    }
}
