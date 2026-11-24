import BonDriver
import SwiftUI

/// Settings of one server profile (macOS settings window, iOS server list).
struct ProfileEditor: View {
    @Binding var profile: ServerProfile

    var body: some View {
        Form {
            Field("表示名") {
                TextField("表示名", text: $profile.name)
            }
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
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
    }

    @ViewBuilder private var proxyFields: some View {
        Section("BonDriverProxy / BonDriverProxyEx サーバー") {
            Field("アドレス") {
                TextField("アドレス", text: $profile.config.address).hostKeyboard()
            }
            Field("ポート") {
                TextField("ポート", value: $profile.config.port, format: .number.grouping(.never)).portKeyboard()
            }
            Field("BonDriver") {
                TextField("BonDriver", text: $profile.config.bonDriver, prompt: Text("BonDriver_PT3-T.dll / ProxyExのグループ名"))
            }
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
            Field("MACアドレス") {
                TextField("MACアドレス", text: Binding(
                    get: { profile.config.macAddress.map { $0.map { String(format: "%02X", $0) }.joined(separator: "-") } ?? "" },
                    set: { profile.config.macAddress = ProxyConfig.parseMAC($0) }), prompt: Text("AA-BB-CC-DD-EE-FF"))
                    .hostKeyboard()
            }
            Field("送信先アドレス") {
                TextField("送信先アドレス", text: Binding(
                    get: { profile.config.magicPacketAddress ?? "" },
                    set: { profile.config.magicPacketAddress = $0.isEmpty ? nil : $0 }), prompt: Text(profile.config.address))
                    .hostKeyboard()
            }
        }
    }

    @ViewBuilder private var tunnelFields: some View {
        Section {
            Field("アドレス") {
                TextField("アドレス", text: $profile.tunnel.address).hostKeyboard()
            }
            Field("ポート") {
                TextField("ポート", value: $profile.tunnel.port, format: .number.grouping(.never)).portKeyboard()
            }
            Field("接続先BonDriver (ORIGIN)") {
                TextField("接続先BonDriver (ORIGIN)", text: $profile.tunnel.origin, prompt: Text("PT3-T"))
            }
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

/// iOS forms don't show a text field's label, only its value; put the label beside the field as on
/// macOS.
private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        #if os(iOS)
        LabeledContent(label) { content.multilineTextAlignment(.trailing) }
        #else
        content
        #endif
    }
}

private extension View {
    /// ASCII keyboard for host names and addresses (iOS would otherwise offer kana input).
    func hostKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }

    func portKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
