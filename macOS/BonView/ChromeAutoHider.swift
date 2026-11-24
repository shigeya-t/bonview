import AppKit

/// In full screen, hides the toolbar, side panel and status bar after a few seconds without
/// mouse / keyboard input, and shows them again on the next input. Main thread only.
final class ChromeAutoHider {
    static let delay: TimeInterval = 3

    /// Called with `true` to hide the surrounding UI and `false` to show it again.
    var setHidden: ((Bool) -> Void)?

    private weak var window: NSWindow?
    /// The video view: the UI is only hidden while the pointer is over the picture.
    private weak var videoView: NSView?
    private var monitor: Any?
    private var timer: Timer?
    private var hidden = false

    var isActive: Bool { monitor != nil }

    func start(window: NSWindow, videoView: NSView) {
        stop()
        self.window = window
        self.videoView = videoView
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                       .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
        ) { [weak self] event in
            if event.window == nil || event.window === self?.window { self?.activity() }
            return event
        }
        schedule()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
        if hidden {
            hidden = false
            setHidden?(false)
        }
    }

    private func activity() {
        if hidden {
            hidden = false
            setHidden?(false)
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        // Default run-loop mode only: the timer does not fire while a menu is being tracked.
        let t = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in self?.fire() }
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    private func fire() {
        guard let window, let videoView, NSApp.isActive, window.isKeyWindow, window.attachedSheet == nil
        else { return schedule() }
        let p = videoView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard videoView.bounds.contains(p) else { return schedule() }
        hidden = true
        setHidden?(true)
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}
