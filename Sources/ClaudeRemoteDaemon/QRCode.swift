#if os(macOS)
import Foundation
import CoreImage

/// Renders a QR code into the terminal using ANSI colours (2 modules per character row).
public enum QRCode {
    public static func terminalLines(for text: String) -> [String]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // render(toBitmap:) writes rows top-down (verified: both top finder patterns land in row 1).
        func dark(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return pixels[(y * width + x) * 4] < 128
        }
        let quiet = 2
        var lines: [String] = []
        var y = -quiet
        while y < height + quiet {
            var line = ""
            for x in -quiet..<(width + quiet) {
                let top = dark(x, y), bottom = dark(x, y + 1)
                // Foreground paints the upper half-block, background the lower half.
                line += "\u{1b}[\(top ? "30" : "37");\(bottom ? "40" : "47")m▀"
            }
            line += "\u{1b}[0m"
            lines.append(line)
            y += 2
        }
        return lines
    }
}
#endif
