import BonDriver
import ChannelScan
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

    /// Scanned services in the user's order, hidden ones left out. Drag to reorder (within a
    /// tuning space); click to tune.
    private var scannedList: some View {
        let entries = model.visibleEntries
        let order = entries.map(\.channel.spaceName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        // Selection-driven list: clicking a row tunes it, and leaves the row free for the List's
        // own drag-to-reorder (a tap gesture on the row would compete with the drag).
        let selection = Binding<String?>(
            get: { entries.first(where: isCurrent)?.id },
            set: { id in
                if let e = entries.first(where: { $0.id == id }) { model.tune(e.tuningChannel, service: e.service.serviceID) }
            })
        return List(selection: selection) {
            if entries.isEmpty {
                Text("すべてのチャンネルが非表示です。「物理チャンネル」から表示を切り替えられます。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(order, id: \.self) { space in
                let items = entries.filter { $0.channel.spaceName == space }
                let ids = items.map(\.id)
                Section(space) {
                    ForEach(items) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let n = e.numberText {
                                Text(n).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Text(e.service.displayName).fontWeight(.semibold).fixedSize()
                            programTitle(e)
                            Spacer(minLength: 0)
                            if isCurrent(e) {
                                Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                        .tag(e.id)
                        .contextMenu { moveMenu(e, ids: ids) }
                    }
                    .onMove { from, to in model.moveEntries(ids, from: from, to: to) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Right-click alternative to dragging.
    @ViewBuilder private func moveMenu(_ e: AppModel.ScannedEntry, ids: [String]) -> some View {
        if let i = ids.firstIndex(of: e.id) {
            Button("先頭へ移動") { model.moveEntries(ids, from: [i], to: 0) }.disabled(i == 0)
            Button("上へ移動") { model.moveEntries(ids, from: [i], to: i - 1) }.disabled(i == 0)
            Button("下へ移動") { model.moveEntries(ids, from: [i], to: i + 2) }.disabled(i == ids.count - 1)
            Button("末尾へ移動") { model.moveEntries(ids, from: [i], to: ids.count) }.disabled(i == ids.count - 1)
            Divider()
            Button("非表示にする") { model.setHidden(e, true) }
            Divider()
        }
        StationLinkMenu(name: e.service.name)
    }

    /// BonDriver's physical channels. After a scan each found service is listed next to its
    /// channel with a "非表示" checkbox controlling the channel list.
    private var physicalList: some View {
        let byChannel = Dictionary(grouping: model.scannedEntries, by: \.channel.id)
        return List {
            ForEach(model.spaces) { space in
                Section(space.name) {
                    ForEach(space.channels) { ch in
                        let services = byChannel[ch.id] ?? []
                        if services.isEmpty {
                            HStack {
                                Text(ch.name).monospacedDigit()
                                    .foregroundStyle(model.scannedChannels.isEmpty ? .primary : .secondary)
                                Spacer()
                                if ch == model.currentChannel {
                                    Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.tune(ch) }
                        } else {
                            ForEach(Array(services.enumerated()), id: \.element.id) { i, e in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(i == 0 ? ch.name : "").monospacedDigit()
                                        .frame(minWidth: 44, alignment: .leading)
                                    if let n = e.numberText {
                                        Text(n).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Text(e.service.displayName)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(model.isHidden(e) ? .secondary : .primary)
                                        .lineLimit(1)
                                    programTitle(e)
                                    Spacer(minLength: 0)
                                    if isCurrent(e) {
                                        Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                                    }
                                    Toggle("非表示", isOn: Binding(get: { model.isHidden(e) },
                                                                 set: { model.setHidden(e, $0) }))
                                        .toggleStyle(.checkbox)
                                        .font(.caption)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { model.tune(e.tuningChannel, service: e.service.serviceID) }
                                .contextMenu { StationLinkMenu(name: e.service.name) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Current programme title after the service name: smaller and grey so it reads apart from the
    /// (semibold) name. Truncated; hovering shows the full title in a popover.
    @ViewBuilder private func programTitle(_ e: AppModel.ScannedEntry) -> some View {
        if let ev = model.currentProgram(e), !ev.title.isEmpty {
            ProgramTitleLabel(event: ev)
        }
    }

    private func isCurrent(_ e: AppModel.ScannedEntry) -> Bool {
        e.tuningChannel == model.currentChannel && e.service.serviceID == model.selection?.serviceID
    }
}

/// Truncated programme title that pops up the full title (with time and description) after the
/// pointer rests on it. `.help` tooltips don't show reliably inside the selectable channel List.
private struct ProgramTitleLabel: View {
    let event: EventInfo
    @State private var hovering = false
    @State private var showPopover = false

    var body: some View {
        Text(event.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .onHover { inside in
                hovering = inside
                if inside {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if hovering { showPopover = true }
                    }
                } else {
                    showPopover = false
                }
            }
            .popover(isPresented: $showPopover, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 4) {
                    if event.start != nil {
                        Text(EventFormat.timeRange(event)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(event.title).font(.headline)
                    if !event.text.isEmpty {
                        Text(event.text).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(10)
            }
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
                    .contextMenu { StationLinkMenu(name: svc.name) }
                }
            }
            if let sel = model.selection, sel.audioStreams.count > 1 {
                Section("音声") {
                    let labels = model.audioStreamLabels
                    Picker("音声", selection: $model.audioIndex) {
                        ForEach(sel.audioStreams.indices, id: \.self) { i in
                            Text("\(labels.indices.contains(i) ? labels[i] : "音声\(i + 1)") (\(sel.audioStreams[i].codecName))").tag(i)
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            }
            if model.status.isDualMono {
                Section("二重音声") {
                    Picker("二重音声", selection: $model.dualMono) {
                        ForEach([DualMonoMode.main, .sub, .both], id: \.self) { Text(model.dualMonoLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Right-click items that open the broadcaster's homepage (built-in table) or a web search.
private struct StationLinkMenu: View {
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
