import SwiftUI
import ClaudeRemoteCore

/// One session in a window of its own, to keep two side by side. It follows the active host: a
/// session on another host waits behind a "Switch" button rather than showing stale state.
struct SessionWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUI.self) private var ui
    let ref: SessionWindowRef
    @State private var width: CGFloat = .infinity

    var body: some View {
        Group {
            if ref.macId == model.activeMacId {
                NavigationStack {
                    ChatWithTerminal(sessionId: ref.sessionId,
                                     showsTerminal: ui.showTerminal && model.summary(for: ref.sessionId)?.kind != .chat)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.system(size: 28)).foregroundStyle(CDS.textMuted)
                    Text("This session is on \(model.macName(ref.macId))")
                        .font(.title3.weight(.semibold)).foregroundStyle(CDS.textPrimary)
                    Text("The window shows sessions of the host the app is connected to.")
                        .font(CDS.body).foregroundStyle(CDS.textMuted)
                    Button("Switch to \(model.macName(ref.macId))") { model.switchTo(ref.macId) }
                        .buttonStyle(CDSButtonStyle(variant: .secondary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CDS.surface0)
            }
        }
        .tint(CDS.brand)
        .formStyle(.grouped)
        .background(GeometryReader { geo in Color.clear.preference(key: SessionWindowWidthKey.self, value: geo.size.width) })
        .onPreferenceChange(SessionWindowWidthKey.self) { width = $0 }
        // No sidebar here, so the panel fits from a narrower window.
        .environment(\.windowWidth, width + 300)
    }
}

private struct SessionWindowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
