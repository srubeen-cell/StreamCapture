// Draws the StreamCapture app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Body: Apple's macOS grid, an 824pt rounded square with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x4F46E5))
    ctx.fillPath()
    ctx.restoreGState()

    // Indigo gradient, lighter at the top (same accent as the app).
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space,
                        colors: [color(0x818CF8), color(0x6366F1), color(0x4338CA)] as CFArray,
                        locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    // Gentle glass sheen across the top half.
    let sheen = CGGradient(colorsSpace: space,
                           colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // A white app window: the thing being recorded.
    let window = CGRect(x: 232, y: 300, width: 560, height: 420)
    let windowPath = CGPath(roundedRect: window, cornerWidth: 48, cornerHeight: 48, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x1E1B4B, 0.35))
    ctx.addPath(windowPath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Title bar strip and traffic-light dots.
    ctx.saveGState()
    ctx.addPath(windowPath)
    ctx.clip()
    ctx.setFillColor(color(0xEEF2FF))
    ctx.fill(CGRect(x: window.minX, y: window.maxY - 74, width: window.width, height: 74))
    ctx.restoreGState()
    for (i, hex) in [UInt32(0xF87171), 0xFBBF24, 0x34D399].enumerated() {
        ctx.setFillColor(color(hex))
        ctx.fillEllipse(in: CGRect(x: window.minX + 36 + CGFloat(i) * 40, y: window.maxY - 51, width: 26, height: 26))
    }

    // Red record button in the middle of the window, with a soft ring.
    let centre = CGPoint(x: window.midX, y: window.minY + (window.height - 74) / 2)
    ctx.setFillColor(color(0xDC2626, 0.14))
    ctx.fillEllipse(in: CGRect(x: centre.x - 118, y: centre.y - 118, width: 236, height: 236))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: color(0xDC2626, 0.45))
    let dot = CGRect(x: centre.x - 82, y: centre.y - 82, width: 164, height: 164)
    ctx.addEllipse(in: dot)
    ctx.clip()
    let red = CGGradient(colorsSpace: space, colors: [color(0xF87171), color(0xDC2626)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(red, start: CGPoint(x: centre.x, y: dot.maxY), end: CGPoint(x: centre.x, y: dot.minY), options: [])
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
