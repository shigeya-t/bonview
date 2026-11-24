import BonDriver
import MediaCore
import SwiftUI
import TSCore

/// Main screen. Portrait: picture on top, controls and the panel below. iPhone landscape: the
/// picture fills the screen and the controls appear on tap. Wide (iPad landscape): picture with
/// the panel at the side, like the macOS window.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var sheet: Sheet?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    enum Sheet: String, Identifiable {
        case settings, guide
        var id: Self { self }
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            if landscape && verticalSizeClass == .compact {
                fullScreen
            } else if landscape {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        picture.frame(maxHeight: .infinity)
                        ControlBar(sheet: $sheet)
                    }
                    Divider()
                    PanelView().frame(width: min(380, geo.size.width * 0.36))
                }
            } else {
                VStack(spacing: 0) {
                    picture.aspectRatio(16 / 9, contentMode: .fit)
                    ControlBar(sheet: $sheet)
                    Divider()
                    PanelView()
                }
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .settings: SettingsScreen().environment(model)
            case .guide: GuideScreen().environment(model)
            }
        }
        .sheet(isPresented: $model.showScanSheet) {
            ChannelScanScreen().environment(model).interactiveDismissDisabled(model.isScanning)
        }
    }

    /// Picture with captions and state messages.
    private var picture: some View {
        ZStack {
            Color.black
            VideoView(displayLayer: model.player.presenter.displayLayer)
            if model.showCaptions {
                switch model.captionStyle {
                case .broadcast: CaptionPlaneView(frame: model.captionFrame, videoSize: model.nativeVideoSize)
                case .simple: CaptionOverlay(lines: model.captionFrame.lines, videoSize: model.nativeVideoSize)
                }
            }
            // Superimpose (emergency / news flashes) is shown regardless of the caption setting.
            CaptionPlaneView(frame: model.superimposeFrame, videoSize: model.nativeVideoSize)
            StateOverlay(sheet: $sheet)
        }
        .clipped()
    }

    // MARK: Full screen (iPhone landscape)

    private var fullScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            picture.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { setControlsVisible(!controlsVisible) }
            if controlsVisible {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.channelTitle).font(.headline)
                            if let ev = model.presentEvent {
                                Text("\(EventFormat.timeRange(ev))  \(ev.title)").font(.caption).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding()
                    .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    ControlBar(sheet: $sheet, onInteraction: { scheduleHide() })
                        .background(.black.opacity(0.55), in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .padding(.bottom, 8)
                        .fixedSize()
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear { scheduleHide() }
    }

    private func setControlsVisible(_ visible: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = visible }
        if visible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, sheet == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

/// Channel up/down, mute, captions, guide and settings.
struct ControlBar: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: PlayerScreen.Sheet?
    var onInteraction: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            button("前のチャンネル", "chevron.up") { model.stepChannel(-1) }
                .disabled(model.spaces.isEmpty)
            button("次のチャンネル", "chevron.down") { model.stepChannel(1) }
                .disabled(model.spaces.isEmpty)
            Spacer(minLength: 4)
            button(model.isMuted ? "消音を解除" : "消音", model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                model.isMuted.toggle()
            }
            button(model.showCaptions ? "字幕を隠す" : "字幕を表示",
                   model.showCaptions ? "captions.bubble.fill" : "captions.bubble") {
                model.showCaptions.toggle()
            }
            .foregroundStyle(model.showCaptions ? Color.accentColor : Color.secondary)
            button("番組表", model.isGrabbingEPG ? "calendar.badge.clock" : "calendar") { sheet = .guide }
            button("設定", "gearshape") { sheet = .settings }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func button(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 40)
        }
        .buttonStyle(.borderless)
    }
}

/// Connection state, scrambling and channel lock messages over the picture.
private struct StateOverlay: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: PlayerScreen.Sheet?

    var body: some View {
        switch model.state {
        case .idle where model.profiles.isEmpty:
            message("BonDriverProxy サーバーが未登録です", button: "設定を開く") { sheet = .settings }
        case .idle:
            message("切断されています", button: "接続") { model.connect() }
        case .connecting:
            ProgressView("接続中…").controlSize(.large).tint(.white).foregroundStyle(.white)
        case .failed(let msg):
            message(msg, button: "再接続") { model.connect() }
        case .connected where model.isScanning:
            ProgressView("チャンネルスキャン中…").controlSize(.large).tint(.white).foregroundStyle(.white)
        case .connected where model.channelLocked:
            banner("チャンネルがロックされています（他のクライアントが使用中）")
        case .connected where model.status.isScrambled:
            banner("スクランブルが解除されていません。サーバー側でB25デコードを有効にしてください。")
        case .connected where model.isTuning:
            ProgressView().controlSize(.large).tint(.white)
        default:
            EmptyView()
        }
    }

    private func message(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text).foregroundStyle(.white).multilineTextAlignment(.center).font(.callout)
            Button(button, action: action).buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private func banner(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.yellow)
                .padding(.top, 12)
            Spacer()
        }
        .padding(.horizontal)
    }
}

/// Programme guide sheet (the guide view is shared with the macOS app).
private struct GuideScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProgramGuideView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
        }
    }
}
