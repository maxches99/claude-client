import SwiftUI
import ClaudeCodeHost
import ClaudeRemoteDaemon

/// Edits `config.json`. Applying restarts the daemon (phone-hosted CLI sessions end; they can
/// be resumed from the phone — transcripts stay on disk).
struct SettingsWindow: View {
    let model: HostModel

    @State private var draft = DaemonConfig()
    @State private var portText = ""
    @State private var loaded = false
    @State private var hookInstalled = false
    @State private var hookError: String?
    @State private var codexPortText = ""
    @State private var codexEnv: String?
    @State private var codexEnvError: String?
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
                LabeledContent("APNs key (.p8)") {
                    HStack {
                        TextField("", text: optional($draft.apnsKeyPath), prompt: Text("~/Keys/AuthKey_ABC123.p8"))
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                        Button("Choose…") { chooseKey() }
                    }
                }
                TextField("Key ID", text: optional($draft.apnsKeyId), prompt: Text("ABC123DEFG"))
                TextField("Team ID", text: optional($draft.apnsTeamId), prompt: Text("1A2B3C4D5E"))
                TextField("App bundle id", text: optional($draft.apnsBundleId), prompt: Text("dev.maxches.ClaudeRemote"))
                Toggle("Sandbox gateway (builds from Xcode; off for TestFlight / App Store)", isOn: $draft.apnsSandbox)
            } header: {
                Text("Live Activity push")
            } footer: {
                Text("Keeps the phone's Live Activity / Dynamic Island updating while the app is in the background. Needs an APNs auth key from the Apple Developer portal (Keys → +, enable APNs). Without it the activity updates only while the app is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show phone sessions in Claude Desktop and the Codex app", isOn: $draft.mirrorToDesktopApps)
            } header: {
                Text("Desktop apps (experimental)")
            } footer: {
                Text("After each turn, a Claude session started on the phone is added to Claude Desktop's Code list — Desktop reads that list when it starts, so it shows up after Desktop's next launch — and a Codex thread is filed under its folder's project in the Codex app (a new project if the folder has none). Neither app offers a way to do this, so it writes their own state files: Codex's only while the Codex app is closed — otherwise when it quits. If Desktop opens a session the phone still runs, the phone's idle copy steps aside. Without this, use \"Started on the phone\" in the menu to open a session in Claude Desktop.")
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
                        Text(claude.installed ? claude.path : "not installed — Codex only").font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
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
                LabeledContent("Shared Codex app-server port") {
                    TextField("", text: $codexPortText, prompt: Text("off — e.g. 4141"))
                        .multilineTextAlignment(.trailing)
                        .onChange(of: codexPortText) { _, v in draft.codexPort = UInt16(v).flatMap { $0 > 0 ? $0 : nil } }
                }
                HStack {
                    Text(codexEnv.map { "Codex app is pointed at \($0)" } ?? "Codex app uses its own private app-server")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let port = draft.codexPort, codexEnv != CodexAppEnvironment.url(port: port) {
                        Button("Point the Codex app here") {
                            codexEnvError = CodexAppEnvironment.set(port: port)
                            codexEnv = CodexAppEnvironment.current()
                        }
                    }
                    if codexEnv != nil {
                        Button("Reset") {
                            codexEnvError = CodexAppEnvironment.clear()
                            codexEnv = CodexAppEnvironment.current()
                        }
                    }
                }
                if let codexEnvError { Text(codexEnvError).font(.caption).foregroundStyle(.red) }
                Text("With a port, the daemon runs `codex app-server --listen ws://127.0.0.1:<port>` and the Codex app can use the same server (launchd env `CODEX_APP_SERVER_WS_URL`; quit and reopen the Codex app after setting it). Sessions open in the app then show up on the phone live and can be prompted, approved and interrupted from there.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Config file") {
                    Text(DaemonConfig.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
        // The form scrolls; a fixed tall window pushed the Apply bar off a laptop screen.
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 720)
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
        hookInstalled = ClaudeHooks.isInstalled()
        codexPortText = draft.codexPort.map(String.init) ?? ""
        codexEnv = CodexAppEnvironment.current()
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func chooseClaude() {
        chooseBinary(named: "claude") { draft.claudePath = $0 }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick the APNs auth key (AuthKey_XXXXXXXXXX.p8)"
        if panel.runModal() == .OK, let url = panel.url {
            draft.apnsKeyPath = url.path
            // Apple names the file after the key id — save the typing.
            let name = url.deletingPathExtension().lastPathComponent
            if name.hasPrefix("AuthKey_"), (draft.apnsKeyId ?? "").isEmpty { draft.apnsKeyId = String(name.dropFirst("AuthKey_".count)) }
        }
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
