import Foundation
import ClaudeRemoteCore

/// A browser for sessions the host runs: Claude Desktop's built-in one is part of the app and never
/// reaches a standalone CLI, so a phone session gets Claude in Chrome (`--chrome`) or Playwright's MCP
/// server instead. The choice is kept per session in `session-browsers.json`, so every respawn (resume
/// after idle, rewind, a fork) brings the same browser back.
extension SessionManager {
    var sessionBrowserStorePath: String? {
        taskStorePath.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("session-browsers.json") }
    }

    func loadSessionBrowsers() {
        guard let path = sessionBrowserStorePath, let data = FileManager.default.contents(atPath: path) else { return }
        sessionBrowsers = (try? JSONDecoder().decode([String: SessionBrowser].self, from: data)) ?? [:]
    }

    func setBrowser(_ browser: SessionBrowser?, for sessionId: String) {
        guard let browser, browser != .none else { return }
        sessionBrowsers[sessionId] = browser
        guard let path = sessionBrowserStorePath else { return }
        try? JSONEncoder().encode(sessionBrowsers).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// What this Mac can offer: Chrome when it is installed, Playwright when `npx` is.
    static func availableBrowsers() -> [SessionBrowser] {
        var list: [SessionBrowser] = [.none]
        #if os(macOS)
        if FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") { list.append(.chrome) }
        #endif
        if locateNpx() != nil { list.append(.playwright) }
        return list
    }

    static func locateNpx() -> String? {
        for p in ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        let path = ClaudeCLI.childEnvironment()["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let p = "\(dir)/npx"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Extra CLI arguments for the session's browser.
    func browserArgs(for sessionId: String) -> [String] {
        switch sessionBrowsers[sessionId] {
        case .chrome:
            return ["--chrome"]
        case .playwright:
            guard let file = playwrightConfigPath() else { return [] }
            return ["--mcp-config", file]
        case .none?, nil:
            return []
        }
    }

    /// An MCP config naming Playwright's server, headless, beside the host's other files.
    private func playwrightConfigPath() -> String? {
        guard let npx = Self.locateNpx(), let base = sessionBrowserStorePath else { return nil }
        let path = ((base as NSString).deletingLastPathComponent as NSString).appendingPathComponent("playwright-mcp.json")
        let config: JSONValue = .object(["mcpServers": .object(["playwright": .object([
            "command": .string(npx),
            "args": .array([.string("-y"), .string("@playwright/mcp@latest"), .string("--headless")]),
        ])])])
        try? Data(config.serializedString().utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }
}
