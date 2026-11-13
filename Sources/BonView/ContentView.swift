import AVFoundation
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
                    if model.showCaptions {
                        switch model.captionStyle {
                        case .broadcast: CaptionPlaneView(frame: model.captionFrame, videoSize: model.nativeVideoSize)
                        case .simple: CaptionOverlay(lines: model.captionFrame.lines, videoSize: model.nativeVideoSize)
                        }
                    }
                    // Superimpose (emergency / news flashes) is shown regardless of the caption setting.
                    CaptionPlaneView(frame: model.superimposeFrame, videoSize: model.nativeVideoSize)
                    overlay
                    noticeOverlay
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
                // Filled + accent colour when on, outline + dimmed when off (a toolbar Toggle's
                // pressed state is too subtle to read at a glance).
                Button { model.showCaptions.toggle() } label: {
                    Label(model.showCaptions ? "字幕を隠す" : "字幕を表示",
                          systemImage: model.showCaptions ? "captions.bubble.fill" : "captions.bubble")
                        .foregroundStyle(model.showCaptions ? Color.accentColor : Color.secondary)
                }
                .help((model.showCaptions ? "字幕: オン" : "字幕: オフ")
                      + (model.selection?.caption == nil ? "（この番組には字幕がありません）" : ""))
                Button { model.saveScreenshot() } label: { Label("スクリーンショット", systemImage: "camera") }
                    .help("スクリーンショットを保存 (⌘S)")
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

    @ViewBuilder private var noticeOverlay: some View {
        if let text = model.notice {
            VStack {
                Spacer()
                Text(text)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
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

// MARK: - Captions

/// Caption text over the picture. The picture is aspect-fitted into the view, so the text is
/// placed relative to that rectangle and sized like ARIB's 960×540 plane with 36-dot characters.
struct CaptionOverlay: View {
    let lines: [String]
    let videoSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let rect = AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: geo.size))
            let fontSize = max(10, rect.height / 15 * 0.85)
            VStack {
                Spacer(minLength: 0)
                if !lines.isEmpty {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: fontSize, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 1.5)
                        .padding(.horizontal, fontSize * 0.4)
                        .padding(.vertical, fontSize * 0.15)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: fontSize * 0.2))
                }
            }
            .padding(.bottom, rect.height * 0.06)
            .padding(.horizontal, rect.width * 0.03)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
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
            if model.selection?.caption != nil {
                Text("字幕")
                    .font(.caption)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary))
                    .foregroundStyle(model.showCaptions ? .primary : .secondary)
                    .help(model.showCaptions ? "字幕あり（表示中）" : "字幕あり（非表示）")
            }
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
