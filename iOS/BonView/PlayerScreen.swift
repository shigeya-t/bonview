import AVKit
import BonDriver
import MediaCore
import SwiftUI
import TSCore

/// Main screen. Portrait: picture on top, controls and the panel below. iPhone landscape: the
/// picture fills the screen and the controls appear on tap. Wide (iPad landscape): picture with
/// the panel at the side, like the macOS window. The full-screen button locks the screen to landscape
/// and shows only the picture; channel and programme information appear for a few seconds on entry,
/// on channel / programme changes and on tap.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PictureInPicture.self) private var pip: PictureInPicture?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var sheet: Sheet?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// Full screen chosen with the button (landscape is locked while it is on).
    @State private var isFullScreen = false

    /// How long the information and controls stay up in full screen.
    private static let overlayDuration: Duration = .seconds(5)

    enum Sheet: String, Identifiable {
        case settings, guide
        var id: Self { self }
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let full = isFullScreen || (landscape && verticalSizeClass == .compact)
            // The layouts only reserve a slot for the picture; the picture itself is one view behind
            // them, positioned on the slot. Rotating or entering full screen then moves it instead of
            // making a new video view (which re-parented the display layer: a black flash, and the
            // PiP source moving between views).
            ZStack {
                if full {
                    fullScreen
                } else if landscape {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            pictureSlot.frame(maxHeight: .infinity)
                            ControlBar(sheet: $sheet, isFullScreen: false, toggleFullScreen: enterFullScreen)
                        }
                        Divider()
                        PanelView(openSettings: { sheet = .settings }).frame(width: min(380, geo.size.width * 0.36))
                    }
                } else {
                    VStack(spacing: 0) {
                        pictureSlot.aspectRatio(16 / 9, contentMode: .fit)
                        ControlBar(sheet: $sheet, isFullScreen: false, toggleFullScreen: enterFullScreen)
                        Divider()
                        PanelView(openSettings: { sheet = .settings })
                    }
                }
            }
            .backgroundPreferenceValue(PictureSlotKey.self) { anchor in
                GeometryReader { g in
                    let r = anchor.map { g[$0] } ?? .zero
                    picture
                        .contentShape(Rectangle())
                        .onTapGesture { if full { setControlsVisible(!controlsVisible) } }
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
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

    /// Where the picture goes in the current layout (see `body`).
    private var pictureSlot: some View {
        Color.clear
            .anchorPreference(key: PictureSlotKey.self, value: .bounds) { $0 }
            .allowsHitTesting(false)
    }

    /// Picture with captions and state messages.
    private var picture: some View {
        ZStack {
            Color.black
            VideoView(displayLayer: model.player.presenter.displayLayer)
            // While the picture is in the PiP window, the system draws a placeholder here.
            if pip?.isActive != true {
                if model.showCaptions {
                    switch model.captionStyle {
                    case .broadcast: CaptionPlaneView(frame: model.captionFrame, videoSize: model.nativeVideoSize)
                    case .simple: CaptionOverlay(lines: model.captionFrame.lines, videoSize: model.nativeVideoSize)
                    }
                }
                // Superimpose (emergency / news flashes) is shown regardless of the caption setting.
                CaptionPlaneView(frame: model.superimposeFrame, videoSize: model.nativeVideoSize)
            }
            StateOverlay(sheet: $sheet)
        }
        .clipped()
    }

    // MARK: Full screen (button, or iPhone landscape)

    private var fullScreen: some View {
        ZStack {
            // Taps on the picture (behind) toggle the controls.
            pictureSlot.ignoresSafeArea()
            if controlsVisible {
                VStack(spacing: 0) {
                    FullScreenInfo(exit: exitFullScreen)
                        .background(LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.4), .clear],
                                                   startPoint: .top, endPoint: .bottom)
                                        .ignoresSafeArea())
                    Spacer()
                    ControlBar(sheet: $sheet, isFullScreen: true, toggleFullScreen: exitFullScreen,
                               onInteraction: { scheduleHide() })
                        .background(.black.opacity(0.55), in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .padding(.bottom, 20)
                        .fixedSize()
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        // Let the control bar near the bottom edge get taps first (home indicator gesture needs a second swipe).
        .defersSystemGestures(on: .bottom)
        .onAppear { setControlsVisible(true) }
        // Show what is on air again after a channel or programme change.
        .onChange(of: infoKey) { setControlsVisible(true) }
        .onChange(of: sheet) { _, s in if s == nil { scheduleHide() } }
    }

    /// Changes when the channel or the programme on air changes.
    private var infoKey: String {
        "\(model.channelTitle)|\(model.presentEvent.map { String($0.eventID) } ?? "-")"
    }

    private func enterFullScreen() {
        isFullScreen = true
        OrientationLock.lockLandscape()
    }

    /// Also used to leave the automatic full screen of a sideways iPhone: rotates back to portrait.
    private func exitFullScreen() {
        isFullScreen = false
        OrientationLock.release()
    }

    private func setControlsVisible(_ visible: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = visible }
        if visible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.overlayDuration)
            guard !Task.isCancelled, sheet == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

/// Channel, programme on air (title, time, progress, description) and the next programme, shown at
/// the top in full screen.
private struct FullScreenInfo: View {
    @Environment(AppModel.self) private var model
    var exit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.channelTitle).font(.headline)
                if let ev = model.presentEvent {
                    Text(ev.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(EventFormat.timeRange(ev)).monospacedDigit()
                        if let p = progress(ev) {
                            ProgressView(value: p).tint(.white).frame(width: 120)
                        }
                    }
                    .font(.caption)
                    if !ev.text.isEmpty {
                        Text(ev.text).font(.caption).lineLimit(2).opacity(0.85)
                    }
                }
                if let next = model.followingEvent {
                    Text("次: \(next.start.map { EventFormat.time.string(from: $0) } ?? "")  \(next.title)")
                        .font(.caption).lineLimit(1).opacity(0.75)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: exit) {
                Label("全画面を終了", systemImage: "arrow.down.right.and.arrow.up.left")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    /// Elapsed fraction of the programme, or nil when the clock is outside it (e.g. a recorded file).
    private func progress(_ ev: EventInfo) -> Double? {
        guard let start = ev.start, let duration = ev.duration, duration > 0 else { return nil }
        let p = (model.programClock ?? Date()).timeIntervalSince(start) / duration
        return (0...1).contains(p) ? p : nil
    }
}

/// System audio output picker (AirPlay speakers, Bluetooth, ...).
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = .tintColor
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Channel up/down, mute, captions, guide and settings.
struct ControlBar: View {
    @Environment(AppModel.self) private var model
    @Environment(PictureInPicture.self) private var pip: PictureInPicture?
    @Binding var sheet: PlayerScreen.Sheet?
    var isFullScreen: Bool
    var toggleFullScreen: () -> Void
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
            if PictureInPicture.isSupported, let pip {
                button(pip.isActive ? "ピクチャ・イン・ピクチャを終了" : "ピクチャ・イン・ピクチャ",
                       pip.isActive ? "pip.exit" : "pip.enter") { pip.toggle() }
                    .disabled(!pip.isPossible && !pip.isActive)
            }
            AirPlayButton()
                .frame(width: 40, height: 40)
                .accessibilityLabel("AirPlay")
            button("番組表", model.isGrabbingEPG ? "calendar.badge.clock" : "calendar") { sheet = .guide }
            button("設定", "gearshape") { sheet = .settings }
            button(isFullScreen ? "全画面を終了" : "全画面",
                   isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                toggleFullScreen()
            }
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
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
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
        case .connected where model.isScrambled:
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

/// Bounds of the picture slot of the current layout.
private struct PictureSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
