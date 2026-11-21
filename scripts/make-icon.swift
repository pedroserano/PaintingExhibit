// Draws the app icon: a gold-framed painting (smiling sun over hills) under a gallery spotlight.
// Run from the repo root:  swift scripts/make-icon.swift
// Writes the iPhone/iPad icon into the asset catalog and Mac/AppIcon.icns for the Mac app.
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func linear(_ c: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func path(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Artwork in a 1024 × 1024 space, origin bottom-left: a gold framed-picture symbol on deep navy.
func drawArt(_ c: CGContext) {
    c.setFillColor(rgb(0x1B2440)); c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    c.setFillColor(rgb(0xF5B83D))

    // Frame.
    let outer = CGRect(x: 172, y: 232, width: 680, height: 560)
    let inner = outer.insetBy(dx: 62, dy: 62)
    let ring = CGMutablePath(); ring.addPath(path(outer, 84)); ring.addPath(path(inner, 26))
    c.addPath(ring); c.fillPath(using: .evenOdd)

    // Sun and mountains inside, with a gap from the frame.
    let art = inner.insetBy(dx: 48, dy: 48)
    c.fillEllipse(in: CGRect(x: art.maxX - 130, y: art.maxY - 130, width: 120, height: 120))
    let m = CGMutablePath()
    m.move(to: CGPoint(x: art.minX, y: art.minY))
    m.addLine(to: CGPoint(x: art.minX, y: art.minY + 60))
    m.addLine(to: CGPoint(x: art.minX + 130, y: art.minY + 230))
    m.addLine(to: CGPoint(x: art.minX + 250, y: art.minY + 90))
    m.addLine(to: CGPoint(x: art.minX + 330, y: art.minY + 175))
    m.addLine(to: CGPoint(x: art.maxX, y: art.minY + 20))
    m.addLine(to: CGPoint(x: art.maxX, y: art.minY))
    m.closeSubpath()
    c.addPath(m); c.setLineJoin(.round); c.setLineWidth(24); c.setStrokeColor(rgb(0xF5B83D))
    c.drawPath(using: .fillStroke)
}

func render(size: Int, mac: Bool) -> Data {
    // iOS icons must be opaque (no alpha); Mac icons need transparent corners.
    let info = mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    let s = CGFloat(size) / 1024
    c.scaleBy(x: s, y: s)
    c.interpolationQuality = .high
    if mac {
        // macOS icon grid: an 824-point rounded square with a shadow, inside the 1024 canvas.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
        c.addPath(shape); c.setFillColor(rgb(0x241A2C)); c.fillPath()
        c.restoreGState()
        c.saveGState(); c.addPath(shape); c.clip()
        c.translateBy(x: 100, y: 100); c.scaleBy(x: 824 / 1024, y: 824 / 1024)
        drawArt(c)
        c.restoreGState()
    } else {
        drawArt(c) // iOS masks the corners itself, so the art fills the square.
    }
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = "PaintingExhibit.swiftpm/App/Assets.xcassets/AppIcon.appiconset"
try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
try render(size: 1024, mac: false).write(to: URL(fileURLWithPath: "\(set)/AppIcon.png"))
try """
{ "images" : [ { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
""".write(toFile: "\(set)/Contents.json", atomically: true, encoding: .utf8)
try """
{ "info" : { "author" : "xcode", "version" : 1 } }
""".write(toFile: "PaintingExhibit.swiftpm/App/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)

let iconset = NSTemporaryDirectory() + "PaintingExhibit.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base, mac: true).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try render(size: base * 2, mac: true).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Mac/AppIcon.icns"]
try p.run(); p.waitUntilExit()
try render(size: 1024, mac: true).write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "PaintingExhibit-mac-preview.png"))
print("Done. Mac preview:", NSTemporaryDirectory() + "PaintingExhibit-mac-preview.png")
