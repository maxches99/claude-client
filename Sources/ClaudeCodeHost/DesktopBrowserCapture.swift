#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit
import ClaudeRemoteCore

/// Reads what Claude Desktop's built-in browser shows, for a phone to look over the agent's shoulder.
/// The pages come from Accessibility (each open tab is a web area with its own address); the picture is
/// Desktop's main window through ScreenCaptureKit — the pane's own frame isn't reported reliably, so the
/// window is sent whole.
enum DesktopBrowserCapture {
    static func snapshot() async throws -> DesktopBrowserSnapshot {
        guard AXIsProcessTrusted() else { throw DesktopSitePrompt.Failure.notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: DesktopSitePrompt.bundleId).first else {
            throw DesktopSitePrompt.Failure.desktopNotRunning
        }
        let pages = await Task.detached(priority: .userInitiated) { readPages(pid: app.processIdentifier) }.value
        let image = try? await windowJpeg(pid: app.processIdentifier)
        return DesktopBrowserSnapshot(pages: pages, windowJpegBase64: image?.base64EncodedString())
    }

    private static func readPages(pid: pid_t) -> [DesktopBrowserSnapshot.Page] {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var result: [DesktopBrowserSnapshot.Page] = []
        var stack = [root]
        var visited = 0
        while let el = stack.popLast(), visited < 30_000 {
            visited += 1
            if DesktopSitePrompt.role(el) == "AXWebArea" {
                let raw = DesktopSitePrompt.value(el, "AXURL")
                let url = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                if DesktopBrowserSnapshot.isBrowserPage(url) {
                    let title = DesktopSitePrompt.value(el, kAXTitleAttribute) as? String ?? ""
                    let text = DesktopSitePrompt.staticTexts(in: el, limit: 600).joined(separator: " ")
                    result.append(.init(url: url, title: title, text: String(text.prefix(1500))))
                    continue
                }
            }
            stack.append(contentsOf: DesktopSitePrompt.children(el).reversed())
        }
        return result
    }

    /// Desktop's largest on-screen window, scaled to at most 1600 px wide.
    private static func windowJpeg(pid: pid_t) async throws -> Data? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.frame.height > 200 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        // Retina detail, but no wider than 1600 px.
        let factor = min(2, 1600 / max(window.frame.width, 1))
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * factor)
        config.height = Int(window.frame.height * factor)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}

extension SessionManager {
    public func desktopBrowserSnapshot() async throws -> DesktopBrowserSnapshot {
        try await DesktopBrowserCapture.snapshot()
    }
}
#endif
