import AVFoundation
import SwiftUI
import UIKit

/// Hosts the presenter's AVSampleBufferDisplayLayer.
struct VideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> VideoHostView {
        let v = VideoHostView()
        v.backgroundColor = .black
        displayLayer.frame = v.bounds
        v.layer.addSublayer(displayLayer)
        v.videoLayer = displayLayer
        return v
    }

    func updateUIView(_ uiView: VideoHostView, context: Context) {}
}

final class VideoHostView: UIView {
    weak var videoLayer: CALayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
    }
}
