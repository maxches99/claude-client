import SwiftUI

/// App settings: Face ID and the paired Macs. Present it from the session list's menu.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showAddMac = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    ForEach(model.macs) { mac in
                        Button { model.switchTo(mac.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "desktopcomputer").foregroundStyle(CDS.textSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.displayName).foregroundStyle(CDS.textPrimary)
                                    Text(macDetail(mac)).font(.footnote).foregroundStyle(CDS.textMuted)
                                }
                                Spacer()
                                if mac.id == model.activeMacId {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ model.macs[$0].id }) { model.forget(id) }
                    }
                    Button { showAddMac = true } label: {
                        Label("Add Mac…", systemImage: "plus")
                    }
                    if model.macs.count > 1 {
                        Toggle("Stay connected to every Mac", isOn: Binding(get: { model.watchAllMacs }, set: { model.watchAllMacs = $0 }))
                        Toggle("One list across every Mac", isOn: Binding(get: { model.showAllMacs }, set: { model.showAllMacs = $0 }))
                            .disabled(!model.watchAllMacs)
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text(model.macs.count > 1
                         ? "Staying connected keeps every Mac's sessions and approvals arriving, so the inbox is complete wherever the agent is. A chat still opens on one Mac at a time — tapping a session on another one switches over. Swipe a Mac to forget it."
                         : "The app shows one Mac at a time — pick it here or from the title of the session list. Swipe a Mac to forget it.")
                }
                Section {
                    Toggle("Require Face ID to approve", isOn: $model.requireBiometricsForApproval)
                    Toggle("Lock app with Face ID", isOn: $model.lockAppWithBiometrics)
                } header: {
                    Text("Security")
                } footer: {
                    Text(Biometrics.isAvailable
                         ? "Approving a tool runs it on your Mac — Face ID adds a check before each Allow. App lock asks for Face ID when you reopen the app."
                         : "Face ID / passcode isn't set up on this device, so these checks are skipped.")
                }
                Section {
                    Toggle("Live Activity for busy sessions", isOn: $model.liveActivitiesEnabled)
                } header: {
                    Text("Lock screen & Dynamic Island")
                } footer: {
                    Text(liveActivityFooter)
                }
                if !model.shares.isEmpty {
                    Section {
                        NavigationLink {
                            SharedLinksView()
                        } label: {
                            LabeledContent("Shared links", value: "\(model.shares.filter { !$0.isExpired }.count) active")
                        }
                    } footer: {
                        Text("Links to transcripts this phone published. Revoking one deletes the page from the relay.")
                    }
                }
                if let host = model.connection.host {
                    Section("Connected Mac") {
                        LabeledContent("Host", value: host.hostName)
                        if let v = host.cliVersion { LabeledContent("claude", value: v) }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showAddMac) { PairingView() }
        }
    }

    private var liveActivityFooter: String {
        var text = "A working session shows what it's doing, with a turn timer; when it stops to ask, Allow and Deny are right there."
        if !LiveActivityController.isSupported {
            text += " Live Activities are off for this app in iOS Settings."
        } else if model.connection.host?.livePush == true {
            text += " The Mac pushes updates, so it keeps moving while the app is in the background."
        } else if model.connection.host != nil {
            text += " Updates arrive while the app is open; set an APNs key in the Mac app's Settings to keep them coming in the background."
        }
        return text
    }

    /// Routes plus when we last reached it: "192.168.1.40:7811 + relay · 2 hr. ago".
    private func macDetail(_ mac: PairingInfo) -> String {
        guard let at = mac.lastConnectedAt else { return mac.routeSummary }
        return "\(mac.routeSummary) · \(RelativeTime.string(at))"
    }
}
