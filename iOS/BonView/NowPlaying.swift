import AVFoundation
import MediaCore
import MediaPlayer
import TSCore
import UIKit

/// Audio session, Control Center / lock screen "Now Playing" and remote commands (headphones,
/// Control Center, CarPlay-style controls).
///
/// Live TV cannot pause: pause stops the stream and releases the tuner, play connects again.
/// Next / previous track step through the channel list.
@MainActor
final class NowPlaying {
    private let model: AppModel
    private var artwork: MPMediaItemArtwork?
    private var artworkKey = ""
    private var artworkTask: Task<Void, Never>?
    /// Something was playing since launch (keeps the app in Control Center after a stop).
    private var hasPlayed = false
    private var lastInfoKey = ""

    init(model: AppModel) {
        self.model = model
    }

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // Long-form video routes: AirPlay speakers / Apple TV, Bluetooth and wired outputs.
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? session.setActive(true)
    }

    func start() {
        Self.configureAudioSession()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play() ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.stop() ?? .commandFailed }
        center.stopCommand.addTarget { [weak self] _ in self?.stop() ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.isPlaying ? self.stop() : self.play()
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.step(1) ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.step(-1) ?? .commandFailed }
        for c in [center.seekForwardCommand, center.seekBackwardCommand, center.skipForwardCommand,
                  center.skipBackwardCommand, center.changePlaybackPositionCommand, center.changePlaybackRateCommand] {
            c.isEnabled = false
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            MainActor.assumeIsolated {
                // Phone call / Siri over: take the audio back and restart the clock.
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.model.player.resync()
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRouteLatency() }
        }
        applyRouteLatency()
        observe()
    }

    private var isPlaying: Bool {
        switch model.state {
        case .connected, .connecting, .playingFile: return true
        default: return false
        }
    }

    private func play() -> MPRemoteCommandHandlerStatus {
        guard model.currentProfile != nil else { return .noActionableNowPlayingItem }
        if !isPlaying {
            Self.configureAudioSession()
            model.connect()
        }
        return .success
    }

    private func stop() -> MPRemoteCommandHandlerStatus {
        if isPlaying { model.disconnect() }
        return .success
    }

    private func step(_ delta: Int) -> MPRemoteCommandHandlerStatus {
        guard model.state == .connected, !model.spaces.isEmpty else { return .commandFailed }
        model.stepChannel(delta)
        return .success
    }

    /// AirPlay adds seconds of output latency; give the audio renderer more data ahead of the clock.
    private func applyRouteLatency() {
        let airPlay = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        let presenter = model.player.presenter
        let latency = airPlay ? 2.0 : 0.4
        guard presenter.latency != latency else { return }
        presenter.latency = latency
        presenter.maxBuffered = airPlay ? 4.0 : 2.5
        model.player.resync()
    }

    // MARK: - Now Playing info

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        let playing = isPlaying
        let channel = model.channelTitle
        let event: EventInfo? = if case .connected = model.state { model.presentEvent } else { nil }
        let clock = model.programClock
        if playing { hasPlayed = true }
        guard hasPlayed else { return }

        // Re-publish only when what is shown changes (the system extrapolates elapsed time).
        let key = "\(playing)|\(channel)|\(event.map { "\($0.eventID)|\($0.title)" } ?? "-")"
        guard key != lastInfoKey else { return }
        lastInfoKey = key

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: event?.title ?? channel,
            MPMediaItemPropertyArtist: event == nil ? "BonView" : channel,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let ev = event, let start = ev.start, let duration = ev.duration, duration > 0 {
            // Programme progress as the scrubber (seeking is disabled).
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = min(max(0, (clock ?? Date()).timeIntervalSince(start)), duration)
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if playing { scheduleArtwork(for: channel) }
    }

    /// Use a frame of the channel as artwork once the picture is up (not possible in the background,
    /// where video is not decoded; the previous artwork stays).
    private func scheduleArtwork(for channel: String) {
        guard channel != artworkKey else { return }
        artworkTask?.cancel()
        artworkTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.model.channelTitle == channel else { return }
                if UIApplication.shared.applicationState == .background { continue }
                guard let pb = self.model.player.presenter.currentFrame(),
                      let cg = FrameSnapshot.cgImage(from: pb) else { continue }
                let image = UIImage(cgImage: cg)
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artworkKey = channel
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    info[MPMediaItemPropertyArtwork] = self.artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
                return
            }
        }
    }
}
