import SwiftUI
import ClaudeRemoteCore

/// A shell in the session's project under the chat, like the desktop app's terminal panel. One shell per
/// session: hiding the pane or switching sessions leaves it running on the host, and coming back
/// re-attaches to the same one.
struct MacTerminalPane: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUI.self) private var ui
    let sessionId: String
    /// Decided once when the pane appears: the session's running shell, or nil for a new one.
    @State private var existing: TerminalModel?
    @State private var ready = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal").font(.system(size: 11)).foregroundStyle(CDS.textMuted)
                Text(title).font(CDS.captionMedium).foregroundStyle(CDS.textSecondary).lineLimit(1)
                Spacer()
                Button { ui.showTerminal = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(CDS.textMuted)
                    .help("Hide the terminal (⌃`)")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(CDS.surface1)
            .overlay(alignment: .top) { Rectangle().fill(CDS.border).frame(height: 1) }
            if model.isConnected, ready {
                TerminalScreenView(existing: existing, sessionId: sessionId, embedded: true) { opened in
                    ui.paneTerminals[sessionId] = opened.id
                }
                .id(sessionId)
            } else if model.isConnected {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Not connected").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CDS.surface0)
        .task(id: sessionId) { await attach() }
    }

    private func attach() async {
        ready = false
        existing = nil
        if let id = ui.paneTerminals[sessionId] {
            model.requestTerminals()
            // The host's list of shells comes back in a moment; a shell that is gone means a new one.
            for _ in 0..<15 where !model.terminals.contains(where: { $0.id == id }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let info = model.terminals.first(where: { $0.id == id }) { existing = model.attachTerminal(info) }
        }
        ready = true
    }

    private var title: String {
        let project = model.summary(for: sessionId)?.projectName ?? ""
        return project.isEmpty ? "Terminal" : "Terminal — \(project)"
    }
}
