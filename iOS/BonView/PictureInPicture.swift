import AVKit
import Observation
import UIKit

/// Picture in Picture for the presenter's `AVSampleBufferDisplayLayer` (captions are drawn by SwiftUI
/// over the picture and are not part of the layer, so they are not shown in the PiP window).
///
/// Starts automatically when the app goes to the background while playing. Live TV: the window shows
/// the live UI, pause stops the stream (releasing the tuner) and play connects again, like the
/// Control Center commands.
@MainActor
@Observable
final class PictureInPicture: NSObject {
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private(set) var isPossible = false
    private(set) var isActive = false

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    /// Read by the playback delegate, which AVKit may call off the main thread.
    @ObservationIgnored private let pausedLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var paused = true
    /// The user paused in the PiP window (the stream was released).
    @ObservationIgnored var onUserStop: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func start() {
        guard Self.isSupported, controller == nil else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: model.player.presenter.displayLayer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = true
        // No skip buttons: there is nothing to seek in a live stream.
        c.requiresLinearPlayback = true
        controller = c
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
        observePlayback()
    }

    /// Start automatically on going to the background (follows the background playback setting).
    func setAutomaticStart(_ on: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = on
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    private var isPlaying: Bool {
        switch model.state {
        case .connected, .connecting, .playingFile: return true
        default: return false
        }
    }

    /// Keep the play / pause button of the PiP window in step with the connection.
    private func observePlayback() {
        let playing = withObservationTracking { isPlaying } onChange: { [weak self] in
            Task { @MainActor in self?.observePlayback() }
        }
        pausedLock.lock()
        let changed = paused == playing
        paused = !playing
        pausedLock.unlock()
        if changed { controller?.invalidatePlaybackState() }
    }

    private func setPlaying(_ playing: Bool) {
        if playing {
            if !isPlaying, model.currentProfile != nil {
                NowPlaying.activateAudioSession()
                model.connect()
            }
        } else if isPlaying {
            model.disconnect()
            onUserStop?()
        }
    }

    private func setActive(_ active: Bool) {
        isActive = active
        if active {
            // The picture is visible again even though the app may be in the background.
            model.player.setVideoEnabled(true)
        } else if UIApplication.shared.applicationState == .background {
            model.player.setVideoEnabled(false)
            // PiP closed in the background with background playback off: release the tuner as
            // going to the background would have (reconnects on return).
            let backgroundPlayback = UserDefaults.standard.object(forKey: "backgroundPlayback") as? Bool ?? true
            if !backgroundPlayback, isPlaying { model.disconnect() }
        }
    }

    /// AVKit calls the delegates on the main thread; this keeps them in order (a `Task` each
    /// would not) and still works if one comes from elsewhere.
    nonisolated private func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }
}

extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        onMain { self.setPlaying(playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Infinite range: live content.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        pausedLock.lock(); defer { pausedLock.unlock() }
        return paused
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        onMain { self.setActive(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        onMain { self.setActive(false) }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        onMain { self.setActive(false) }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
