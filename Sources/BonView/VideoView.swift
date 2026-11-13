import AppKit
import AVFoundation
import SwiftUI

/// Hosts the AVSampleBufferDisplayLayer. Double-click toggles full screen.
struct VideoView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    /// Called after every layout (size change) with the hosting view.
    var onLayout: ((VideoHostView) -> Void)?

    func makeNSView(context: Context) -> VideoHostView {
        let v = VideoHostView()
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = v.bounds
        v.layer?.addSublayer(displayLayer)
        v.videoLayer = displayLayer
        v.onLayout = onLayout
        return v
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {
        nsView.onLayout = onLayout
    }
}

final class VideoHostView: NSView {
    weak var videoLayer: CALayer?
    var onLayout: ((VideoHostView) -> Void)?

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
        // Report asynchronously: this runs inside AppKit/SwiftUI layout.
        DispatchQueue.main.async { [weak self] in
            if let self { self.onLayout?(self) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            if let self { self.onLayout?(self) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        } else {
            super.mouseDown(with: event)
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }
}
