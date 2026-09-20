import SwiftUI
import CoreSpotlight
import ClaudeRemoteCore

/// The two halves of the app: work sessions in a project, and tool-less quick chats.
enum AppTab: Hashable {
    case sessions
    case chats
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        Group {
            if model.macs.isEmpty {
                PairingView()
            } else if sizeClass == .regular {
                // iPad / Mac: the session list is a sidebar and the chat fills the rest, like the desktop app.
                NavigationSplitView(columnVisibility: $columns) {
                    VStack(spacing: 0) {
                        Picker("", selection: $model.tab) {
                            Text("Sessions").tag(AppTab.sessions)
                            Text("Chats").tag(AppTab.chats)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, CDS.gutter).padding(.vertical, 8)
                        .background(CDS.surface0)
                        SessionListView(scope: model.tab == .chats ? .chats : .sessions)
                    }
                    .background(CDS.surface0)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
                } detail: {
                    // Rows in the sidebar push onto this stack; each tab keeps its own path.
                    NavigationStack(path: model.tab == .chats ? $model.chatPath : $model.sessionPath) {
                        detailPlaceholder
                            .navigationDestination(for: String.self) { ChatView(sessionId: $0) }
                    }
                    .id(model.tab)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $model.tab) {
                    NavigationStack(path: $model.sessionPath) {
                        SessionListView(scope: .sessions)
                            .navigationDestination(for: String.self) { ChatView(sessionId: $0) }
                    }
                    .tabItem { Label("Sessions", systemImage: "chevron.left.forwardslash.chevron.right") }
                    .tag(AppTab.sessions)

                    NavigationStack(path: $model.chatPath) {
                        SessionListView(scope: .chats)
                            .navigationDestination(for: String.self) { ChatView(sessionId: $0) }
                    }
                    .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                    .tag(AppTab.chats)
                }
            }
        }
        .tint(CDS.brand)
        .onChange(of: sizeClass) { old, new in
            // Going from split view to a phone layout leaves one path per tab; nothing to carry over.
            // The other way, the current chat is already on the tab's path and simply lands in the detail column.
            if old != new { columns = .all }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            // A session found in Spotlight.
            if let id = SpotlightIndex.sessionId(from: activity) { model.openDeepLink(sessionId: id) }
        }
        .onOpenURL { url in
            // ccremote://session/<id> — a Live Activity tap; go straight to that session.
            if url.host == "session", let id = url.pathComponents.dropFirst().first, !id.isEmpty {
                model.openDeepLink(sessionId: id)
                return
            }
            // ccremote://pair?host=…&port=…&token=…&name=… (the daemon's QR code / pair URL):
            // adds the Mac (or refreshes it if already paired) and switches to it.
            if let info = PairingInfo.parse(pairURL: url.absoluteString) { model.pair(info) }
        }
    }
}

extension RootView {
    /// What the detail column shows before a session is picked.
    fileprivate var detailPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: model.tab == .chats ? "bubble.left.and.bubble.right" : "asterisk")
                .font(.system(size: 30, weight: .medium)).foregroundStyle(CDS.textMuted)
            Text(model.tab == .chats ? "Pick a chat" : "Pick a session")
                .font(.title3.weight(.semibold)).foregroundStyle(CDS.textPrimary)
            Text(model.activeMac.map { "Connected to \($0.displayName)" } ?? "")
                .font(CDS.body).foregroundStyle(CDS.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CDS.surface0)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
    }
}

struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.connection.status
        if status != .connected {
            CDSBanner(kind: .warning, text: text(for: status), systemImage: "wifi.exclamationmark", showsProgress: status == .connecting)
        }
    }

    /// Name the Mac while connecting — with several paired, "Connecting…" alone doesn't say which.
    private func text(for status: HostConnection.Status) -> String {
        let cached = model.showingCachedSessions ? " · showing what was last seen" : ""
        if status == .connecting, let mac = model.activeMac { return "Connecting to \(mac.displayName)…" + cached }
        return status.label + cached
    }
}
