import BonDriver
import SwiftUI
import TSCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    VideoView(displayLayer: model.player.presenter.displayLayer,
                              onLayout: { [model] in model.videoHostDidLayout($0) })
                    overlay
                }
                .frame(minWidth: 320, minHeight: 180)
                if model.showPanel {
                    Divider()
                    SidePanel()
                        .frame(width: 280)
                }
            }
            Divider()
            StatusBar()
        }
        .navigationTitle(model.channelTitle)
        .sheet(isPresented: $model.showScanSheet) {
            ChannelScanView().environment(model).interactiveDismissDisabled(model.isScanning)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("BonDriver", selection: Binding(
                    get: { model.currentProfile?.id },
                    set: { id in if let p = model.profiles.first(where: { $0.id == id }) { model.connect(p) } })) {
                    ForEach(model.profiles) { p in Text(p.displayName).tag(Optional(p.id)) }
                }
                .frame(minWidth: 180)
                .disabled(model.profiles.isEmpty)
            }
            ToolbarItemGroup {
                Button { model.stepChannel(-1) } label: { Label("前のチャンネル", systemImage: "chevron.up") }
                    .disabled(model.spaces.isEmpty)
                Button { model.stepChannel(1) } label: { Label("次のチャンネル", systemImage: "chevron.down") }
                    .disabled(model.spaces.isEmpty)
                Button { model.isMuted.toggle() } label: {
                    Label("消音", systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                Slider(value: $model.volume, in: 0...1).frame(width: 90)
                Menu {
                    ForEach(AppModel.videoScales, id: \.self) { scale in
                        Button {
                            model.setVideoScale(scale)
                        } label: {
                            if scale.percent == model.videoScalePercent {
                                Label(scale.label, systemImage: "checkmark")
                            } else {
                                Text(scale.label)
                            }
                        }
                    }
                } label: {
                    Text(model.videoScaleText).monospacedDigit()
                }
                .help("画面サイズ")
                .fixedSize()
                Button { model.showPanel.toggle() } label: { Label("パネル", systemImage: "sidebar.right") }
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch model.state {
        case .idle where model.profiles.isEmpty:
            message("BonDriverProxy サーバーが未登録です", button: "設定を開く") { openSettings() }
        case .idle:
            message("切断されています", button: "接続") { model.connect() }
        case .connecting:
            ProgressView("接続中…").controlSize(.large).foregroundStyle(.white)
        case .failed(let msg):
            message(msg, button: "再接続") { model.connect() }
        case .connected where model.isScanning:
            ProgressView("チャンネルスキャン中…").controlSize(.large).foregroundStyle(.white)
        case .connected where model.channelLocked:
            banner("チャンネルがロックされています（他のクライアントが使用中）")
        case .connected where model.status.isScrambled:
            banner("スクランブルが解除されていません。サーバー側でB25デコードを有効にしてください。")
        case .connected where model.isTuning:
            ProgressView().controlSize(.large)
        default:
            EmptyView()
        }
    }

    private func message(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text).foregroundStyle(.white).multilineTextAlignment(.center)
            Button(button, action: action)
        }
        .padding(24)
    }

    private func banner(_ text: String) -> some View {
        VStack {
            Text(text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.yellow)
                .padding(.top, 12)
            Spacer()
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Text(model.currentChannel?.name ?? "—").lineLimit(1)
            if let ev = model.presentEvent {
                Text("\(EventFormat.timeRange(ev))  \(ev.title)").lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if case .connected = model.state {
                Label(model.signalText, systemImage: "antenna.radiowaves.left.and.right")
            }
            Text(String(format: "%.2f Mbps", model.status.bitrateMbps)).monospacedDigit()
            if model.status.errorPackets + model.status.continuityErrors > 0 {
                Text("D:\(model.status.continuityErrors) E:\(model.status.errorPackets)")
                    .foregroundStyle(.orange).monospacedDigit()
            }
            if let t = model.broadcastTime {
                Text(t, format: .dateTime.hour().minute().second()).monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }
}

enum EventFormat {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E)"
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return f
    }()

    static func timeRange(_ ev: EventInfo) -> String {
        guard let s = ev.start else { return "" }
        let start = time.string(from: s)
        if let e = ev.end { return "\(start)〜\(time.string(from: e))" }
        return "\(start)〜"
    }
}
