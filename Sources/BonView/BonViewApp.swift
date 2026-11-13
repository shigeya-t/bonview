import AppKit
import MediaCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct BonViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("TSファイルを開く…") { openFile() }.keyboardShortcut("o")
        }
        CommandMenu("チューナー") {
            Button("接続") { model.connect() }.keyboardShortcut("k")
            Button("切断") { model.disconnect() }.keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("前のチャンネル") { model.stepChannel(-1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("次のチャンネル") { model.stepChannel(1) }.keyboardShortcut(.downArrow, modifiers: .command)
            Button("チャンネルスキャン…") { model.showScanSheet = true }
                .disabled(model.state != .connected || model.isScanning)
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
            Picker("二重音声", selection: Binding(get: { model.dualMono }, set: { model.dualMono = $0 })) {
                Text("主+副").tag(DualMonoMode.both)
                Text("主音声").tag(DualMonoMode.main)
                Text("副音声").tag(DualMonoMode.sub)
            }
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
            Button(model.showPanel ? "パネルを隠す" : "パネルを表示") { model.showPanel.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ts") ?? .data, UTType(filenameExtension: "m2ts") ?? .data, .mpeg2TransportStream]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { model.openFile(url) }
    }
}
