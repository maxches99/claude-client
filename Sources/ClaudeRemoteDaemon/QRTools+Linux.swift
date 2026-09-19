#if os(Linux)
import Foundation

// macOS renders QR codes with CoreImage (QRCode.swift, QRImage.swift). On Linux we shell out to
// `qrencode` (apt install qrencode) when it is installed and simply skip the QR otherwise — the
// pairing URL is always printed as text and can be pasted into the app.

private func qrencode(_ arguments: [String]) -> Data? {
    let fm = FileManager.default
    let candidates = ["/usr/bin/qrencode", "/usr/local/bin/qrencode"]
        + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/qrencode" }
    guard let binary = candidates.first(where: fm.isExecutableFile(atPath:)) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = arguments
    let out = Pipe()
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

/// Terminal QR via `qrencode -t UTF8`.
public enum QRCode {
    public static func terminalLines(for text: String) -> [String]? {
        guard let data = qrencode(["-t", "UTF8", "-m", "2", "-l", "M", text]), let s = String(data: data, encoding: .utf8) else { return nil }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.isEmpty ? nil : lines
    }
}

/// PNG QR via `qrencode -o`.
public enum QRImage {
    public static func write(_ text: String, to path: String) -> Bool {
        qrencode(["-o", path, "-s", "8", "-m", "2", "-l", "M", text]) != nil
    }
}
#endif
