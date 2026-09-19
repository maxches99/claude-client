#!/usr/bin/swift
// Renders the ClaudeRemote Host app icon (a phone with radio waves on a clay squircle) into
// ClaudeRemoteHost/Assets.xcassets/AppIcon.appiconset. Run from the repo root:
//   swift scripts/make-icon.swift
// Pure geometry — no SF Symbols (they may not be used in app icons).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ClaudeRemoteHost/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size / 1024
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon grid: the shape fills 824/1024 of the canvas, corner radius ≈ 22.5%.
    let inset = 100 * s
    let shape = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: shape, xRadius: 185 * s, yRadius: 185 * s)
    let clay = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)        // #D97757
    let clayDark = NSColor(srgbRed: 0.72, green: 0.36, blue: 0.23, alpha: 1)
    NSGradient(starting: clay, ending: clayDark)!.draw(in: squircle, angle: -90)

    // Phone body: rounded outline, centre-left.
    let ink = NSColor(white: 1, alpha: 0.96)
    let phone = NSRect(x: 300 * s, y: 262 * s, width: 268 * s, height: 500 * s)
    let body = NSBezierPath(roundedRect: phone, xRadius: 54 * s, yRadius: 54 * s)
    body.lineWidth = 40 * s
    ink.setStroke()
    body.stroke()
    // Speaker slot + home bar.
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: phone.midX - 46 * s, y: phone.maxY - 66 * s, width: 92 * s, height: 20 * s), xRadius: 10 * s, yRadius: 10 * s).fill()
    NSBezierPath(roundedRect: NSRect(x: phone.midX - 60 * s, y: phone.minY + 44 * s, width: 120 * s, height: 20 * s), xRadius: 10 * s, yRadius: 10 * s).fill()

    // Radio waves: three arcs to the right of the phone, centred on its right edge.
    let center = NSPoint(x: phone.maxX + 20 * s, y: phone.midY)
    for (i, radius) in [90.0, 170.0, 250.0].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: CGFloat(radius) * s, startAngle: -38, endAngle: 38)
        arc.lineWidth = 40 * s
        arc.lineCapStyle = .round
        NSColor(white: 1, alpha: 0.96 - CGFloat(i) * 0.12).setStroke()
        arc.stroke()
    }
    NSBezierPath(ovalIn: NSRect(x: center.x - 24 * s, y: center.y - 24 * s, width: 48 * s, height: 48 * s)).fill()

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// (point size, scale) pairs macOS asset catalogs expect.
let entries: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in entries {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try png(draw(size: CGFloat(pixels)), pixels: pixels).write(to: root.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: root.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(root.path)")
