// Run with: swift scripts/gen-icon.swift  -> writes Resources/AppIcon.icns
// Waveform glyph on the black/blue-glow/grain canvas (spec §8).
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
    path.addClip()

    NSColor(srgbRed: 0.02, green: 0.024, blue: 0.031, alpha: 1).setFill()
    rect.fill()

    let glow = NSGradient(colors: [
        NSColor(srgbRed: 0.247, green: 0.714, blue: 1.0, alpha: 0.9),
        NSColor(srgbRed: 0.039, green: 0.4, blue: 1.0, alpha: 0.45),
        NSColor.clear])!
    glow.draw(fromCenter: NSPoint(x: size * 0.18, y: size * 0.12), radius: 0,
              toCenter: NSPoint(x: size * 0.18, y: size * 0.12), radius: size * 0.95, options: [])

    // grain
    for _ in 0..<Int(size * size * 0.02) {
        let x = CGFloat.random(in: 0..<size), y = CGFloat.random(in: 0..<size)
        NSColor.white.withAlphaComponent(CGFloat.random(in: 0...0.05)).setFill()
        NSRect(x: x, y: y, width: 1, height: 1).fill()
    }

    // waveform bars
    let bars: [CGFloat] = [0.22, 0.42, 0.68, 0.92, 0.6, 0.36, 0.2]
    let barW = size * 0.045
    let gap = size * 0.035
    let totalW = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
    var x = (size - totalW) / 2
    for h in bars {
        let barH = size * 0.55 * h
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: (size - barH) / 2, width: barW, height: barH),
                               xRadius: barW / 2, yRadius: barW / 2)
        NSColor.white.setFill()
        bar.fill()
        x += barW + gap
    }
    img.unlockFocus()
    return img
}

let iconset = "Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                   ("512x512", 512), ("512x512@2x", 1024)] {
    let img = drawIcon(size: CGFloat(px))
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    rep.size = NSSize(width: px, height: px)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
print("iconset written — converting to icns…")
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
task.launch(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "Resources/AppIcon.icns ✓" : "iconutil failed")
