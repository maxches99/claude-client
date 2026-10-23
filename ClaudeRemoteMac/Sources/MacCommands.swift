import SwiftUI
import AppKit
import ClaudeRemoteCore

/// The menu bar: new sessions and chats, switching hosts, and every tool the phone keeps in its "…" menu.
struct MacCommands: Commands {
    let model: AppModel
    let ui: MacUI

    var body: some Commands {
        SidebarCommands()

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task {
                    let updates = MacUpdates.shared
                    await updates.check()
                    if updates.available { updates.install(); return }
                    let alert = NSAlert()
                    if updates.status?.state == .failed {
                        alert.messageText = "Couldn't check for updates"
                        alert.informativeText = updates.status?.message ?? ""
                    } else {
                        alert.messageText = "ClaudeRemote is up to date"
                        alert.informativeText = "Version \(updates.status?.current ?? "?")."
                    }
                    alert.runModal()
                }
            }
            .disabled(MacUpdates.shared.updating)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Session…") { ui.tab(.sessions); ui.sheet = .newSession }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.isConnected)
            Button("New Chat") { ui.tab(.chats); model.startChat(.claude) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.isConnected || !model.supportsChats)
            if model.hasCodex {
                Button("New Codex Chat") { ui.tab(.chats); model.startChat(.codex) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!model.isConnected || !model.supportsChats)
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Sessions") { ui.tab(.sessions) }.keyboardShortcut("1", modifiers: .command)
            Button("Chats") { ui.tab(.chats) }.keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("Go to…") { ui.sheet = .quickOpen }.keyboardShortcut("k", modifiers: .command)
            Button("Previous Session") { model.stepSession(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Session") { model.stepSession(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button(ui.showTerminal ? "Hide Terminal" : "Show Terminal") { ui.showTerminal.toggle() }
                .keyboardShortcut("`", modifiers: .control)
            Divider()
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isConnected)
        }

        CommandMenu("Host") {
            ForEach(Array(model.macs.enumerated()), id: \.element.id) { index, mac in
                Toggle(isOn: Binding(get: { model.activeMacId == mac.id }, set: { if $0 { model.switchTo(mac.id) } })) {
                    Text(mac.displayName)
                }
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control]) : nil)
            }
            if model.macs.count > 1 {
                Toggle("Show Every Host in the List", isOn: Binding(get: { model.showAllMacs }, set: { model.showAllMacs = $0 }))
                    .disabled(!model.watchAllMacs)
            }
            Divider()
            Button("Add Host…") { ui.sheet = .addHost }
        }

        CommandMenu("Tools") {
            Button("Approvals Inbox") { ui.sheet = .inbox }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            if model.supportsMacTools {
                Button("Catch Up…") {
                    let since = model.activeMacId.flatMap { model.lastSeen($0) } ?? Date().addingTimeInterval(-86_400)
                    model.requestDigest(since: min(since, Date().addingTimeInterval(-3600)))
                    ui.sheet = .digest
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            Divider()
            if model.supportsQueue {
                Button("Task Queue…") { ui.sheet = .tasks }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Background Processes…") { ui.sheet = .processes }
            }
            if model.supportsMacTools {
                Button("Terminals…") { ui.sheet = .terminals }
                    .keyboardShortcut("t", modifiers: [.command, .control])
            }
            Button("Simulator…") { ui.sheet = .simulator }
            Divider()
            if model.supportsPipelines {
                Button("Clone a Repository…") { ui.sheet = .clone }
            }
            if model.supportsAutomation {
                Button("Audit…") { ui.sheet = .audit }
            }
            if model.supportsOperations, !model.isMember {
                Button("Feed…") { ui.sheet = .feed }
            }
            if model.supportsSchedules, !model.isMember {
                Button("Crashes…") { ui.sheet = .crashes }
            }
            Button("Translator…") { ui.sheet = .translator }
        }
    }
}

extension MacUI {
    /// Switches the sidebar between work sessions and quick chats.
    func tab(_ tab: AppTab) {
        AppModel.shared?.tab = tab
    }
}
