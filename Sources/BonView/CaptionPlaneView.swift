import AVFoundation
import SwiftUI
import TSCore

/// Draws a caption / superimpose plane as broadcast: each glyph at its position, size and colour,
/// with DRCS patterns as bitmaps. The plane is mapped onto the aspect-fitted picture rectangle.
struct CaptionPlaneView: View {
    let frame: CaptionFrame
    let videoSize: CGSize

    /// Rounded gothic is the usual look of Japanese TV captions; falls back to the system font.
    private static let fontName = NSFont(name: "HiraMaruProN-W4", size: 12) != nil ? "HiraMaruProN-W4" : "HiraginoSans-W4"

    var body: some View {
        GeometryReader { geo in
            let rect = AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: geo.size))
            Canvas { ctx, _ in
                draw(in: &ctx, rect: rect)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(in ctx: inout GraphicsContext, rect: CGRect) {
        guard !frame.glyphs.isEmpty else { return }
        let sx = rect.width / frame.planeWidth, sy = rect.height / frame.planeHeight
        func cellRect(_ g: CaptionGlyph) -> CGRect {
            CGRect(x: rect.minX + g.x * sx, y: rect.minY + g.y * sy, width: g.width * sx, height: g.height * sy)
        }

        // Backgrounds, underline and enclosure first, without an outline.
        for g in frame.glyphs {
            let cell = cellRect(g)
            if !g.background.isTransparent {
                ctx.fill(Path(cell), with: .color(g.background.color))
            }
            let stroke = max(1, sy)
            if g.underline {
                ctx.fill(Path(CGRect(x: cell.minX, y: cell.maxY - stroke, width: cell.width, height: stroke)), with: .color(g.foreground.color))
            }
            if g.enclosure != 0 {
                var p = Path()
                if g.enclosure & 1 != 0 { p.move(to: CGPoint(x: cell.minX, y: cell.maxY)); p.addLine(to: CGPoint(x: cell.maxX, y: cell.maxY)) }
                if g.enclosure & 2 != 0 { p.move(to: CGPoint(x: cell.maxX, y: cell.minY)); p.addLine(to: CGPoint(x: cell.maxX, y: cell.maxY)) }
                if g.enclosure & 4 != 0 { p.move(to: CGPoint(x: cell.minX, y: cell.minY)); p.addLine(to: CGPoint(x: cell.maxX, y: cell.minY)) }
                if g.enclosure & 8 != 0 { p.move(to: CGPoint(x: cell.minX, y: cell.minY)); p.addLine(to: CGPoint(x: cell.minX, y: cell.maxY)) }
                ctx.stroke(p, with: .color(g.foreground.color), lineWidth: stroke)
            }
        }

        // Characters, with a dark edge so they stay readable on a transparent background.
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.9), radius: max(0.8, 1.2 * sy)))
            for g in frame.glyphs {
                let cell = cellRect(g)
                let box = CGRect(x: cell.midX - g.charWidth * sx / 2, y: cell.midY - g.charHeight * sy / 2,
                                 width: g.charWidth * sx, height: g.charHeight * sy)
                switch g.content {
                case .text(let s):
                    guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    let text = layer.resolve(Text(s).font(.custom(Self.fontName, size: box.height * 0.92))
                        .foregroundColor(g.foreground.color))
                    var c = layer
                    c.translateBy(x: box.midX, y: box.midY)
                    c.scaleBy(x: box.width / max(box.height, 1), y: 1) // half-width (MSZ) / double-width
                    c.draw(text, at: .zero, anchor: .center)
                case .drcs(let pattern):
                    if let image = DRCSImageCache.shared.image(pattern, color: g.foreground) {
                        layer.draw(Image(decorative: image, scale: 1), in: box)
                    }
                }
            }
        }
    }
}

extension CaptionColor {
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

/// DRCS pattern + colour → CGImage (main thread only).
@MainActor
final class DRCSImageCache {
    static let shared = DRCSImageCache()
    private var cache: [Key: CGImage] = [:]

    private struct Key: Hashable {
        var pattern: CaptionDRCS
        var color: CaptionColor
    }

    func image(_ p: CaptionDRCS, color: CaptionColor) -> CGImage? {
        let key = Key(pattern: p, color: color)
        if let img = cache[key] { return img }
        guard p.width > 0, p.height > 0, p.pixels.count == p.width * p.height else { return nil }
        let levels = Double(max(p.depth + 1, 1))
        var rgba = [UInt8](repeating: 0, count: p.width * p.height * 4)
        for (n, v) in p.pixels.enumerated() {
            let a = min(1, Double(v) / levels) * Double(color.a) / 255
            // Premultiplied alpha.
            rgba[n * 4] = UInt8(Double(color.r) * a)
            rgba[n * 4 + 1] = UInt8(Double(color.g) * a)
            rgba[n * 4 + 2] = UInt8(Double(color.b) * a)
            rgba[n * 4 + 3] = UInt8(255 * a)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: p.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        if cache.count > 512 { cache.removeAll() }
        cache[key] = img
        return img
    }
}
