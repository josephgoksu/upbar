// Draws the app icon. Run: swift scripts/icon.swift && open Upbar.icns
// Seven bars like the menu bar sparkline, the last one rising in green: "it's up".
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024  // design on Apple's 1024 grid: 824 pt body, 100 pt margin
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
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
    let width = 56 * s, gap = 30 * s, base = 300 * s, full = 520 * s
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
iconutil.arguments = ["-c", "icns", set.path, "-o", "Upbar.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: set)
try! draw(1024).write(to: URL(fileURLWithPath: "icon.png"))
print("Wrote Upbar.icns and icon.png")
