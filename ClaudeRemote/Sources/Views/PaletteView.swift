import SwiftUI
import ClaudeRemoteCore

/// Everything you can launch in this project without remembering its name: the slash commands the
/// CLI advertises, the skills and sub-agents defined in `.claude/`, and your own saved prompts.
struct PaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    /// What is in the composer right now — offered as a new snippet.
    let draft: String
    let onPick: (String) -> Void

    @State private var search = ""
    @State private var savingSnippet = false
    @State private var snippetTitle = ""
    @State private var template: PromptTemplate?

    private var cwd: String? { model.summary(for: sessionId)?.cwd ?? model.states[sessionId]?.cwd }
    private var templates: [PromptTemplate] {
        let all = cwd.flatMap { model.templatesByCwd[$0] } ?? []
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) || $0.prompt.lowercased().contains(q) }
    }

    private var items: [PaletteItem] { model.palettes[sessionId] ?? [] }

    private func matches(_ item: PaletteItem) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return item.name.lowercased().contains(q) || (item.detail?.lowercased().contains(q) ?? false)
    }

    private var snippets: [PromptSnippet] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.snippets }
        return model.snippets.filter { $0.title.lowercased().contains(q) || $0.text.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !templates.isEmpty {
                    Section("Templates") {
                        ForEach(templates) { t in
                            Button { template = t } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(t.name).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                                        if !t.fields.isEmpty { Text("\(t.fields.count) field\(t.fields.count == 1 ? "" : "s")").font(CDS.caption).foregroundStyle(CDS.textMuted) }
                                    }
                                    Text(t.description ?? t.prompt).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(2)
                                }
                            }
                            .listRowBackground(CDS.surface0)
                        }
                    }
                }
                if !snippets.isEmpty {
                    Section("Saved prompts") {
                        ForEach(snippets) { snippet in
                            Button {
                                onPick(snippet.text)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.title).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                                    Text(snippet.text).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(2)
                                }
                            }
                            .listRowBackground(CDS.surface0)
                        }
                        .onDelete { offsets in
                            model.removeSnippets(Set(offsets.map { snippets[$0].id }))
                        }
                    }
                }
                ForEach(PaletteItem.Kind.allCases, id: \.self) { kind in
                    let group = items.filter { $0.kind == kind && matches($0) }
                    if !group.isEmpty {
                        Section(kind.label) {
                            ForEach(group) { item in row(item) }
                        }
                    }
                }
                if items.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Reading .claude on the Mac…").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    }
                    .listRowBackground(CDS.surface0)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .searchable(text: $search, prompt: "Commands, skills, agents")
            .navigationTitle("Launch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Save the draft as a prompt", systemImage: "bookmark") {
                            snippetTitle = AgentTask.title(fromPrompt: draft)
                            savingSnippet = true
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Reload from the Mac", systemImage: "arrow.clockwise") { model.requestPalette(sessionId) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Save this prompt", isPresented: $savingSnippet) {
                TextField("Name", text: $snippetTitle)
                Button("Save") {
                    let title = snippetTitle.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return }
                    model.addSnippet(PromptSnippet(title: title, text: draft))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It stays on the phone and shows up here for every session.")
            }
        }
        .onAppear {
            if items.isEmpty { model.requestPalette(sessionId) }
            if model.supportsAutomation, let cwd { model.requestTemplates(cwd: cwd) }
        }
        .sheet(item: $template) { t in
            TemplateForm(template: t) { filled in
                onPick(filled)
                dismiss()
            }
        }
    }

    private func row(_ item: PaletteItem) -> some View {
        Button {
            onPick(item.insert)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CDS.textMuted)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.kind == .agent ? item.name : "/\(item.name)")
                            .font(CDS.code).foregroundStyle(CDS.textPrimary).lineLimit(1)
                        if item.scope != .builtin {
                            CDSChip(text: item.scope.label)
                        }
                    }
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(CDS.surface0)
    }
}
