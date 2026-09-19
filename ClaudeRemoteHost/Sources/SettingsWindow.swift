import SwiftUI
import ClaudeRemoteDaemon

/// Edits `config.json`. Applying restarts the daemon (phone-hosted CLI sessions end; they can
/// be resumed from the phone — transcripts stay on disk).
struct SettingsWindow: View {
    let model: HostModel

    @State private var draft = DaemonConfig()
    @State private var portText = ""
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    private var isDirty: Bool { draft != model.config }

    var body: some View {
        Form {
            Section("This Mac") {
                TextField("Name", text: Binding(
                    get: { draft.serviceName ?? "" },
                    set: { draft.serviceName = $0.isEmpty ? nil : $0 }),
                          prompt: Text(Host.current().localizedName ?? "Mac"))
                TextField("Port", text: $portText, prompt: Text("7811"))
                    .onChange(of: portText) { _, v in
                        if let p = UInt16(v), p > 0 { draft.port = p } else if v.isEmpty { draft.port = 7811 }
                    }
                Toggle("Encrypt the connection (wss, self-signed cert pinned by the phone)", isOn: $draft.useTLS)
            }

            Section {
                TextField("Relay URL", text: optional($draft.relayURL), prompt: Text("wss://relay.example.com"))
                SecureField("Relay secret", text: optional($draft.relaySecret))
                LabeledContent("Relay cert fingerprint") {
                    TextField("", text: optional($draft.relayFingerprint), prompt: Text("optional — sha256 hex"))
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
                if let room = model.status?.pairing.room {
                    LabeledContent("Room") { Text(room).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                }
            } header: {
                Text("Remote access")
            } footer: {
                Text("Lets the phone reach this Mac when it is not on the same Wi‑Fi. Run the relay from `relay/` on a server you control; the pairing token still protects the daemon end-to-end. A mesh VPN (Tailscale/WireGuard) works without a relay — just pair by the VPN address.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("ntfy topic or URL", text: optional($draft.ntfy), prompt: Text("my-mac-a1b2c3  (ntfy.sh) or https://ntfy.example.com/topic"))
                SecureField("Telegram bot token", text: optional($draft.telegramToken))
                TextField("Telegram chat id", text: optional($draft.telegramChat))
                Toggle("Also notify when a turn completes", isOn: $draft.notifyDone)
            } header: {
                Text("Phone notifications")
            } footer: {
                Text("Permission requests and errors always notify when a channel is set.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("claude binary") {
                    HStack {
                        TextField("", text: optional($draft.claudePath), prompt: Text("auto — Claude Desktop's bundled CLI, else PATH"))
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                        Button("Choose…") { chooseClaude() }
                    }
                }
                if let claude = model.status?.claude {
                    LabeledContent("Using") {
                        Text(claude.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    }
                }
                LabeledContent("codex binary") {
                    HStack {
                        TextField("", text: optional($draft.codexPath), prompt: Text("auto — PATH, else the Codex app's bundled CLI"))
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                        Button("Choose…") { chooseBinary(named: "codex") { draft.codexPath = $0 } }
                    }
                }
                if let codex = model.status?.codex {
                    LabeledContent("Using") {
                        Text(codex.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    }
                }
                LabeledContent("Config file") {
                    Text(DaemonConfig.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 700)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(isDirty ? "Applying restarts the host; sessions started from the phone stop (they can be resumed)." : " ")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { load() }.disabled(!isDirty)
                Button("Apply & Restart") {
                    model.apply(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isDirty || (draft.relayEnabled && (draft.relaySecret ?? "").isEmpty))
            }
            .padding(12)
            .background(.bar)
        }
        .onAppear { if !loaded { load(); loaded = true } }
    }

    private func load() {
        draft = model.config
        portText = draft.port == 7811 ? "" : String(draft.port)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func chooseClaude() {
        chooseBinary(named: "claude") { draft.claudePath = $0 }
    }

    private func chooseBinary(named name: String, _ set: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Pick the \(name) executable"
        if panel.runModal() == .OK, let url = panel.url { set(url.path) }
    }
}

/// The recent daemon log, live.
struct LogWindow: View {
    let model: HostModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.recentLog.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.recentLog.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
                .onAppear {
                    if !model.recentLog.isEmpty { proxy.scrollTo(model.recentLog.count - 1, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text(FileLog.defaultPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Open in Console") { model.openLog() }.controlSize(.small)
            }
            .padding(8)
        }
        .frame(minWidth: 520, minHeight: 300)
    }
}
