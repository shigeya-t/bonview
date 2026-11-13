import BonDriver
import MediaCore
import SwiftUI
import TSCore

/// Side panel: 番組情報 / チャンネル / サービス / 情報.
struct SidePanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case program = "番組"
        case channel = "チャンネル"
        case service = "サービス"
        case info = "情報"
        var id: Self { self }
    }

    @AppStorage("panelTab") private var tab: Tab = .channel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .program: ProgramPanel()
            case .channel: ChannelPanel()
            case .service: ServicePanel()
            case .info: InfoPanel()
            }
        }
    }
}

private struct ProgramPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.presentEvent == nil && model.followingEvent == nil {
                    Text("番組情報を取得していません").foregroundStyle(.secondary)
                }
                if let ev = model.presentEvent { event(ev, heading: "現在の番組") }
                if let ev = model.followingEvent { event(ev, heading: "次の番組") }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func event(_ ev: EventInfo, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.caption).foregroundStyle(.secondary)
            if let s = ev.start {
                Text("\(EventFormat.day.string(from: s)) \(EventFormat.timeRange(ev))").font(.caption).monospacedDigit()
            }
            Text(ev.title).font(.headline).textSelection(.enabled)
            if !ev.text.isEmpty { Text(ev.text).font(.callout).textSelection(.enabled) }
        }
    }
}

private struct ChannelPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showPhysicalChannels") private var showPhysical = false

    var body: some View {
        VStack(spacing: 0) {
            if model.spaces.isEmpty {
                Text("チャンネルがありません").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.scannedChannels.isEmpty || showPhysical {
                physicalList
            } else {
                scannedList
            }
            Divider()
            HStack {
                Button("スキャン…") { model.showScanSheet = true }
                    .disabled(model.state != .connected || model.isScanning)
                Spacer()
                if !model.scannedChannels.isEmpty {
                    Toggle("物理チャンネル", isOn: $showPhysical).toggleStyle(.checkbox).font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var scannedList: some View {
        let entries = model.scannedEntries
        let groups = Dictionary(grouping: entries, by: \.channel.spaceName)
        let order = entries.map(\.channel.spaceName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return List {
            ForEach(order, id: \.self) { space in
                Section(space) {
                    ForEach(groups[space] ?? []) { e in
                        Button { model.tune(e.tuningChannel, service: e.service.serviceID) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.service.displayName)
                                    Text(e.channel.channelName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if e.tuningChannel == model.currentChannel && e.service.serviceID == model.selection?.serviceID {
                                    Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var physicalList: some View {
        let found = Set(model.scannedChannels.map(\.id))
        return List {
            ForEach(model.spaces) { space in
                Section(space.name) {
                    ForEach(space.channels) { ch in
                        Button { model.tune(ch) } label: {
                            HStack {
                                Text(ch.name)
                                    .foregroundStyle(found.isEmpty || found.contains(ch.id) ? .primary : .secondary)
                                Spacer()
                                if ch == model.currentChannel {
                                    Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct ServicePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            Section("サービス") {
                ForEach(model.services) { svc in
                    Button { model.selectService(svc.serviceID) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(svc.displayName)
                                Text(String(format: "SID %d%@", svc.serviceID, svc.isOneSeg ? " ・ワンセグ" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if svc.serviceID == model.selection?.serviceID {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let sel = model.selection, sel.audioStreams.count > 1 {
                Section("音声") {
                    Picker("音声", selection: $model.audioIndex) {
                        ForEach(sel.audioStreams.indices, id: \.self) { i in
                            Text("音声\(i + 1) (\(sel.audioStreams[i].codecName))").tag(i)
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            }
            Section("二重音声") {
                Picker("二重音声", selection: $model.dualMono) {
                    ForEach(DualMonoMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .listStyle(.sidebar)
    }
}

private struct InfoPanel: View {
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
