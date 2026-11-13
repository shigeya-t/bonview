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
            Toggle("インターレース解除 (bwdif, 59.94p)", isOn: $model.deinterlace)
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
            let url = try result.get()
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            // Windows .ini files are usually Shift_JIS.
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) ?? ""
            let name = url.deletingPathExtension().lastPathComponent
            let p: ServerProfile
            if TunnelConfig.looksLikeTunnelConfig(text) {
                // BonDriver_hoge.ini of BonDriver_Tunnel (origin defaults to the file name).
                p = ServerProfile(name: name, kind: .tunnel, tunnel: try TunnelConfig.parse(text, fileName: url.lastPathComponent))
            } else {
                p = ServerProfile(name: name, kind: .proxy, config: try ProxyConfig.parse(text))
            }
            model.profiles.append(p)
            selection = p.id
        } catch {
            importError = String(describing: error)
        }
    }
}

private struct ProfileEditor: View {
    @Binding var profile: ServerProfile

    var body: some View {
        Form {
            TextField("表示名", text: $profile.name)
            Picker("接続方式", selection: $profile.kind) {
                ForEach(ServerProfile.Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            switch profile.kind {
            case .proxy: proxyFields
            case .tunnel: tunnelFields
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var proxyFields: some View {
        Section("BonDriverProxy / BonDriverProxyEx サーバー") {
            TextField("アドレス", text: $profile.config.address)
            TextField("ポート", value: $profile.config.port, format: .number.grouping(.never))
            TextField("BonDriver", text: $profile.config.bonDriver, prompt: Text("BonDriver_PT3-T.dll / ProxyExのグループ名"))
            Stepper("接続タイムアウト: \(profile.config.connectTimeout) 秒", value: $profile.config.connectTimeout, in: 1...120)
            Picker("チャンネルロック", selection: $profile.config.channelLock) {
                Text("なし (0)").tag(UInt8(0))
                Text("1").tag(UInt8(1))
                Text("2").tag(UInt8(2))
                Text("3").tag(UInt8(3))
                Text("占有 (255)").tag(UInt8(255))
            }
            Toggle("サーバーにスクランブル解除を要求 (B25)", isOn: $profile.config.requestB25)
                .help("HaijinW 版 BonDriverProxyEx 用。サーバーの ini も B25=1 のときだけ解除されます。他のサーバーでは無視されます")
        }
        Section("Wake on LAN") {
            Toggle("接続前にマジックパケットを送信", isOn: $profile.config.useMagicPacket)
            TextField("MACアドレス", text: Binding(
                get: { profile.config.macAddress.map { $0.map { String(format: "%02X", $0) }.joined(separator: "-") } ?? "" },
                set: { profile.config.macAddress = ProxyConfig.parseMAC($0) }), prompt: Text("AA-BB-CC-DD-EE-FF"))
            TextField("送信先アドレス", text: Binding(
                get: { profile.config.magicPacketAddress ?? "" },
                set: { profile.config.magicPacketAddress = $0.isEmpty ? nil : $0 }), prompt: Text(profile.config.address))
        }
    }

    @ViewBuilder private var tunnelFields: some View {
        Section {
            TextField("アドレス", text: $profile.tunnel.address)
            TextField("ポート", value: $profile.tunnel.port, format: .number.grouping(.never))
            TextField("接続先BonDriver (ORIGIN)", text: $profile.tunnel.origin, prompt: Text("PT3-T"))
            Stepper("接続タイムアウト: \(profile.tunnel.connectTimeout) 秒", value: $profile.tunnel.connectTimeout, in: 1...120)
            Stepper("送受信タイムアウト: \(profile.tunnel.sendRecvTimeout) 秒", value: $profile.tunnel.sendRecvTimeout, in: 1...120)
        } header: {
            Text("BonDriverTunnel サーバー")
        } footer: {
            Text("ORIGIN はサーバー側の BonDriver_*.dll の * 部分です（BonDriverTunnel.exe と同じフォルダに置いたもの）。BonDriverLocalProxy と多段接続する場合は Proxy0_PT3-T のように指定します。チャンネルロックはありません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
