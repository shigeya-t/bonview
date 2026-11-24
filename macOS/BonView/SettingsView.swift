import AppKit
import BonDriver
import MediaCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            ServerSettings().tabItem { Label("BonDriver", systemImage: "antenna.radiowaves.left.and.right") }
            PlaybackSettings().tabItem { Label("再生", systemImage: "play.rectangle") }
        }
        .frame(width: 620, height: 440)
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("H.264 / HEVC をハードウェアデコードする (VideoToolbox)", isOn: $model.hardwareDecoding)
            Picker("インターレース解除 (bwdif)", selection: $model.deinterlace) {
                Text("オフ").tag(DeinterlaceMode.off)
                Text("29.97p (CPU 負荷 小)").tag(DeinterlaceMode.frameRate)
                Text("59.94p (なめらか)").tag(DeinterlaceMode.fieldRate)
            }
            Section("スクリーンショット") {
                LabeledContent("保存先") {
                    HStack {
                        Text(model.screenshotFolder.path(percentEncoded: false))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(model.screenshotFolder.path(percentEncoded: false))
                        Button("変更…") { chooseFolder() }
                    }
                }
                Picker("形式", selection: $model.screenshotFormat) {
                    Text("PNG").tag(FrameSnapshot.Format.png)
                    Text("JPEG").tag(FrameSnapshot.Format.jpeg)
                }
                Toggle("表示中の字幕を含める", isOn: $model.screenshotIncludesCaptions)
            }
            CloudSyncSection()
            Section("番組表") {
                Toggle("接続中に番組表を自動で取得する (6時間ごと)", isOn: $model.epgAutoGrab)
                Text("BonDriver サーバーに別の接続を開き、チャンネルを切り替えながら取得します。視聴には影響しませんが、空きチューナーが1つ必要です。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("番組表のデータを消去") { model.clearEPG() }
                    .disabled(model.currentProfile == nil)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.screenshotFolder
        panel.prompt = "選択"
        if panel.runModal() == .OK, let url = panel.url { model.screenshotFolder = url }
    }
}

private struct ServerSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.profiles) { p in Text(p.displayName).tag(p.id) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus") }.help("追加")
                    Button { remove() } label: { Image(systemName: "minus") }.help("削除").disabled(selection == nil)
                    Spacer()
                    Button("読み込み…") { importing = true }
                        .help("BonDriver_Proxy.ini / .conf を読み込む")
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 210)
            Divider()
            if let idx = model.profiles.firstIndex(where: { $0.id == selection }) {
                ProfileEditor(profile: $model.profiles[idx])
            } else {
                Text("左のリストから選択するか、＋で追加してください")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? model.currentProfile?.id }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText, .item]) { result in
            importConfig(result)
        }
        .alert("読み込めませんでした", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: { Text(importError ?? "") }
    }

    private func add() {
        var p = ServerProfile.sample
        p.id = UUID()
        model.profiles.append(p)
        selection = p.id
    }

    private func remove() {
        model.profiles.removeAll { $0.id == selection }
        selection = model.profiles.first?.id
    }

    private func importConfig(_ result: Result<URL, Error>) {
        do {
            let p = try ServerProfile.imported(from: try result.get())
            model.profiles.append(p)
            selection = p.id
        } catch {
            importError = String(describing: error)
        }
    }
}
