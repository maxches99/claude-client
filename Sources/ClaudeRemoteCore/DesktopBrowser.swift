import Foundation

/// What Claude Desktop's built-in browser has open on a host: each page with its address, title and the
/// start of its text, plus a picture of Desktop's window when the host may record the screen.
public struct DesktopBrowserSnapshot: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Identifiable, Sendable {
        public var url: String
        public var title: String
        /// The page's visible text, cut short.
        public var text: String
        public var id: String { url }

        public init(url: String, title: String, text: String) {
            self.url = url
            self.title = title
            self.text = text
        }
    }

    public var pages: [Page]
    /// Desktop's window as JPEG (nil without Screen Recording access or with Desktop hidden).
    public var windowJpegBase64: String?
    public var takenAt: Date

    public init(pages: [Page], windowJpegBase64: String?, takenAt: Date = Date()) {
        self.pages = pages
        self.windowJpegBase64 = windowJpegBase64
        self.takenAt = takenAt
    }

    /// Desktop's own pages (its UI, claude.ai) are not browser tabs.
    public static func isBrowserPage(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased(), url.hasPrefix("http") else { return false }
        return host != "claude.ai" && !host.hasSuffix(".claude.ai")
    }
}

/// A browser for a session the host runs itself. Claude Desktop's built-in browser belongs to the app,
/// not to the CLI, so a phone session gets one of these instead.
public enum SessionBrowser: String, Codable, CaseIterable, Sendable {
    case none
    /// Claude in Chrome: the person's own Chrome on the host, through its extension (`--chrome`).
    case chrome
    /// Playwright's MCP server: a headless browser of its own; screenshots come back as images.
    case playwright

    public var label: String {
        switch self {
        case .none: return "None"
        case .chrome: return "Chrome on the Mac"
        case .playwright: return "Headless (Playwright)"
        }
    }
}
