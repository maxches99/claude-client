import SwiftUI
import ClaudeRemoteCore

/// The main window: the session list as a sidebar and the chat filling the rest, like the desktop app.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUI.self) private var ui
    @State private var windowWidth: CGFloat = .infinity

    var body: some View {
        @Bindable var model = model
        @Bindable var ui = ui
        ZStack {
            if model.macs.isEmpty {
                PairingView()
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CDS.surface0)
            } else {
                NavigationSplitView(columnVisibility: $ui.columns) {
                    MacSidebar()
                        // Squeezed below its width, keep the leading edge in view instead of clipping both.
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                } detail: {
                    NavigationStack {
                        if let id = selectedId {
                            ChatWithTerminal(sessionId: id, showsTerminal: ui.showTerminal && model.tab != .chats)
                            .toolbar {
                                if model.tab != .chats, model.supportsMacTools {
                                    ToolbarItem(placement: .primaryAction) {
                                        Button { ui.showTerminal.toggle() } label: { Image(systemName: "apple.terminal") }
                                            .help(ui.showTerminal ? "Hide the terminal (⌃`)" : "Show a terminal in this project (⌃`)")
                                    }
                                }
                            }
                        } else {
                            placeholder
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
            if model.locked {
                LockView().transition(.opacity)
            }
        }
        .tint(CDS.brand)
        .formStyle(.grouped)
        .background(GeometryReader { geo in Color.clear.preference(key: MacWindowWidthKey.self, value: geo.size.width) })
        .onPreferenceChange(MacWindowWidthKey.self) { windowWidth = $0 }
        .environment(\.windowWidth, windowWidth)
        .animation(.easeInOut(duration: 0.2), value: model.locked)
        .sheet(item: $model.imageViewer) { ImageViewer(target: $0) }
        .sheet(item: $ui.sheet) { sheet in
            if sheet == .quickOpen {
                MacQuickOpen().environment(model).environment(ui)
            } else {
                sheetContent(sheet)
                    .environment(model)
                    .environment(ui)
                    .formStyle(.grouped)
                    .frame(minWidth: 560, idealWidth: 680, minHeight: 480, idealHeight: 640)
            }
        }
        .sheet(item: $model.incomingShare) { draft in ShareDraftView(draft: draft) }
        // Reopen what was open on this host last time, and keep remembering it.
        .onAppear { restoreLastOpen() }
        .onChange(of: model.activeMacId) { _, _ in restoreLastOpen() }
        .onChange(of: model.tab) { _, _ in saveLastOpen() }
        .onChange(of: model.sessionPath) { _, _ in saveLastOpen() }
        .onChange(of: model.chatPath) { _, _ in saveLastOpen() }
        .onOpenURL { url in
            if model.receiveShare(url) { return }
            if model.receivePackageFile(url) { return }
            if url.host == "session", let id = url.pathComponents.dropFirst().first, !id.isEmpty {
                model.openDeepLink(sessionId: id)
                return
            }
            // ccremote://pair?… — a pairing link from the host's menu or its QR code.
            if let info = PairingInfo.parse(pairURL: url.absoluteString) { model.pair(info) }
        }
    }

    private func lastOpenKey(_ macId: String) -> String { "ccremote.mac.lastOpen.\(macId)" }

    private func saveLastOpen() {
        // Switching hosts empties both paths before the new host's are restored: nothing worth saving then.
        guard let macId = model.activeMacId, !(model.sessionPath.isEmpty && model.chatPath.isEmpty) else { return }
        var entry: [String: String] = ["tab": model.tab == .chats ? "chats" : "sessions"]
        entry["session"] = model.sessionPath.last
        entry["chat"] = model.chatPath.last
        UserDefaults.standard.set(entry, forKey: lastOpenKey(macId))
    }

    private func restoreLastOpen() {
        guard let macId = model.activeMacId, model.sessionPath.isEmpty, model.chatPath.isEmpty,
              let entry = UserDefaults.standard.dictionary(forKey: lastOpenKey(macId)) as? [String: String] else { return }
        if let id = entry["session"] { model.sessionPath = [id] }
        if let id = entry["chat"] { model.chatPath = [id] }
        model.tab = entry["tab"] == "chats" ? .chats : .sessions
    }

    /// The session beside the sidebar (each tab remembers its own).
    private var selectedId: String? { model.tab == .chats ? model.chatPath.last : model.sessionPath.last }

    @ViewBuilder private func sheetContent(_ sheet: MacUI.Sheet) -> some View {
        switch sheet {
        case .newSession: NewSessionView(initialCwd: nil)
        case .addHost: PairingView()
        case .inbox: ApprovalsInboxView()
        case .tasks: TasksView()
        case .processes: ProcessesView(sessionId: nil)
        case .terminals: TerminalsView(sessionId: nil)
        case .digest: DigestView()
        case .feed: FeedView()
        case .crashes: CrashesView()
        case .clone: CloneRepositoryView()
        case .audit: AuditView()
        case .simulator: SimulatorView()
        case .translator: TranslatorView()
        case .quickOpen: EmptyView()   // presented on its own above, at its own size
        }
    }

    /// What the detail column shows before a session is picked.
    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: model.tab == .chats ? "bubble.left.and.bubble.right" : "asterisk")
                .font(.system(size: 30, weight: .medium)).foregroundStyle(CDS.textMuted)
            Text(model.tab == .chats ? "Pick a chat" : "Pick a session")
                .font(.title3.weight(.semibold)).foregroundStyle(CDS.textPrimary)
            if let mac = model.activeMac {
                Text("Connected to \(mac.displayName)")
                    .font(CDS.body).foregroundStyle(CDS.textMuted)
            }
            HStack(spacing: 10) {
                if model.tab == .chats {
                    Button("New chat") { model.startChat(.claude) }
                } else {
                    Button("New session") { ui.sheet = .newSession }
                }
            }
            .buttonStyle(CDSButtonStyle(variant: .secondary))
            .disabled(!model.isConnected)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CDS.surface0)
    }
}

private struct MacWindowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The chat, with the terminal pane under it when it is on. AppKit's split view sizes its panes from
/// their ideal width — a transcript's is its longest paragraph — so the panes say how narrow they can be.
struct ChatWithTerminal: View {
    let sessionId: String
    let showsTerminal: Bool

    var body: some View {
        if showsTerminal {
            VSplitView {
                ChatView(sessionId: sessionId).id(sessionId)
                    .frame(minWidth: 440, idealWidth: 440, maxWidth: .infinity, minHeight: 280)
                MacTerminalPane(sessionId: sessionId)
                    .frame(minWidth: 440, idealWidth: 440, maxWidth: .infinity, minHeight: 140, idealHeight: 260)
            }
        } else {
            ChatView(sessionId: sessionId).id(sessionId)
        }
    }
}
