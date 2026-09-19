import SwiftUI

/// App settings (currently Face ID). Present it from the session list's menu.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
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
                if let host = model.connection.host {
                    Section("Mac") {
                        LabeledContent("Host", value: host.hostName)
                        if let v = host.cliVersion { LabeledContent("claude", value: v) }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
