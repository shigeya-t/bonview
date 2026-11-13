import ChannelScan
import SwiftUI
import TSCore

/// 番組表 window: one column per channel-list entry of a tuning space, one broadcast day
/// (04:00–翌04:00 JST) at a time.
struct ProgramGuideView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("guideSpace") private var spaceName = ""
    @State private var dayOffset = 0
    @State private var selected: String?
    @State private var scrollTarget: Int?

    static let columnWidth: CGFloat = 156
    static let timeColumnWidth: CGFloat = 30
    static let headerHeight: CGFloat = 40
    static let pointsPerMinute: CGFloat = 3

    static let jst = TimeZone(identifier: "Asia/Tokyo")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = jst
        return c
    }

    /// Start (04:00 JST) of the broadcast day containing `date`.
    static func broadcastDay(_ date: Date) -> Date {
        let cal = calendar
        let shifted = date.addingTimeInterval(-4 * 3600)
        return cal.startOfDay(for: shifted).addingTimeInterval(4 * 3600)
    }

    private var now: Date { model.broadcastTime ?? Date() }
    private var dayStart: Date { Self.calendar.date(byAdding: .day, value: dayOffset, to: Self.broadcastDay(now))! }
    private var dayEnd: Date { dayStart.addingTimeInterval(24 * 3600) }

    private var spaces: [String] {
        model.visibleEntries.map(\.channel.spaceName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private var currentSpace: String? { spaces.contains(spaceName) ? spaceName : spaces.first }

    /// Days that have data, from today.
    private var dayCount: Int {
        guard let last = model.epg.dateRange?.upperBound else { return 1 }
        let days = Self.calendar.dateComponents([.day], from: Self.broadcastDay(now), to: Self.broadcastDay(last)).day ?? 0
        return max(1, min(days + 1, 9))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.visibleEntries.isEmpty {
                ContentUnavailableView("チャンネルがありません", systemImage: "list.bullet.rectangle",
                                       description: Text("番組表にはチャンネルスキャンの結果を使います。"))
            } else {
                grid
            }
            Divider()
            GuideStatusBar()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("チューニング空間", selection: Binding(get: { currentSpace ?? "" }, set: { spaceName = $0 })) {
                    ForEach(spaces, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup {
                Button { dayOffset = max(0, dayOffset - 1) } label: { Label("前の日", systemImage: "chevron.left") }
                    .disabled(dayOffset == 0)
                Picker("日付", selection: $dayOffset) {
                    ForEach(0..<max(dayCount, dayOffset + 1), id: \.self) { i in
                        Text(EventFormat.day.string(from: Self.calendar.date(byAdding: .day, value: i, to: Self.broadcastDay(now))!)).tag(i)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                Button { dayOffset += 1 } label: { Label("次の日", systemImage: "chevron.right") }
                    .disabled(dayOffset + 1 >= dayCount)
                Button {
                    dayOffset = 0
                    scrollTarget = Self.calendar.component(.hour, from: now)
                } label: { Label("現在", systemImage: "clock") }
                    .help("現在の時刻へ移動")
            }
        }
        .navigationTitle("番組表")
    }

    private var grid: some View {
        let entries = model.visibleEntries.filter { $0.channel.spaceName == currentSpace }
        let height = 24 * 60 * Self.pointsPerMinute
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        HStack(alignment: .top, spacing: 0) {
                            timeColumn(height: height)
                            ForEach(entries) { e in
                                column(e, height: height)
                                Divider()
                            }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: Self.timeColumnWidth)
                            ForEach(entries) { e in
                                header(e)
                                Divider()
                            }
                        }
                        .frame(height: Self.headerHeight)
                        .background(.bar)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
            .onAppear {
                // Open at the current hour.
                DispatchQueue.main.async { proxy.scrollTo(hourID(Self.calendar.component(.hour, from: now)), anchor: .topLeading) }
            }
            .onChange(of: scrollTarget) { _, h in
                guard let h else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(hourID(h), anchor: .topLeading) } }
                scrollTarget = nil
            }
        }
    }

    private func hourID(_ hour: Int) -> String { "hour-\(hour)" }

    private func timeColumn(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { i in
                let hour = (i + 4) % 24
                Text("\(hour)")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .padding(.top, 2)
                    .frame(width: Self.timeColumnWidth, height: 60 * Self.pointsPerMinute, alignment: .top)
                    .background(i % 2 == 0 ? Color.secondary.opacity(0.10) : Color.secondary.opacity(0.18))
                    .id(hourID(hour))
            }
        }
        .frame(height: height, alignment: .top)
    }

    private func header(_ e: AppModel.ScannedEntry) -> some View {
        Button {
            model.tune(e.tuningChannel, service: e.service.serviceID)
        } label: {
            VStack(spacing: 0) {
                if let n = e.numberText { Text(n).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
                Text(e.service.displayName).font(.callout.weight(.semibold)).lineLimit(1)
            }
            .frame(width: Self.columnWidth - 1, height: Self.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(e.service.displayName) を視聴")
    }

    private func column(_ e: AppModel.ScannedEntry, height: CGFloat) -> some View {
        let events = model.epgKey(e).map { model.epg.events(for: $0, from: dayStart, to: dayEnd) } ?? []
        return ZStack(alignment: .topLeading) {
            // Hour lines.
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle().fill(.clear).frame(height: 60 * Self.pointsPerMinute)
                        .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5) }
                }
            }
            ForEach(events, id: \.eventID) { ev in
                let s = max(ev.start!, dayStart), en = min(ev.end!, dayEnd)
                let y = s.timeIntervalSince(dayStart) / 60 * Self.pointsPerMinute
                let h = max(en.timeIntervalSince(s) / 60 * Self.pointsPerMinute, 1)
                let id = "\(e.id)-\(ev.eventID)"
                EventBlock(event: ev, past: ev.end! <= now, onAir: ev.start! <= now && now < ev.end!)
                    .frame(width: Self.columnWidth - 1, height: h, alignment: .topLeading)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.tune(e.tuningChannel, service: e.service.serviceID) }
                    .onTapGesture { selected = id }
                    .popover(isPresented: Binding(get: { selected == id }, set: { if !$0 { selected = nil } }), arrowEdge: .trailing) {
                        EventDetail(event: ev, entry: e)
                    }
                    .offset(y: y)
            }
            if now >= dayStart && now < dayEnd {
                Rectangle().fill(.red).frame(height: 1.5)
                    .offset(y: now.timeIntervalSince(dayStart) / 60 * Self.pointsPerMinute)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.columnWidth - 1, height: height, alignment: .topLeading)
    }
}

/// One programme in the grid.
private struct EventBlock: View {
    let event: EventInfo
    let past: Bool
    let onAir: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(event.start.map { String(format: "%02d", ProgramGuideView.calendar.component(.minute, from: $0)) } ?? "")
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(event.title).font(.caption.weight(.semibold))
            }
            if !event.text.isEmpty {
                Text(event.text).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GenreColor.color(event.genre).opacity(past ? 0.10 : 0.28))
        .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.45)).frame(height: 0.5) }
        .overlay { if onAir { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5) } }
        .opacity(past ? 0.6 : 1)
    }
}

/// Popover with the full programme information.
private struct EventDetail: View {
    @Environment(AppModel.self) private var model
    let event: EventInfo
    let entry: AppModel.ScannedEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(entry.service.displayName).font(.caption.weight(.semibold))
                    if let g = GenreColor.name(event.genre) {
                        Text(g).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(GenreColor.color(event.genre).opacity(0.35), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    // At the top so it is reachable without scrolling long descriptions.
                    Button("このチャンネルを視聴") { model.tune(entry.tuningChannel, service: entry.service.serviceID) }
                        .controlSize(.small)
                        .disabled(model.state != .connected)
                }
                if let s = event.start {
                    Text("\(EventFormat.day.string(from: s)) \(EventFormat.timeRange(event))").font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(event.title).font(.headline).textSelection(.enabled)
                if !event.text.isEmpty { Text(event.text).font(.callout).textSelection(.enabled) }
                ForEach(Array(event.extended.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        if !item.heading.isEmpty { Text(item.heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        Text(item.text).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
        }
        .frame(maxHeight: 420)
    }
}

/// Acquisition status and controls at the bottom of the guide.
private struct GuideStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            if let g = model.epgGrab, g.isRunning {
                ProgressView(value: Double(g.index), total: Double(max(g.total, 1)))
                    .frame(width: 120)
                Text("番組表を取得中 \(min(g.index + 1, g.total))/\(g.total)  \(g.current)").lineLimit(1)
                Spacer()
                Button("中止") { model.cancelEPGGrab() }
            } else {
                if let err = model.epgGrab?.error {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
                } else if let last = model.epgLastGrab {
                    Text("最終取得: \(EventFormat.day.string(from: last)) \(EventFormat.time.string(from: last))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("番組表はまだ取得していません").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("自動取得", isOn: $model.epgAutoGrab).toggleStyle(.checkbox)
                    .help("接続中、6時間ごとに番組表を取得します")
                Button("番組表を取得") { model.startEPGGrab() }
                    .disabled(model.state != .connected || model.isScanning || model.scannedChannels.isEmpty)
                    .help("別の接続でチャンネルを切り替えながら全局の番組表を取得します (空きチューナーが必要です)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// ARIB STD-B10 content_nibble_level_1.
enum GenreColor {
    static let names = ["ニュース/報道", "スポーツ", "情報/ワイドショー", "ドラマ", "音楽", "バラエティ", "映画", "アニメ/特撮",
                        "ドキュメンタリー/教養", "劇場/公演", "趣味/教育", "福祉"]
    private static let hues: [Double] = [0.58, 0.33, 0.12, 0.95, 0.80, 0.08, 0.0, 0.88, 0.50, 0.70, 0.22, 0.45]

    static func name(_ genre: UInt8?) -> String? {
        guard let g = genre, Int(g) < names.count else { return nil }
        return names[Int(g)]
    }

    static func color(_ genre: UInt8?) -> Color {
        guard let g = genre, Int(g) < hues.count else { return Color.gray }
        return Color(hue: hues[Int(g)], saturation: 0.6, brightness: 0.85)
    }
}
