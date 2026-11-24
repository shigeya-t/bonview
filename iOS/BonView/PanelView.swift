import BonDriver
import ChannelScan
import MediaCore
import SwiftUI
import TSCore

/// Panel under (or beside) the picture: チャンネル / 番組 / 音声 / 情報.
struct PanelView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case channel = "チャンネル"
        case program = "番組"
        case audio = "音声・字幕"
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            switch tab {
            case .channel: ChannelListView()
            case .program: ProgramInfoView()
            case .audio: AudioCaptionView()
            case .info: InfoPanel()
            }
        }
    }
}

// MARK: - Channels

struct ChannelListView: View {
    @Environment(AppModel.self) private var model
    @State private var editMode: EditMode = .inactive

    var body: some View {
        Group {
            if model.spaces.isEmpty && model.scannedChannels.isEmpty {
                ContentUnavailableView {
                    Label("チャンネルがありません", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text(model.state == .connected ? "チャンネルスキャンを行ってください。" : "サーバーに接続するとチャンネルが表示されます。")
                } actions: {
                    if model.state == .connected { scanButton }
                }
            } else if model.scannedChannels.isEmpty {
                physicalList
            } else {
                scannedList
            }
        }
        .environment(\.editMode, $editMode)
    }

    private var scanButton: some View {
        Button("チャンネルスキャン…") { model.showScanSheet = true }
            .disabled(model.state != .connected || model.isScanning)
    }

    /// Scanned services in the user's order. Tap to tune; 編集 to reorder and hide.
    private var scannedList: some View {
        let editing = editMode.isEditing
        let entries = editing ? model.scannedEntries : model.visibleEntries
        let spaces = entries.map(\.channel.spaceName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return List {
            if entries.isEmpty {
                Text("すべてのチャンネルが非表示です。「編集」から表示を切り替えられます。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(spaces, id: \.self) { space in
                let items = entries.filter { $0.channel.spaceName == space }
                let ids = items.map(\.id)
                Section(space) {
                    ForEach(items) { e in
                        row(e, editing: editing)
                    }
                    .onMove { from, to in model.moveEntries(ids, from: from, to: to) }
                }
            }
            Section {
                HStack {
                    scanButton
                    Spacer()
                    Button(editing ? "完了" : "編集") {
                        withAnimation { editMode = editing ? .inactive : .active }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder private func row(_ e: AppModel.ScannedEntry, editing: Bool) -> some View {
        let hidden = model.isHidden(e)
        HStack(spacing: 10) {
            if editing {
                Button {
                    model.setHidden(e, !hidden)
                } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .foregroundStyle(hidden ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(hidden ? "表示する" : "非表示にする")
            }
            Button {
                model.tune(e.tuningChannel, service: e.service.serviceID)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let n = e.numberText {
                        Text(n).monospacedDigit().foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.service.displayName).fontWeight(.semibold)
                            .foregroundStyle(hidden ? .secondary : .primary)
                        if let ev = model.currentProgram(e), !ev.title.isEmpty {
                            Text(ev.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if isCurrent(e) {
                        Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(editing)
        }
        .swipeActions {
            Button(hidden ? "表示" : "非表示") { model.setHidden(e, !hidden) }.tint(.gray)
        }
        .contextMenu {
            Button(hidden ? "表示する" : "非表示にする") { model.setHidden(e, !hidden) }
            StationLinkMenu(name: e.service.name)
        }
    }

    /// BonDriver's physical channels (before a scan).
    private var physicalList: some View {
        List {
            Section {
                HStack {
                    Text("スキャンすると放送局名で一覧できます").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    scanButton.buttonStyle(.borderless)
                }
            }
            ForEach(model.spaces) { space in
                Section(space.name) {
                    ForEach(space.channels) { ch in
                        Button {
                            model.tune(ch)
                        } label: {
                            HStack {
                                Text(ch.name).monospacedDigit()
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
        .listStyle(.plain)
    }

    private func isCurrent(_ e: AppModel.ScannedEntry) -> Bool {
        e.tuningChannel == model.currentChannel && e.service.serviceID == model.selection?.serviceID
    }
}

// MARK: - Programme

private struct ProgramInfoView: View {
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
            .padding(16)
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
            ForEach(Array(ev.extended.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    if !item.heading.isEmpty { Text(item.heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(item.text).font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Services, audio and captions

private struct AudioCaptionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            if model.services.count > 1 {
                Section("サービス") {
                    ForEach(model.services, id: \.serviceID) { svc in
                        Button {
                            model.selectService(svc.serviceID)
                        } label: {
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
            Section("字幕") {
                Toggle("字幕を表示", isOn: $model.showCaptions)
                Picker("表示方法", selection: $model.captionStyle) {
                    ForEach(CaptionStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if model.captionLanguages.count > 1 {
                    Picker("言語", selection: $model.captionLanguageIndex) {
                        ForEach(Array(model.captionLanguages.enumerated()), id: \.offset) { i, l in Text(l.displayName).tag(i) }
                    }
                }
                if model.selection != nil && model.selection?.caption == nil {
                    Text("この番組には字幕がありません").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("音量") {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $model.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                Toggle("消音", isOn: $model.isMuted)
            }
        }
    }
}
