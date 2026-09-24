import SwiftUI
import ClaudeRemoteCore

// MARK: - Issues

/// Open issues of the project's GitHub repository; picking one starts the task from it.
struct IssuePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let cwd: String
    let onPick: (GitHubIssue) -> Void
    @State private var query = ""

    private var list: IssueList? { model.issuesByCwd[cwd] }
    private var shown: [GitHubIssue] {
        let items = list?.items ?? []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(q) || "#\($0.number)".contains(q) || $0.labels.contains { $0.lowercased().contains(q) } }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = list?.error {
                    Text(error).font(CDS.caption).foregroundStyle(CDS.danger).listRowBackground(CDS.surface0)
                } else if list?.loading ?? true, shown.isEmpty {
                    HStack { ProgressView(); Text("Asking GitHub…").foregroundStyle(CDS.textMuted) }.listRowBackground(CDS.surface0)
                } else if shown.isEmpty {
                    Text("No open issues.").foregroundStyle(CDS.textMuted).listRowBackground(CDS.surface0)
                }
                ForEach(shown) { issue in
                    Button {
                        onPick(issue)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("#\(issue.number)").font(CDS.caption.monospacedDigit()).foregroundStyle(CDS.textMuted)
                                Text(issue.title).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).multilineTextAlignment(.leading)
                            }
                            if !issue.labels.isEmpty || issue.author != nil {
                                HStack(spacing: 6) {
                                    ForEach(issue.labels.prefix(3), id: \.self) { CDSChip(text: $0, style: .neutral) }
                                    if let author = issue.author { Text(author).font(CDS.caption).foregroundStyle(CDS.textMuted) }
                                }
                            }
                        }
                    }
                    .listRowBackground(CDS.surface0)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .searchable(text: $query, prompt: "Filter issues")
            .navigationTitle("Issues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .refreshable { model.requestIssues(cwd: cwd) }
        }
        .onAppear { model.requestIssues(cwd: cwd) }
    }
}

// MARK: - Templates

/// Asks for each `{field}` of a template, shows the prompt it makes, and hands it back.
struct TemplateForm: View {
    @Environment(\.dismiss) private var dismiss
    let template: PromptTemplate
    let onUse: (String) -> Void
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                if let description = template.description {
                    Section { Text(description).font(CDS.caption).foregroundStyle(CDS.textSecondary) }
                }
                if !template.fields.isEmpty {
                    Section("Fill in") {
                        ForEach(template.fields, id: \.self) { field in
                            TextField(field.capitalized, text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 }), axis: .vertical)
                        }
                    }
                }
                Section("Prompt") {
                    Text(template.filled(values)).font(CDS.prose).foregroundStyle(CDS.textSecondary).textSelection(.enabled)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle(template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        onUse(template.filled(values))
                        dismiss()
                    }
                    .disabled(template.fields.contains { (values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
    }
}

// MARK: - Audit

/// What agents did on the Mac: every command, write, fetch and tool call in a window, the unusual
/// ones marked — outside the project, sudo, deletes, the network, secrets.
struct AuditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var range = Range.day
    @State private var flaggedOnly = true
    @State private var kinds: Set<AuditEvent.Kind> = [.command, .write, .delete, .fetch, .tool]

    enum Range: String, CaseIterable, Identifiable {
        case hour, day, week
        var id: String { rawValue }
        var label: String { self == .hour ? "Hour" : (self == .day ? "Day" : "Week") }
        var since: Date { Date().addingTimeInterval(self == .hour ? -3600 : (self == .day ? -86_400 : -7 * 86_400)) }
    }

    private var events: [AuditEvent] {
        (model.auditReport?.events ?? []).filter { (!flaggedOnly || $0.isFlagged) && kinds.contains($0.kind) }
    }

    private var grouped: [(day: Date, items: [AuditEvent])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: events) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Range", selection: $range) { ForEach(Range.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                    Toggle("Only what stands out", isOn: $flaggedOnly).tint(CDS.brand)
                } footer: {
                    let all = model.auditReport?.events ?? []
                    Text("\(all.count) actions, \(all.filter(\.isFlagged).count) marked — commands outside the project, sudo, deletes, the network, secrets, CI files.")
                }
                .listRowBackground(CDS.surface0)
                if model.auditLoading && model.auditReport == nil {
                    HStack { ProgressView(); Text("Reading transcripts on the Mac…").foregroundStyle(CDS.textMuted) }.listRowBackground(CDS.surface0)
                } else if events.isEmpty {
                    Text(flaggedOnly ? "Nothing unusual." : "Nothing happened.").foregroundStyle(CDS.textMuted).listRowBackground(CDS.surface0)
                }
                ForEach(grouped, id: \.day) { group in
                    Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(group.items) { event in row(event) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Audit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach([AuditEvent.Kind.command, .write, .delete, .fetch, .tool], id: \.self) { kind in
                            Toggle(isOn: Binding(get: { kinds.contains(kind) }, set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } })) {
                                Label(kind.rawValue.capitalized, systemImage: kind.systemImage)
                            }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
            }
            .refreshable { model.requestAudit(since: range.since) }
        }
        .onAppear { model.requestAudit(since: range.since) }
        .onChange(of: range) { _, new in model.requestAudit(since: new.since) }
    }

    private func row(_ event: AuditEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: event.kind.systemImage).font(.caption).foregroundStyle(event.isFlagged ? CDS.warning : CDS.textMuted).frame(width: 16)
                Text(event.detail).font(CDS.codeSmall).foregroundStyle(CDS.textPrimary).lineLimit(3)
            }
            if event.isFlagged {
                HStack(spacing: 4) { ForEach(event.flags, id: \.self) { CDSChip(text: $0, style: .warning) } }
            }
            HStack(spacing: 5) {
                Text(event.date, style: .time)
                Text("·")
                Text(event.agent.label).foregroundStyle(event.agent.tint)
                Text("·")
                Text(event.sessionTitle).lineLimit(1)
            }
            .font(CDS.caption).foregroundStyle(CDS.textMuted)
        }
        .padding(.vertical, 2)
        .listRowBackground(CDS.surface0)
        .contentShape(Rectangle())
        .onTapGesture {
            model.present(event.sessionId, kind: .agent)
            dismiss()
        }
    }
}

// MARK: - Host settings: relay, update, GitHub

/// Per-Mac rows in Settings: the relay it is on (or joining one), its version and update, and its GitHub login.
struct HostControlRows: View {
    @Environment(AppModel.self) private var model
    let macId: String
    @State private var showRelay = false
    @State private var showGitHub = false

    private var host: HostInfo? { model.hostByMac[macId] }

    var body: some View {
        if model.supportsAutomation(mac: macId), let host {
            LabeledContent("Relay") {
                if host.relay != nil {
                    Text("on").foregroundStyle(CDS.success)
                } else {
                    Button("Join a relay…") { showRelay = true }
                }
            }
            .sheet(isPresented: $showRelay) { RelayJoinView(macId: macId) }
            updateRow(host)
            Button {
                showGitHub = true
            } label: {
                LabeledContent("GitHub") {
                    let panel = model.githubByMac[macId]
                    Text(panel?.account?.login.map { "@\($0)" } ?? (panel?.account == nil ? "…" : "not connected"))
                }
            }
            .sheet(isPresented: $showGitHub) { GitHubHostView(macId: macId) }
            .onAppear {
                if model.githubByMac[macId] == nil { model.requestGitHub(mac: macId) }
                if model.supportsOperations(mac: macId), model.healthByMac[macId] == nil { model.requestHealth(mac: macId) }
                if model.hostUpdates[macId] == nil, host.canUpdate == true { model.checkHostUpdate(mac: macId) }
            }
            if model.supportsOperations(mac: macId) {
                NavigationLink {
                    HealthView(macId: macId)
                } label: {
                    LabeledContent("Health") {
                        let warnings = model.healthByMac[macId]?.warnings ?? []
                        Text(model.healthByMac[macId] == nil ? "…" : (warnings.isEmpty ? "fine" : "\(warnings.count) warning\(warnings.count == 1 ? "" : "s")"))
                            .foregroundStyle(warnings.isEmpty ? CDS.textSecondary : CDS.warning)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func updateRow(_ host: HostInfo) -> some View {
        let update = model.hostUpdates[macId]
        LabeledContent("Version") {
            HStack(spacing: 8) {
                Text(host.appVersion ?? host.daemonVersion)
                switch update?.state {
                case .available?:
                    Button("Update to \(update?.latest ?? "new")") { model.updateHost(mac: macId) }
                        .buttonStyle(CDSButtonStyle(variant: .primary))
                case .updating?:
                    ProgressView().controlSize(.small)
                case .upToDate?:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CDS.success)
                default:
                    if host.canUpdate == true {
                        Button("Check") { model.checkHostUpdate(mac: macId) }
                    }
                }
            }
        }
        if let update, let message = update.message, update.state == .updating || update.state == .failed || update.state == .unsupported {
            Text(message).font(CDS.caption).foregroundStyle(update.state == .failed ? CDS.danger : CDS.textMuted)
        }
    }
}

/// Puts a Mac on the relay: from a relay setup QR (shown in another Mac's Host settings), or copied
/// from another paired Mac that is already on it.
struct RelayJoinView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let macId: String
    @State private var scanning = false

    private var join: RelayJoin? { model.relayJoins[macId] }
    private var donors: [PairingInfo] {
        model.macs.filter { $0.id != macId && model.hostByMac[$0.id]?.relay != nil && model.supportsAutomation(mac: $0.id) }
    }
    private var name: String { model.macs.first { $0.id == macId }?.displayName ?? "this Mac" }

    var body: some View {
        NavigationStack {
            Form {
                if let join {
                    Section {
                        switch join.state {
                        case .sending, .restarting:
                            HStack { ProgressView(); Text(join.state == .sending ? "Sending…" : "\(name) is restarting onto the relay…") }
                        case .joined:
                            Label("\(name) is on the relay — it now works away from home too.", systemImage: "checkmark.circle.fill").foregroundStyle(CDS.success)
                        case .failed:
                            Label(join.message ?? "It did not work.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(CDS.danger)
                        }
                    }
                }
                Section {
                    Button("Scan a relay setup QR", systemImage: "qrcode.viewfinder") { scanning = true }
                } footer: {
                    Text("On a Mac that is already on the relay: Host app → Settings → Remote access → Relay setup QR.")
                }
                if !donors.isEmpty {
                    Section("Or use the relay of") {
                        ForEach(donors) { donor in
                            let fetch = model.relaySetups[donor.id]
                            Button {
                                model.requestRelaySetup(from: donor.id)
                            } label: {
                                HStack {
                                    Text(donor.displayName)
                                    Spacer()
                                    if fetch?.loading == true { ProgressView().controlSize(.small) }
                                    if let error = fetch?.error { Text(error).font(CDS.caption).foregroundStyle(CDS.danger) }
                                }
                            }
                            .onChange(of: fetch?.setup) { _, setup in
                                if let setup { model.joinRelay(setup, mac: macId) }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Join a relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $scanning) {
                QRScannerView(accept: { RelaySetup.parse($0) != nil }, onScan: { payload in
                    scanning = false
                    if let setup = RelaySetup.parse(payload) { model.joinRelay(setup, mac: macId) }
                }, hint: "Point the camera at the relay setup QR", rejectedHint: "That's not a relay setup code")
            }
        }
    }
}

/// The host's GitHub login (device code typed on github.com by you) and its git author.
struct GitHubHostView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let macId: String
    @State private var name = ""
    @State private var email = ""
    @State private var copied = false

    private var panel: GitHubPanel? { model.githubByMac[macId] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let account = panel?.account {
                        if !account.ghInstalled {
                            Text("GitHub CLI (gh) is not installed on this host.").foregroundStyle(CDS.danger)
                        } else if let login = account.login {
                            Label("Connected as @\(login)", systemImage: "checkmark.circle.fill").foregroundStyle(CDS.success)
                        } else {
                            loginFlow
                        }
                    } else {
                        ProgressView()
                    }
                    if let error = panel?.error { Text(error).font(CDS.caption).foregroundStyle(CDS.danger) }
                } header: { Text("GitHub") } footer: {
                    Text("Lets this host list your repositories and issues, push branches and open pull requests — the hub then works from GitHub alone.")
                }
                Section {
                    TextField("Name", text: $name).textContentType(.name)
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    Button("Save") { model.setGitIdentity(name: name, email: email, mac: macId) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !email.contains("@"))
                } header: { Text("Commits are signed as") } footer: {
                    Text("git's user.name and user.email on the host.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            model.requestGitHub(mac: macId)
            fillIdentity()
        }
        .onChange(of: panel?.account) { _, _ in fillIdentity() }
    }

    private func fillIdentity() {
        if name.isEmpty { name = panel?.account?.gitName ?? "" }
        if email.isEmpty { email = panel?.account?.gitEmail ?? "" }
    }

    @ViewBuilder
    private var loginFlow: some View {
        switch panel?.login?.status {
        case .starting?:
            HStack { ProgressView(); Text("Asking GitHub for a code…") }
        case .waiting?:
            if let code = panel?.login?.code {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Open github.com/login/device and enter:").font(CDS.caption).foregroundStyle(CDS.textSecondary)
                    Text(code).font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    HStack {
                        Button(copied ? "Copied" : "Copy code") { UIPasteboard.general.string = code; copied = true }
                            .buttonStyle(CDSButtonStyle(variant: .secondary))
                        Button("Open GitHub") { openURL(URL(string: panel?.login?.url ?? "https://github.com/login/device")!) }
                            .buttonStyle(CDSButtonStyle(variant: .primary))
                    }
                    HStack { ProgressView().controlSize(.small); Text("Waiting for you to approve…").font(CDS.caption).foregroundStyle(CDS.textMuted) }
                    Button("Cancel", role: .destructive) { model.cancelGitHubLogin(mac: macId) }.font(CDS.caption)
                }
            }
        case .failed?:
            Text(panel?.login?.message ?? "The login did not finish.").foregroundStyle(CDS.danger)
            Button("Try again") { model.startGitHubLogin(mac: macId) }
        default:
            Button("Connect GitHub", systemImage: "link") { model.startGitHubLogin(mac: macId) }
        }
    }
}
