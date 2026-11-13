// Generates Resources/AppIcon.icns (and a 1024px PNG preview) for BonView.
//   swift scripts/make_icon.swift
// Everything is drawn with CoreGraphics paths (no SF Symbols / third-party artwork).
import AppKit
import CoreGraphics

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    // Flip to top-left origin for easier layout.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: 824×824 body with ~185 corner radius, centred, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x1B2366))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x4C6BFF), rgb(0x2A2F9E), rgb(0x151A4F)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Glossy top light.
    let gloss = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gloss, startCenter: CGPoint(x: 512, y: 120), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 120), endRadius: 620, options: [])
    ctx.restoreGState()

    // Antenna.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(26)
    let hub = CGPoint(x: 512, y: 352)
    for tip in [CGPoint(x: 404, y: 214), CGPoint(x: 626, y: 196)] {
        ctx.move(to: hub)
        ctx.addLine(to: tip)
        ctx.strokePath()
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: tip.x - 24, y: tip.y - 24, width: 48, height: 48))
    }

    // Set body (white bezel) with shadow.
    let tv = CGRect(x: 214, y: 340, width: 596, height: 420)
    let tvPath = CGPath(roundedRect: tv, cornerWidth: 78, cornerHeight: 78, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: rgb(0x000000, 0.35))
    ctx.addPath(tvPath)
    ctx.setFillColor(rgb(0xF4F6FF))
    ctx.fillPath()
    ctx.restoreGState()

    // Screen.
    let screen = tv.insetBy(dx: 38, dy: 38)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 46, cornerHeight: 46, transform: nil)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    let scr = CGGradient(colorsSpace: space, colors: [rgb(0x0B1030), rgb(0x23307A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(scr, start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])

    // Signal waves from the lower-left corner of the screen.
    let origin = CGPoint(x: screen.minX + 76, y: screen.maxY - 64)
    ctx.setLineWidth(30)
    for (i, r) in [CGFloat(78), 142, 206].enumerated() {
        ctx.setStrokeColor(rgb(0x7FE3FF, 1 - CGFloat(i) * 0.22))
        ctx.addArc(center: origin, radius: r, startAngle: -.pi / 2 + 0.12, endAngle: -0.12, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(rgb(0x7FE3FF))
    ctx.fillEllipse(in: CGRect(x: origin.x - 30, y: origin.y - 30, width: 60, height: 60))

    // Play mark.
    let c = CGPoint(x: screen.maxX - 112, y: screen.midY + 4)
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: c.x - 46, y: c.y - 62))
    tri.addLine(to: CGPoint(x: c.x + 62, y: c.y))
    tri.addLine(to: CGPoint(x: c.x - 46, y: c.y + 62))
    tri.closeSubpath()
    ctx.addPath(tri)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(22)
    ctx.setStrokeColor(rgb(0xFF8A3D))
    ctx.setFillColor(rgb(0xFF8A3D))
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    // Stand.
    ctx.setFillColor(rgb(0xF4F6FF))
    let feet = CGMutablePath()
    feet.addRoundedRect(in: CGRect(x: 330, y: 754, width: 70, height: 52), cornerWidth: 18, cornerHeight: 18)
    feet.addRoundedRect(in: CGRect(x: 624, y: 754, width: 70, height: 52), cornerWidth: 18, cornerHeight: 18)
    ctx.addPath(feet)
    ctx.fillPath()
}

func png(_ size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(ctx, size: CGFloat(size))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let resources = root.appendingPathComponent("Resources")
try png(1024).write(to: resources.appendingPathComponent("AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil failed")
