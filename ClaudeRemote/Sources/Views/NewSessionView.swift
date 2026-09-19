import SwiftUI
import ClaudeRemoteCore

struct NewSessionView: View {
    /// When set (e.g. the "+" on a project group), preselects that project's path.
    var initialCwd: String? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Selected project path, `customTag` for a typed path, or "" until the project list arrives.
    @State private var cwd = ""
    @State private var customPath = ""
    private static let customTag = "custom"
    private var isCustom: Bool { cwd == Self.customTag }
    @State private var agent: AgentKind = .claude
    @State private var modelId = "claude-opus-5"
    @State private var mode: PermissionMode = .manual
    // Codex knobs
    @State private var codexModelId = ""
    @State private var codexEffort = ""
    @State private var approvalPolicy: CodexApprovalPolicy = .onRequest
    @State private var sandbox: CodexSandboxMode = .workspaceWrite

    static let models: [(id: String, label: String)] = [
        ("claude-opus-5", "Opus 5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-haiku-4-5", "Haiku 4.5"),
    ]

    private var codexModel: ModelOption? { model.codexModels.first { $0.id == codexModelId } }

    var body: some View {
        NavigationStack {
            Form {
                if model.hasCodex {
                    Section {
                        Picker("Agent", selection: $agent) {
                            ForEach(AgentKind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Project") {
                    Picker("Recent", selection: $cwd) {
                        Text("Custom path…").tag(Self.customTag)
                        ForEach(model.projects) { p in
                            Text("\(p.name)  (\(ToolSummary.shortPath(p.path)))").tag(p.path)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if isCustom {
                        TextField("/Users/you/project", text: $customPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                if agent == .codex { codexSections } else { claudeSections }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let path = isCustom ? customPath.trimmingCharacters(in: .whitespaces) : cwd
                        model.create(options(cwd: path))
                        dismiss()
                    }
                    .disabled(cwd.isEmpty || (isCustom && customPath.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .onAppear {
                // Default to the most recent project once; "Custom path…" must survive coming back from the picker.
                if cwd.isEmpty, let initialCwd, !initialCwd.isEmpty { cwd = initialCwd }
                if cwd.isEmpty, let first = model.projects.first { cwd = first.path }
                if model.projects.isEmpty { model.refresh() }
                if model.hasCodex, model.codexModels.isEmpty { model.requestCodexModels() }
                pickCodexDefaults(model.codexModels)
            }
            .onChange(of: model.projects) { _, projects in
                if cwd.isEmpty, let first = projects.first { cwd = first.path }
            }
            .onChange(of: model.codexModels) { _, models in pickCodexDefaults(models) }
            .onChange(of: codexModelId) { _, _ in
                // Efforts differ per model; keep the choice if the new model has it, else its default.
                if let m = codexModel, !m.efforts.contains(codexEffort) { codexEffort = m.defaultEffort ?? m.efforts.first ?? "" }
            }
        }
    }

    private func options(cwd: String) -> NewSessionOptions {
        switch agent {
        case .claude:
            return NewSessionOptions(cwd: cwd, model: modelId, permissionMode: mode.rawValue)
        case .codex:
            return NewSessionOptions(cwd: cwd, model: codexModelId.isEmpty ? nil : codexModelId, permissionMode: approvalPolicy.rawValue,
                                     effort: codexEffort.isEmpty ? nil : codexEffort, agent: .codex, sandbox: sandbox.rawValue)
        }
    }

    private func pickCodexDefaults(_ models: [ModelOption]) {
        guard codexModelId.isEmpty, let m = models.first(where: { $0.isDefault }) ?? models.first else { return }
        codexModelId = m.id
        codexEffort = m.defaultEffort ?? m.efforts.first ?? ""
    }

    // MARK: Claude

    @ViewBuilder
    private var claudeSections: some View {
        Section("Model") {
            Picker("Model", selection: $modelId) {
                ForEach(NewSessionView.models, id: \.id) { m in Text(m.label).tag(m.id) }
            }
            .pickerStyle(.segmented)
        }
        Section("Permissions") {
            Picker("Mode", selection: $mode) {
                ForEach(PermissionMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
            }
            Text(modeHint).font(.footnote).foregroundStyle(CDS.textSecondary)
        }
    }

    private var modeHint: String {
        switch mode {
        case .manual: return "Every tool that needs permission shows up here for approval."
        case .acceptEdits: return "File edits run without asking; commands still ask."
        case .plan: return "Read-only exploration and planning."
        case .auto: return "A classifier approves routine actions; the rest come to you."
        case .dontAsk: return "Anything that would prompt is denied automatically."
        case .bypassPermissions: return "No prompts at all. Only for sandboxes."
        }
    }

    // MARK: Codex

    @ViewBuilder
    private var codexSections: some View {
        Section("Model") {
            if model.codexModels.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking the Mac for models…").font(.footnote).foregroundStyle(CDS.textSecondary)
                }
            } else {
                Picker("Model", selection: $codexModelId) {
                    ForEach(model.codexModels) { m in Text(m.label).tag(m.id) }
                }
                if let m = codexModel, !m.efforts.isEmpty {
                    Picker("Reasoning", selection: $codexEffort) {
                        ForEach(m.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                if let description = codexModel?.description, !description.isEmpty {
                    Text(description).font(.footnote).foregroundStyle(CDS.textSecondary)
                }
            }
        }
        Section("Approvals") {
            Picker("Ask", selection: $approvalPolicy) {
                ForEach(CodexApprovalPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text(approvalPolicy.hint).font(.footnote).foregroundStyle(CDS.textSecondary)
        }
        Section("Sandbox") {
            Picker("Access", selection: $sandbox) {
                ForEach(CodexSandboxMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text(sandbox.hint).font(.footnote).foregroundStyle(CDS.textSecondary)
        }
    }
}

extension CodexSandboxMode {
    var hint: String {
        switch self {
        case .workspaceWrite: return "Commands may write inside the project; anything else asks."
        case .readOnly: return "Commands can only read. Writes ask first."
        case .dangerFullAccess: return "No sandbox at all. Only for throwaway machines."
        }
    }

    var symbol: String {
        switch self {
        case .workspaceWrite: return "folder"
        case .readOnly: return "eye"
        case .dangerFullAccess: return "shield.slash"
        }
    }
}

extension CodexApprovalPolicy {
    var shortLabel: String {
        switch self {
        case .onRequest: return "On request"
        case .untrusted: return "Untrusted"
        case .never: return "Never ask"
        }
    }

    var symbol: String {
        switch self {
        case .onRequest: return "hand.raised"
        case .untrusted: return "exclamationmark.shield"
        case .never: return "bell.slash"
        }
    }
}
