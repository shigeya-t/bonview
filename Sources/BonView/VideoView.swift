import AppKit
import AVFoundation
import SwiftUI

/// Hosts the AVSampleBufferDisplayLayer. Double-click toggles full screen.
struct VideoView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> VideoHostView {
        let v = VideoHostView()
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = v.bounds
        v.layer?.addSublayer(displayLayer)
        v.videoLayer = displayLayer
        return v
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {}
}

final class VideoHostView: NSView {
    weak var videoLayer: CALayer?

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
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
