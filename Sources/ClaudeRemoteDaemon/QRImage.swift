#if os(macOS)
import Foundation
import CoreImage
import AppKit

/// Renders a pairing URL to a crisp black-on-white QR bitmap with a quiet zone.
/// The terminal (ANSI half-block) QR is fine for short payloads but gets dense and hard to
/// scan once the URL carries a relay + room + fingerprint — so the daemon also writes a PNG
/// and the menu-bar app shows the same bitmap on screen.
public enum QRImage {
    /// `scale` pixels per module, `quiet` modules of white border.
    public static func render(_ text: String, scale: Int = 12, quiet: Int = 4) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let modules = Int(ci.extent.width)
        guard modules > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: modules * modules * 4)
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        ctx.render(ci, toBitmap: &buf, rowBytes: modules * 4, bounds: ci.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        func dark(_ x: Int, _ y: Int) -> Bool { buf[(y * modules + x) * 4] < 128 }

        let side = (modules + quiet * 2) * scale
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        NSColor.black.setFill()
        for y in 0..<modules {
            for x in 0..<modules where dark(x, y) {
                let rx = (x + quiet) * scale
                let ry = (modules - 1 - y + quiet) * scale   // NSImage origin is bottom-left
                NSBezierPath(rect: NSRect(x: rx, y: ry, width: scale, height: scale)).fill()
            }
        }
        image.unlockFocus()
        return image
    }

    public static func png(_ text: String, scale: Int = 12, quiet: Int = 4) -> Data? {
        guard let image = render(text, scale: scale, quiet: quiet), let tiff = image.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff) else { return nil }
        return bmp.representation(using: .png, properties: [:])
    }

    @discardableResult
    public static func write(_ text: String, to path: String, scale: Int = 12, quiet: Int = 4) -> Bool {
        guard let data = png(text, scale: scale, quiet: quiet) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
#endif
