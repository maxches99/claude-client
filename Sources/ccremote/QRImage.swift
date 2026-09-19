import Foundation
import CoreImage
import AppKit

/// Renders a pairing URL to a crisp black-on-white PNG with a quiet zone.
/// The terminal (ANSI half-block) QR is fine for short payloads but gets dense and hard to
/// scan once the URL carries a relay + room + fingerprint — so we also write a PNG file.
enum QRImage {
    @discardableResult
    static func write(_ text: String, to path: String, scale: Int = 12, quiet: Int = 4) -> Bool {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return false }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return false }
        let modules = Int(ci.extent.width)
        guard modules > 0 else { return false }
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
        guard let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
