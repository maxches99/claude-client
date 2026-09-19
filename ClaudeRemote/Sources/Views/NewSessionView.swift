import SwiftUI
import ClaudeRemoteCore

struct NewSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Selected project path, `customTag` for a typed path, or "" until the project list arrives.
    @State private var cwd = ""
    @State private var customPath = ""
    private static let customTag = "custom"
    private var isCustom: Bool { cwd == Self.customTag }
    @State private var modelId = "claude-opus-5"
    @State private var mode: PermissionMode = .manual

    static let models: [(id: String, label: String)] = [
        ("claude-opus-5", "Opus 5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-haiku-4-5", "Haiku 4.5"),
    ]

    var body: some View {
        NavigationStack {
            Form {
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
                        model.create(NewSessionOptions(cwd: path, model: modelId, permissionMode: mode.rawValue))
                        dismiss()
                    }
                    .disabled(cwd.isEmpty || (isCustom && customPath.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .onAppear {
                // Default to the most recent project once; "Custom path…" must survive coming back from the picker.
                if cwd.isEmpty, let first = model.projects.first { cwd = first.path }
                if model.projects.isEmpty { model.refresh() }
            }
            .onChange(of: model.projects) { _, projects in
                if cwd.isEmpty, let first = projects.first { cwd = first.path }
            }
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
}
