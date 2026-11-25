import BonDriver
import MediaCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings sheet: servers, channels, playback, programme guide, files and licences.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing: Importing?
    @State private var importError: String?
    @AppStorage("backgroundPlayback") private var backgroundPlayback = true

    private enum Importing {
        case config, tsFile
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    ForEach($model.profiles) { $profile in
                        NavigationLink {
                            ProfileScreen(profile: $profile)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayName)
                                    Text("\(profile.address):\(String(profile.port))  \(profile.driverName)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if profile.id == model.currentProfile?.id, model.state == .connected {
                                    Text("接続中").font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    .onDelete { model.profiles.remove(atOffsets: $0) }
                    Button("サーバーを追加") { add() }
                    Button("設定ファイルから読み込む…") { importing = .config }
                } header: {
                    Text("BonDriver サーバー")
                } footer: {
                    Text("BonDriver_Proxy.ini / .conf や BonDriver_Tunnel の ini を読み込めます。")
                }

                Section("チャンネル") {
                    Button("チャンネルスキャン…") {
                        dismiss()
                        // Present the scan sheet once this one has gone.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.showScanSheet = true }
                    }
                    .disabled(model.state != .connected || model.isScanning)
                    if model.state == .connected {
                        Button("切断", role: .destructive) { model.disconnect() }
                    } else {
                        Button("接続") { model.connect() }.disabled(model.profiles.isEmpty)
                    }
                }

                Section("再生") {
                    Toggle("バックグラウンドで音声を再生", isOn: $backgroundPlayback)
                    Toggle("H.264 / HEVC をハードウェアデコード", isOn: $model.hardwareDecoding)
                    Picker("インターレース解除", selection: $model.deinterlace) {
                        Text("オフ").tag(DeinterlaceMode.off)
                        Text("29.97p (負荷 小)").tag(DeinterlaceMode.frameRate)
                        Text("59.94p (なめらか)").tag(DeinterlaceMode.fieldRate)
                    }
                    Picker("字幕の表示方法", selection: $model.captionStyle) {
                        ForEach(CaptionStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Toggle("接続中に自動で取得 (6時間ごと)", isOn: $model.epgAutoGrab)
                    if model.isGrabbingEPG {
                        Button("番組表の取得を中止") { model.cancelEPGGrab() }
                    } else {
                        Button("番組表を取得") { model.startEPGGrab() }
                            .disabled(model.state != .connected || model.isScanning || model.scannedChannels.isEmpty)
                    }
                    Button("番組表のデータを消去", role: .destructive) { model.clearEPG() }
                        .disabled(model.currentProfile == nil)
                } header: {
                    Text("番組表")
                } footer: {
                    Text("サーバーに別の接続を開き、チャンネルを切り替えながら取得します。視聴には影響しませんが、空きチューナーが1つ必要です。")
                }

                CloudSyncSection()

                Section("ファイル") {
                    Button("TSファイルを再生…") { importing = .tsFile }
                }

                Section {
                    NavigationLink("ライセンス") { LicensesScreen() }
                    LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                          allowedContentTypes: importTypes) { result in
                handleImport(result)
            }
            .alert("読み込めませんでした", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK") {}
            } message: { Text(importError ?? "") }
        }
    }

    private var importTypes: [UTType] {
        switch importing {
        case .tsFile: return [.mpeg2TransportStream, UTType(filenameExtension: "m2ts") ?? .data, .data]
        default: return [.data, .plainText, .item]
        }
    }

    private func add() {
        var p = ServerProfile.sample
        p.id = UUID()
        model.profiles.append(p)
    }

    private func handleImport(_ result: Result<URL, Error>) {
        let kind = importing
        do {
            let url = try result.get()
            switch kind {
            case .tsFile:
                // Played straight from the picked location (security-scoped while the reader runs).
                _ = url.startAccessingSecurityScopedResource()
                model.openFile(url)
                dismiss()
            default:
                model.profiles.append(try ServerProfile.imported(from: url))
            }
        } catch {
            importError = String(describing: error)
        }
    }
}

/// One server: editor plus connect / delete.
private struct ProfileScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var profile: ServerProfile

    var body: some View {
        VStack(spacing: 0) {
            ProfileEditor(profile: $profile)
        }
        .navigationTitle(profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("接続") { model.connect(profile) }
            }
        }
    }
}

/// Licences of BonView and the bundled third-party code.
private struct LicensesScreen: View {
    private struct Item: Identifiable {
        var id: String { title }
        var title: String
        var note: String
        var files: [String]
    }

    private var items: [Item] {
        [
            Item(title: "BonView", note: "MIT License", files: ["LICENSE"]),
            Item(title: "FFmpeg",
                 note: "LGPL 2.1 以降。映像・音声のデコードに使っています。ソースコードは https://ffmpeg.org/releases/ から入手でき、BonView のリリースにも同梱しています。",
                 files: ["FFmpeg/LICENSE.md", "FFmpeg/COPYING.LGPLv2.1"]),
            Item(title: "libaribcaption", note: "ARIB 外字の Unicode 対応表 (ISC License)", files: ["Licenses/libaribcaption.txt"]),
            Item(title: "BonDriverProxy_Linux / BonDriverTunnel", note: "プロトコルの実装は各プロジェクト（MIT License）を参考にしています。", files: []),
        ]
    }

    var body: some View {
        List(items) { item in
            if item.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                    Text(item.note).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(item.note).font(.callout)
                            ForEach(item.files, id: \.self) { f in
                                Text(Self.text(f)).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        .padding()
                    }
                    .navigationTitle(item.title)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                        Text(item.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle("ライセンス")
    }

    private static func text(_ path: String) -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(path),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "(\(path) が見つかりません)" }
        return s
    }
}
