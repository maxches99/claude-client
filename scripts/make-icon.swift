#!/usr/bin/swift
// Renders the app icons on a clay squircle. Run from the repo root:
//   swift scripts/make-icon.swift            # Host: a phone with radio waves → ClaudeRemoteHost/Assets.xcassets
//   swift scripts/make-icon.swift --client   # Mac client: a window with a sidebar and a chat → ClaudeRemoteMac/Assets.xcassets
// An extra argument overrides the output folder. Pure geometry — no SF Symbols (they may not be used in app icons).
import AppKit

var arguments = Array(CommandLine.arguments.dropFirst())
let client = arguments.first == "--client"
if client { arguments.removeFirst() }
let defaultRoot = client ? "ClaudeRemoteMac/Assets.xcassets/AppIcon.appiconset" : "ClaudeRemoteHost/Assets.xcassets/AppIcon.appiconset"
let root = URL(fileURLWithPath: arguments.first ?? defaultRoot)
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

    if client {
        drawWindow(scale: s)
        image.unlockFocus()
        return image
    }

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

/// The Mac client's glyph: a window with a sidebar of rows and a chat of two bubbles.
func drawWindow(scale s: CGFloat) {
    let ink = NSColor(white: 1, alpha: 0.96)
    let window = NSRect(x: 232 * s, y: 292 * s, width: 560 * s, height: 440 * s)
    let frame = NSBezierPath(roundedRect: window, xRadius: 48 * s, yRadius: 48 * s)
    frame.lineWidth = 36 * s
    ink.setStroke()
    frame.stroke()
    // Sidebar divider.
    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: window.minX + 180 * s, y: window.minY))
    divider.line(to: NSPoint(x: window.minX + 180 * s, y: window.maxY))
    divider.lineWidth = 28 * s
    divider.stroke()
    ink.setFill()
    // Sidebar rows.
    for i in 0..<3 {
        let y = window.maxY - (100 + CGFloat(i) * 80) * s
        NSBezierPath(roundedRect: NSRect(x: window.minX + 50 * s, y: y, width: 90 * s, height: 26 * s), xRadius: 13 * s, yRadius: 13 * s).fill()
    }
    // Chat: a reply on the left, the prompt on the right.
    NSBezierPath(roundedRect: NSRect(x: window.minX + 230 * s, y: window.maxY - 170 * s, width: 210 * s, height: 70 * s), xRadius: 35 * s, yRadius: 35 * s).fill()
    NSColor(white: 1, alpha: 0.7).setFill()
    NSBezierPath(roundedRect: NSRect(x: window.maxX - 250 * s, y: window.minY + 80 * s, width: 200 * s, height: 70 * s), xRadius: 35 * s, yRadius: 35 * s).fill()
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
