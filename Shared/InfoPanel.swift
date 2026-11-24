import ChannelScan
import SwiftUI

/// Right-click items that open the broadcaster's homepage (built-in table) or a web search.
struct StationLinkMenu: View {
    let name: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = StationHomepage.url(for: name) {
            Button("放送局のホームページを開く（\(url.host ?? "")）") { openURL(url) }
        }
        if !name.isEmpty, let url = StationHomepage.searchURL(for: name) {
            Button("「\(name)」をWebで検索") { openURL(url) }
        }
    }
}

struct InfoPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("チューナー") {
                row("方式", model.currentProfile?.kind.label ?? "—")
                row("BonDriver", model.currentProfile?.driverName ?? "—")
                row("サーバー", model.currentProfile.map { "\($0.address):\($0.port)" } ?? "—")
                row("信号レベル", model.signalText)
            }
            Section("ストリーム") {
                row("ビットレート", String(format: "%.2f Mbps", model.status.bitrateMbps))
                row("映像", model.status.videoCodec.isEmpty ? "—" : model.status.videoCodec)
                if model.videoSize != .zero {
                    row("解像度", "\(Int(model.videoSize.width))×\(Int(model.videoSize.height))")
                }
                row("音声", model.status.audioCodec.isEmpty ? "—" : model.status.audioCodec)
                row("バッファ", String(format: "%.2f 秒", model.status.bufferedSeconds))
            }
            Section("エラー") {
                row("パケット", "\(model.status.packets)")
                row("ドロップ (CC)", "\(model.status.continuityErrors)")
                row("エラー", "\(model.status.errorPackets)")
                row("スクランブル", "\(model.status.scrambledPackets)")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).monospacedDigit().textSelection(.enabled) }
    }
}
