// Draws the app icon (1024x1024 PNG) and builds Resources/AppIcon.icns with iconutil.
// Run: swift tools/make_icon.swift
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded tile with a deep blue → teal gradient (macOS icon grid: 824pt tile centred in 1024).
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
path.fill()
ctx.restoreGState()
path.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.18, blue: 0.42, alpha: 1),
                    NSColor(srgbRed: 0.10, green: 0.52, blue: 0.62, alpha: 1)])!.draw(in: tile, angle: 60)

// 2x2 grid of frosted "widget" cards; one shows a tiny bar chart.
let pad: CGFloat = 92, gap: CGFloat = 56
let cell = (tile.width - pad * 2 - gap) / 2
for row in 0..<2 {
    for col in 0..<2 {
        let r = NSRect(x: tile.minX + pad + CGFloat(col) * (cell + gap),
                       y: tile.minY + pad + CGFloat(row) * (cell + gap), width: cell, height: cell)
        let card = NSBezierPath(roundedRect: r, xRadius: 58, yRadius: 58)
        NSColor.white.withAlphaComponent(row == 1 && col == 0 ? 0.95 : 0.30).setFill()
        card.fill()
        if row == 1 && col == 0 {
            let heights: [CGFloat] = [0.35, 0.6, 0.45, 0.8]
            let bw: CGFloat = 34, bg: CGFloat = 20
            let total = CGFloat(heights.count) * bw + CGFloat(heights.count - 1) * bg
            var x = r.midX - total / 2
            for h in heights {
                let bar = NSRect(x: x, y: r.minY + 52, width: bw, height: (r.height - 104) * h)
                NSColor(srgbRed: 0.10, green: 0.45, blue: 0.62, alpha: 1).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10).fill()
                x += bw + bg
            }
        }
    }
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = URL(fileURLWithPath: "build/icon_1024.png")
try! png.write(to: master)

for s in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = s * scale
        let name = scale == 1 ? "icon_\(s)x\(s).png" : "icon_\(s)x\(s)@2x.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
    }
}
let ic = Process()
ic.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
ic.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! ic.run(); ic.waitUntilExit()
print(ic.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
