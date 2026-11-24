import AVFoundation
import SwiftUI

@main
struct BonViewApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Whether to reconnect when the app comes back to the foreground.
    @State private var resumeOnActive = false

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            PlayerScreen()
                .environment(model)
                .onOpenURL { url in
                    // Opened in place from Files: keep access while the file is read.
                    _ = url.startAccessingSecurityScopedResource()
                    model.openFile(url)
                }
                .onAppear {
                    if model.currentProfile != nil, model.state == .idle { model.connect() }
                }
                .onChange(of: model.state) { _, state in
                    // Keep the screen on while something is playing.
                    switch state {
                    case .connected, .playingFile: UIApplication.shared.isIdleTimerDisabled = true
                    default: UIApplication.shared.isIdleTimerDisabled = false
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Nothing is shown in the background: release the tuner and save the guide.
                if model.state == .connected || model.state == .connecting {
                    resumeOnActive = true
                    model.disconnect()
                } else if case .playingFile = model.state {
                    model.disconnect()
                }
            case .active:
                try? AVAudioSession.sharedInstance().setActive(true)
                if resumeOnActive {
                    resumeOnActive = false
                    model.connect()
                }
            default:
                break
            }
        }
    }
}
