import SwiftUI
import ClaudeRemoteCore

/// Fan-out: one prompt to several Macs, projects, agents and models at once, the answers side by side.
/// The list of past runs (the last 20) and a "New" composer.
struct FanOutListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    private static let composeTag = "new"

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button { path.append(Self.composeTag) } label: {
                        Label("New fan-out", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(model.connectedMacCount == 0)
                } footer: {
                    Text("Send one prompt to several projects, agents and models — on any paired Mac — and compare the answers.")
                }
                if !model.fanOut.runs.isEmpty {
                    Section("Recent") {
                        ForEach(model.fanOut.runs) { run in
                            Button { path.append(run.id) } label: { row(run) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { model.fanOut.remove(run.id) }
                                }
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { model.fanOut.remove(run.id) }
                                }
                        }
                    }
                }
            }
            .groupedListStyle()
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Fan-out")
            .inlineNavigationTitle()
            .navigationBarBackground(CDS.surface0)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { id in
                if id == Self.composeTag {
                    FanOutComposer { runId in path = [runId] }
                } else {
                    FanOutRunView(runId: id) { dismiss() }
                }
            }
        }
    }

    private func row(_ run: FanOutRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.prompt).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(2)
            HStack(spacing: 6) {
                Text("\(run.targets.count) targets").font(CDS.caption).foregroundStyle(CDS.textMuted)
                Text(run.createdAt, style: .relative).font(CDS.caption).foregroundStyle(CDS.textMuted)
                Spacer(minLength: 0)
                ForEach(run.targets) { StatusDot(status: model.fanOutStatus($0), origin: .host, agent: $0.agent) }
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - composer

/// The prompt and the targets it goes to.
struct FanOutComposer: View {
    @Environment(AppModel.self) private var model
    /// Called with the new run's id once it is sent.
    let onStart: (String) -> Void
    @State private var prompt = ""
    @State private var targets: [FanOutTarget] = []
    @State private var claudeMode: PermissionMode = .manual
    // The target being added.
    @State private var macId = ""
    @State private var cwd = ""
    @State private var agent: AgentKind = .claude
    @State private var modelId = ""

    private var connectedMacs: [PairingInfo] {
        model.macs.filter { model.link(for: $0.id)?.status == .connected }
    }

    private var projects: [ProjectInfo] { model.fanOutProjects(macId) }

    var body: some View {
        Form {
            Section("Prompt") {
                TextField("Ask every target the same thing…", text: $prompt, axis: .vertical)
                    .lineLimit(4...12)
            }
            Section {
                if targets.isEmpty {
                    Text("No targets yet — add two or more below.").font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                ForEach(targets) { target in
                    HStack(spacing: 8) {
                        Circle().fill(target.agent.tint).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(target.projectName) · \(target.modelLabel)").font(CDS.body).foregroundStyle(CDS.textPrimary)
                            Text(model.macName(target.macId)).font(CDS.caption).foregroundStyle(CDS.textMuted)
                        }
                        Spacer(minLength: 0)
                        Button { targets.removeAll { $0.id == target.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(CDS.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove")
                    }
                }
                .onDelete { targets.remove(atOffsets: $0) }
            } header: {
                Text("Targets (\(targets.count))")
            }
            Section("Add a target") {
                Picker("Mac", selection: $macId) {
                    ForEach(connectedMacs) { Text($0.displayName).tag($0.id) }
                }
                Picker("Project", selection: $cwd) {
                    if projects.isEmpty { Text("Loading…").tag("") }
                    ForEach(projects) { p in Text("\(p.name)  (\(ToolSummary.shortPath(p.path)))").tag(p.path) }
                }
                .longListPickerStyle()
                if model.hasAgent(.claude, mac: macId), model.hasAgent(.codex, mac: macId) {
                    Picker("Agent", selection: $agent) {
                        ForEach(AgentKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Model", selection: $modelId) {
                    Text("Default").tag("")
                    if agent == .claude {
                        ForEach(NewSessionView.models, id: \.id) { Text($0.label).tag($0.id) }
                    } else if macId == model.activeMacId {
                        // Codex lists its models per Mac; only the active Mac's are known.
                        ForEach(model.codexModels) { Text($0.label).tag($0.id) }
                    }
                }
                Button("Add target", systemImage: "plus") {
                    targets.append(FanOutTarget(macId: macId, cwd: cwd, agent: agent, model: modelId.isEmpty ? nil : modelId))
                }
                .disabled(macId.isEmpty || cwd.isEmpty || isDuplicate)
            }
            if targets.contains(where: { $0.agent == .claude }) {
                Section {
                    Picker("Claude permissions", selection: $claudeMode) {
                        ForEach(PermissionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Every session asks for approval as usual (Codex: on request, sandboxed to the project). Approvals land in the inbox.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CDS.surface0)
        .navigationTitle("New fan-out")
        .inlineNavigationTitle()
        .navigationBarBackground(CDS.surface0)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    onStart(model.startFanOut(prompt: text, targets: targets, claudeMode: claudeMode))
                }
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targets.isEmpty)
            }
        }
        .onAppear {
            model.requestFanOutProjects()
            if macId.isEmpty { macId = model.activeMacId ?? connectedMacs.first?.id ?? "" }
            pickDefaults()
        }
        .onChange(of: macId) { _, _ in cwd = ""; pickDefaults() }
        .onChange(of: projects) { _, _ in pickDefaults() }
        .onChange(of: agent) { _, _ in modelId = "" }
    }

    private var isDuplicate: Bool {
        let wanted = modelId.isEmpty ? nil : modelId
        return targets.contains { $0.macId == macId && $0.cwd == cwd && $0.agent == agent && $0.model == wanted }
    }

    private func pickDefaults() {
        if cwd.isEmpty || !projects.contains(where: { $0.path == cwd }) { cwd = projects.first?.path ?? "" }
        if !model.hasAgent(agent, mac: macId) { agent = agent == .claude ? .codex : .claude }
    }
}

// MARK: - comparison

/// One column per target: its status and latest reply. Pages on a phone, side by side when there is room.
struct FanOutRunView: View {
    @Environment(AppModel.self) private var model
    let runId: String
    /// Closes the fan-out screens so the opened session shows.
    let close: () -> Void
    @State private var showPrompt = false

    private var run: FanOutRun? { model.fanOut.run(runId) }

    var body: some View {
        Group {
            if let run {
                VStack(alignment: .leading, spacing: 0) {
                    promptHeader(run)
                    columns(run)
                }
            } else {
                Text("This fan-out is gone.").font(CDS.body).foregroundStyle(CDS.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CDS.surface0)
        .navigationTitle("Fan-out")
        .inlineNavigationTitle()
        .navigationBarBackground(CDS.surface0)
        .onAppear { model.attachFanOut(runId) }
        // Sessions started after the screen opened, or Macs that came back.
        .onChange(of: run?.targets.compactMap(\.sessionId)) { _, _ in model.attachFanOut(runId) }
        .onChange(of: model.connectedMacCount) { _, _ in model.attachFanOut(runId) }
    }

    private func promptHeader(_ run: FanOutRun) -> some View {
        Button { showPrompt.toggle() } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(CDS.textMuted)
                Text(run.prompt).font(CDS.body).foregroundStyle(CDS.textPrimary)
                    .lineLimit(showPrompt ? nil : 2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(run.createdAt, style: .relative).font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            .padding(.horizontal, CDS.gutter).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func columns(_ run: FanOutRun) -> some View {
        GeometryReader { geo in
            let spacing: CGFloat = 12
            let count = CGFloat(max(run.targets.count, 1))
            let available = geo.size.width - CDS.gutter * 2
            // A phone pages through full-width columns; a wide window fits them side by side, scrolling past ~3.
            let width = geo.size.width < 600 ? available : max(320, (available - spacing * (count - 1)) / count)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(run.targets) { target in
                        FanOutColumn(target: target) {
                            close()
                            model.openFanOut(target)
                        }
                        .frame(width: width, height: max(200, geo.size.height - 12))
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, CDS.gutter)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// One target's status and latest assistant reply.
struct FanOutColumn: View {
    @Environment(AppModel.self) private var model
    let target: FanOutTarget
    let open: () -> Void

    private var status: SessionStatus { model.fanOutStatus(target) }
    private var reply: String { TranscriptExport.lastReply(items: model.fanOutTranscript(target)?.items ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CDS.border)
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider().overlay(CDS.border)
            HStack {
                if !reply.isEmpty {
                    Button { UIPasteboard.general.string = reply } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                Spacer()
                Button("Open", systemImage: "arrow.up.forward.square", action: open)
                    .disabled(target.sessionId == nil)
            }
            .font(CDS.caption)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(CDS.surface1, in: RoundedRectangle(cornerRadius: CDS.radius))
        .overlay(RoundedRectangle(cornerRadius: CDS.radius).stroke(CDS.border))
    }

    private var header: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusDot(status: status, origin: .host, agent: target.agent)
                    Text(target.projectName).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    CDSChip(text: target.modelLabel, style: .agent(target.agent.tint))
                }
                HStack(spacing: 6) {
                    Text(model.macName(target.macId)).lineLimit(1)
                    Text("·")
                    Text(statusLabel).foregroundStyle(statusColor)
                }
                .font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target.sessionId == nil)
    }

    @ViewBuilder private var content: some View {
        if let error = model.fanOutError(target) {
            Text(error).font(CDS.body).foregroundStyle(CDS.danger).textSelection(.enabled)
        }
        if !reply.isEmpty {
            MarkdownText(text: reply)
        } else if target.sessionId == nil, target.error == nil {
            placeholder("Starting the session…", spinning: true)
        } else if status == .running {
            placeholder("Working…", spinning: true)
        } else if status == .awaitingPermission {
            placeholder("Waiting for an approval — open the session or the inbox to answer.", spinning: false)
        } else if target.sessionId != nil, model.fanOutTranscript(target) == nil {
            placeholder(model.link(for: target.macId)?.status == .connected ? "Loading the reply…" : "\(model.macName(target.macId)) is not connected — open the session to read it.",
                        spinning: model.link(for: target.macId)?.status == .connected)
        } else if target.error == nil {
            placeholder("No reply yet.", spinning: false)
        }
    }

    private func placeholder(_ text: String, spinning: Bool) -> some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.small) }
            Text(text).font(CDS.caption).foregroundStyle(CDS.textMuted)
        }
    }

    private var statusLabel: String {
        if target.error != nil { return "Failed" }
        switch status {
        case .running: return target.sessionId == nil ? "Starting" : "Working"
        case .awaitingPermission: return "Needs approval"
        case .idle: return "Done"
        case .exited: return "Stopped"
        case .unknown: return "—"
        }
    }

    private var statusColor: Color {
        if target.error != nil { return CDS.danger }
        switch status {
        case .running: return target.agent.tint
        case .awaitingPermission: return CDS.warning
        case .exited: return CDS.danger
        default: return CDS.textMuted
        }
    }
}
