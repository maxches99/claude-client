import SwiftUI
import AppKit
import ClaudeRemoteCore

/// The native Mac client: the iOS app's model and screens in one Mac window — paired hosts (another
/// Mac, the Linux hub) and their sessions in the sidebar, the chat in the detail column — plus menu
/// commands, a Settings window, a menu-bar item for approvals, a Dock badge and notifications.
@main
struct ClaudeRemoteMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var ui = MacUI()

    var body: some Scene {
        Window("ClaudeRemote", id: MacUI.mainWindowId) {
            MacRootView()
                .environment(model)
                .environment(ui)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    MacAttention.shared.attach(model)
                    MacUpdates.shared.start()
                }
        }
        .defaultSize(width: 1240, height: 820)
        .commands { MacCommands(model: model, ui: ui) }

        WindowGroup("Session", id: MacUI.sessionWindowId, for: SessionWindowRef.self) { $ref in
            if let ref {
                SessionWindow(ref: ref)
                    .environment(model)
                    .environment(ui)
                    .frame(minWidth: 560, minHeight: 480)
            }
        }
        .defaultSize(width: 900, height: 780)

        Settings {
            SettingsView()
                .environment(model)
                .environment(ui)
                .formStyle(.grouped)
                .tint(CDS.brand)
                .frame(width: 520, height: 620)
        }

        MenuBarExtra {
            ApprovalsMenu()
                .environment(model)
                .environment(ui)
        } label: {
            MenuBarLabel(count: model.pendingApprovals.count)
        }
        .menuBarExtraStyle(.window)
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window keeps the app (and its connections) running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in AppModel.shared?.enteredForeground() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task { @MainActor in AppModel.shared?.enteredBackground() }
    }
}

/// Mac-only UI state: sheets the menu commands open, so ⌘N and friends work from anywhere in the window.
@Observable
@MainActor
final class MacUI {
    static let mainWindowId = "main"
    static let sessionWindowId = "session"

    enum Sheet: String, Identifiable {
        case newSession, addHost, inbox, tasks, processes, terminals, digest, feed, crashes, clone, audit, simulator, translator, quickOpen
        var id: String { rawValue }
    }

    var sheet: Sheet?
    var columns = NavigationSplitViewVisibility.all
    /// The terminal panel under the chat (remembered across launches).
    var showTerminal = UserDefaults.standard.bool(forKey: "ccremote.mac.terminalPane") {
        didSet { UserDefaults.standard.set(showTerminal, forKey: "ccremote.mac.terminalPane") }
    }
    /// The shell each session's panel opened, so it re-attaches instead of starting another.
    var paneTerminals: [String: String] = [:]
}

/// A session shown in a window of its own ("Open in New Window").
struct SessionWindowRef: Codable, Hashable {
    let macId: String
    let sessionId: String
}

private struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: "asterisk.circle.fill")
        } else {
            Image(systemName: "asterisk.circle")
        }
    }
}
