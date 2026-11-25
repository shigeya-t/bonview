import AVFoundation
import SwiftUI

@main
struct BonViewApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var nowPlaying: NowPlaying?
    @State private var pip: PictureInPicture?
    /// Keep playing (audio only) when the app goes to the background or the screen is locked.
    @AppStorage("backgroundPlayback") private var backgroundPlayback = true
    /// Whether to reconnect when the app comes back to the foreground.
    @State private var resumeOnActive = false

    init() {
        NowPlaying.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            PlayerScreen()
                .environment(model)
                .environment(pip)
                .onOpenURL { url in
                    // Opened in place from Files (TSFileSource holds the security scope while reading).
                    model.openFile(url)
                }
                .onAppear {
                    if nowPlaying == nil {
                        let n = NowPlaying(model: model)
                        // Stopped by the user while in the background: don't reconnect on return.
                        n.onUserStop = { resumeOnActive = false }
                        n.start()
                        nowPlaying = n
                        let p = PictureInPicture(model: model)
                        p.onUserStop = { resumeOnActive = false }
                        p.start()
                        p.setAutomaticStart(backgroundPlayback)
                        pip = p
                    }
                    if model.currentProfile != nil, model.state == .idle { model.connect() }
                }
                .onChange(of: model.state) { _, state in
                    // Keep the screen on while something is playing.
                    switch state {
                    case .connected, .playingFile: UIApplication.shared.isIdleTimerDisabled = true
                    default: UIApplication.shared.isIdleTimerDisabled = false
                    }
                    // Take the audio (stopping other apps' playback) only when something plays.
                    switch state {
                    case .connecting, .connected, .playingFile: NowPlaying.activateAudioSession()
                    default: break
                    }
                }
        }
        .onChange(of: backgroundPlayback) { _, on in pip?.setAutomaticStart(on) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                let live = model.state == .connected || model.state == .connecting
                var file = false
                if case .playingFile = model.state { file = true }
                if pip?.isActive == true || (backgroundPlayback && (live || file)) {
                    // Audio continues. Stop decoding video unless the picture moved to a PiP window
                    // (which may start just after this; PictureInPicture re-enables video when it does).
                    if pip?.isActive != true { model.player.setVideoEnabled(false) }
                    resumeOnActive = live
                    model.saveEPG()
                } else if live {
                    // Release the tuner and save the guide.
                    resumeOnActive = true
                    model.disconnect()
                } else if file {
                    model.disconnect()
                }
            case .active:
                model.player.setVideoEnabled(true)
                switch model.state {
                case .connecting, .connected, .playingFile: NowPlaying.activateAudioSession()
                default: break
                }
                // Reconnect if the stream was released, or was lost while in the background.
                if resumeOnActive {
                    resumeOnActive = false
                    switch model.state {
                    case .idle, .failed: model.connect()
                    default: break
                    }
                }
            default:
                break
            }
        }
    }
}
