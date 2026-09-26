import SwiftUI

/// Every permission an agent might need, with one button that asks for all of them now — so the Mac
/// does not sit on an alert while you are away with the phone.
struct PermissionsWindow: View {
    let permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions").font(.title2.weight(.semibold))
                Text("Agents you start from the phone run as ClaudeRemote Host, so macOS asks this app. An unanswered alert stops the agent until someone clicks it at the Mac — grant everything now while you're here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    permissions.grantAll()
                } label: {
                    Text(permissions.granting ? "Asking…" : "Grant all")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .disabled(permissions.granting || !permissions.needsAttention)
                if permissions.granting {
                    ProgressView().controlSize(.small)
                    Text("Answer each macOS alert as it comes up").font(.caption).foregroundStyle(.secondary)
                } else if !permissions.needsAttention {
                    Label("Nothing left to ask", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }
                Spacer()
                Button { permissions.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Check again (after changing something in System Settings)")
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(permissions.items) { item in
                        row(item)
                        if item.id != permissions.items.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            }

            Text("Updates get a new signature, and macOS may forget these after one — this window comes back when it does.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 520, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings.
            if !permissions.granting { permissions.refresh() }
        }
    }

    private func row(_ item: Permissions.Item) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout)
                Text(item.why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            badge(item.state)
            action(item)
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func badge(_ state: Permissions.State) -> some View {
        switch state {
        case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Granted")
        case .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Denied")
        case .notAsked: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("Not asked yet")
        case .notRunning: Image(systemName: "moon.circle").foregroundStyle(.secondary).help("The app isn't running — Ask starts it for a moment")
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help("macOS doesn't report this one")
        }
    }

    @ViewBuilder
    private func action(_ item: Permissions.Item) -> some View {
        switch item.state {
        case .granted:
            EmptyView()
        case .notAsked, .notRunning:
            if item.kind == .fullDisk {
                Button("Open Settings") { permissions.grant(item) }.controlSize(.small)
            } else {
                Button("Ask") { permissions.grant(item) }.controlSize(.small).disabled(permissions.granting)
            }
        case .denied, .unknown:
            Button("Open Settings") { permissions.grant(item) }.controlSize(.small)
        }
    }
}
