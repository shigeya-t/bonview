import AVFoundation
import SwiftUI

// MARK: - Captions

/// Caption text over the picture. The picture is aspect-fitted into the view, so the text is
/// placed relative to that rectangle and sized like ARIB's 960×540 plane with 36-dot characters.
struct CaptionOverlay: View {
    let lines: [String]
    let videoSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let rect = AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: geo.size))
            let fontSize = max(10, rect.height / 15 * 0.85)
            VStack {
                Spacer(minLength: 0)
                if !lines.isEmpty {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: fontSize, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 1.5)
                        .padding(.horizontal, fontSize * 0.4)
                        .padding(.vertical, fontSize * 0.15)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: fontSize * 0.2))
                }
            }
            .padding(.bottom, rect.height * 0.06)
            .padding(.horizontal, rect.width * 0.03)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }
}
