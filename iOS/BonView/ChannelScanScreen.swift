import BonDriver
import ChannelScan
import SwiftUI

/// Channel scan sheet.
struct ChannelScanScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UInt32> = []

    var body: some View {
        NavigationStack {
            Group {
                if let scan = model.scan {
                    progress(scan)
                } else {
                    setup
                }
            }
            .navigationTitle("チャンネルスキャン")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if model.scan?.finished == true { model.scan = nil }
            // Default: spaces never scanned before (or all, on the first scan).
            let scanned = Set(model.scannedChannels.map(\.space))
            let fresh = model.spaces.map(\.index).filter { !scanned.contains($0) }
            selected = Set(fresh.isEmpty ? model.spaces.map(\.index) : fresh)
        }
    }

    private var setup: some View {
        Form {
            Section {
                ForEach(model.spaces) { space in
                    Toggle(isOn: Binding(get: { selected.contains(space.index) },
                                         set: { if $0 { selected.insert(space.index) } else { selected.remove(space.index) } })) {
                        VStack(alignment: .leading) {
                            Text(space.name)
                            let n = model.scannedChannels.filter { $0.space == space.index }.count
                            Text("\(space.channels.count) ch" + (n > 0 ? "・前回 \(n) 件" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("選択したチューニング空間のチャンネルを順に選局し、放送されている局を探します。視聴は一時停止します。")
            }
            if !model.scannedChannels.isEmpty {
                Section {
                    Button("スキャン結果を消去", role: .destructive) { model.clearScanResult() }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("開始") { model.startScan(spaces: selected) }
                    .disabled(selected.isEmpty || model.state != .connected)
            }
        }
    }

    private func progress(_ scan: AppModel.ScanProgress) -> some View {
        List {
            Section {
                ProgressView(value: Double(scan.index), total: Double(max(scan.total, 1))) {
                    if scan.finished {
                        Text(scan.cancelled ? "中止しました（結果は保存していません）" : "完了: \(scan.found.count) チャンネルで放送が見つかりました")
                    } else {
                        Text("\(scan.current) を確認中… (\(scan.index + 1)/\(scan.total))")
                    }
                }
            }
            Section("見つかったチャンネル") {
                ForEach(scan.found) { ch in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(ch.channelName).monospacedDigit()
                            Text(ch.spaceName).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "TSID 0x%04X", ch.transportStreamID)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(ch.services.filter(\.isViewable).map(\.displayName).joined(separator: "、"))
                            .font(.callout)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if scan.finished {
                    Button("閉じる") { model.scan = nil; dismiss() }
                } else {
                    Button("中止") { model.cancelScan() }
                }
            }
        }
    }
}
