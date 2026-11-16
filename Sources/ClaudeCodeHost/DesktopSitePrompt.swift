#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import ClaudeRemoteCore

/// Answers Claude Desktop's "allow this site?" card for its built-in browser. The card comes from the
/// app's own permission broker — no hook or CLI channel reaches it — so the host presses its button
/// through Accessibility, the way someone at the Mac would. The session is brought up in Desktop's
/// sidebar first when the card isn't on screen.
public enum DesktopSitePrompt {
    public enum Failure: Error, CustomStringConvertible {
        case notTrusted
        case desktopNotRunning
        case noPrompt

        public var description: String {
            switch self {
            case .notTrusted: return "The Host app has no Accessibility access on this Mac, so it can't press buttons in Claude Desktop. Turn it on in the Host's Permissions window."
            case .desktopNotRunning: return "Claude Desktop is not running on this Mac."
            case .noPrompt: return "No site prompt is showing in Claude Desktop for this session — it may have been answered already."
            }
        }
    }

    static let bundleId = "com.anthropic.claudefordesktop"

    /// Desktop's labels for the card's buttons (its en-US strings).
    static func label(_ answer: SitePromptAnswer) -> String {
        switch answer {
        case .allowOnce: return "Allow once"
        case .alwaysAllow: return "Always allow"
        case .cancel: return "Cancel"
        }
    }

    /// Presses `answer` on the card of the Desktop session that runs CLI session `sessionId`. Returns the
    /// card's text, for the log. Blocking (Accessibility calls are synchronous) — call off the main actor.
    public static func answer(_ answer: SitePromptAnswer, sessionId: String, fallbackTitle: String?) throws -> String {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            throw Failure.desktopNotRunning
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium builds its web content tree only for assistive apps that ask for it.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var card = waitForCard(in: root, timeout: 1)
        if card == nil, let title = desktopTitle(cliSessionId: sessionId) ?? fallbackTitle,
           let row = find(in: root, where: { role($0) == kAXButtonRole && text($0) == title }) {
            AXUIElementPerformAction(row, kAXPressAction as CFString)
            card = waitForCard(in: root, timeout: 3)
        }
        guard let card, let button = find(in: card, where: { role($0) == kAXButtonRole && text($0) == label(answer) }) else {
            throw Failure.noPrompt
        }
        let summary = staticTexts(in: card).joined(separator: " ").prefix(240)
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        if answer == .alwaysAllow { confirmAlwaysAllow(in: root) }
        return String(summary)
    }

    /// Sites on a local name ask once more ("Always allow Claude on host?") before they are kept.
    private static func confirmAlwaysAllow(in root: AXUIElement) {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            guard let question = find(in: root, where: { el in
                role(el) == kAXStaticTextRole && (text(el).map { $0.hasPrefix("Always allow") && $0.hasSuffix("?") } ?? false)
            }) else { continue }
            var node = question
            for _ in 0..<6 {
                guard let parent = element(node, kAXParentAttribute) else { break }
                node = parent
                if let button = find(in: node, where: { role($0) == kAXButtonRole && (text($0)?.hasPrefix("Always allow") ?? false) }) {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                    return
                }
            }
        }
    }

    /// The smallest element holding both "Allow once" and "Cancel" — the card, not some other Cancel.
    private static func waitForCard(in root: AXUIElement, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let allowOnce = find(in: root, where: { role($0) == kAXButtonRole && text($0) == label(.allowOnce) }) {
                var node = allowOnce
                for _ in 0..<6 {
                    guard let parent = element(node, kAXParentAttribute) else { break }
                    node = parent
                    if find(in: node, where: { role($0) == kAXButtonRole && text($0) == label(.cancel) }) != nil { return node }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// The title Desktop shows in its sidebar for the session running `cliSessionId`.
    static func desktopTitle(cliSessionId: String) -> String? {
        guard let dir = ClaudeDesktopSessions.activeDirectory() else { return nil }
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasPrefix("local_") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  record["cliSessionId"] as? String == cliSessionId else { continue }
            return record["title"] as? String
        }
        return nil
    }

    // MARK: Accessibility helpers

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func role(_ el: AXUIElement) -> String? { value(el, kAXRoleAttribute) as? String }

    static func text(_ el: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s = value(el, attr) as? String, !s.isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Depth-first, capped so a huge transcript can't stall the host.
    static func find(in root: AXUIElement, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        var stack = [root]
        var visited = 0
        while let el = stack.popLast(), visited < 20_000 {
            visited += 1
            if match(el) { return el }
            stack.append(contentsOf: children(el).reversed())
        }
        return nil
    }

    static func staticTexts(in root: AXUIElement, limit: Int = 200) -> [String] {
        var out: [String] = []
        var stack = [root]
        var visited = 0
        while let el = stack.popLast(), visited < limit {
            visited += 1
            if role(el) == kAXStaticTextRole, let s = text(el) { out.append(s) }
            stack.append(contentsOf: children(el).reversed())
        }
        return out
    }
}
#endif
