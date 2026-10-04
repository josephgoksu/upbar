// Draws the app icon and the GitHub social preview. Run from the repo root: swift scripts/icon.swift
// Seven bars like the menu bar sparkline, the last one rising in green: "it's up".
import AppKit

func draw(_ px: Int) -> Data {
    let rep = canvas(px, px)
    drawIcon(in: NSRect(x: 0, y: 0, width: px, height: px))
    return rep.representation(using: .png, properties: [:])!
}

func canvas(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    return rep
}

func drawIcon(in frame: NSRect) {
    let s = frame.width / 1024  // design on Apple's 1024 grid: 824 pt body, 100 pt margin
    let body = NSRect(x: frame.minX + 100 * s, y: frame.minY + 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.26, alpha: 1),
               ending: NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1))!.draw(in: squircle, angle: -90)

    let heights: [CGFloat] = [0.30, 0.44, 0.36, 0.52, 0.40, 0.48, 0.82]
    let width = 56 * s, gap = 30 * s, base = frame.minY + 300 * s, full = 520 * s
    let left = body.midX - (CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap) / 2
    for (i, h) in heights.enumerated() {
        let bar = NSBezierPath(roundedRect: NSRect(x: left + CGFloat(i) * (width + gap), y: base, width: width, height: full * h),
                               xRadius: width / 2, yRadius: width / 2)
        if i == heights.count - 1 {
            NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.84, blue: 0.42, alpha: 1),
                       ending: NSColor(srgbRed: 0.55, green: 0.95, blue: 0.55, alpha: 1))!.draw(in: bar, angle: 90)
        } else {
            NSColor.white.withAlphaComponent(0.92).setFill()
            bar.fill()
        }
    }
}

func socialPreview() -> Data {
    let rep = canvas(1280, 640)
    NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1280, height: 640).fill()
    drawIcon(in: NSRect(x: 90, y: 140, width: 360, height: 360))
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 110, weight: .bold), .foregroundColor: NSColor.white]
    let tagline: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .regular), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
    ("Upbar" as NSString).draw(at: NSPoint(x: 500, y: 330), withAttributes: title)
    ("Is it up? Uptime checks in your menu bar." as NSString).draw(at: NSPoint(x: 504, y: 260), withAttributes: tagline)
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "Upbar.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! draw(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! draw(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", "Resources/Upbar.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: set)
try! draw(1024).write(to: URL(fileURLWithPath: "docs/icon.png"))
try! socialPreview().write(to: URL(fileURLWithPath: "docs/social-preview.png"))
print("Wrote Resources/Upbar.icns, docs/icon.png, docs/social-preview.png")
