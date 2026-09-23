import SwiftUI
import ClaudeRemoteCore

/// Brings a repository onto the host — the VPS hub has none of its own — so tasks and sessions can
/// run in it. Your GitHub repositories when `gh` is logged in there, or any URL.
struct CloneRepositoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called with the path once cloned (the task editor selects it).
    var onCloned: ((String) -> Void)?
    @State private var source = ""
    @State private var search = ""

    private var repositories: [RemoteRepository] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.remoteRepositories }
        return model.remoteRepositories.filter { $0.nameWithOwner.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("owner/name or a git URL", text: $source)
                            .font(CDS.code)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { model.cloneRepository(source) }
                        Button { model.cloneRepository(source) } label: {
                            if model.cloning == source.trimmingCharacters(in: .whitespaces), !source.isEmpty { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.down.circle.fill") }
                        }
                        .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || model.cloning != nil)
                    }
                    .listRowBackground(CDS.surface0)
                } footer: {
                    Text("Clones into \((model.host?.workspaceRoot as NSString?)?.abbreviatingWithTildeInPath ?? "~/work") on \(model.activeMac?.displayName ?? "the Mac"). Private repositories need git or gh to be logged in there.")
                }
                if let message = model.cloneMessage {
                    Section {
                        Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(CDS.caption).foregroundStyle(message.isError ? CDS.danger : CDS.success)
                            .listRowBackground(CDS.surface0)
                    }
                }
                if model.host?.hasGitHubCLI == true {
                    Section("Your repositories on GitHub") {
                        if model.remoteRepositoriesLoading && model.remoteRepositories.isEmpty {
                            ProgressView().listRowBackground(CDS.surface0)
                        }
                        if let error = model.remoteRepositoriesError {
                            Text(error).font(CDS.caption).foregroundStyle(CDS.danger).listRowBackground(CDS.surface0)
                        }
                        ForEach(repositories) { repo in row(repo) }
                    }
                } else {
                    Section {
                        Text("Install GitHub's `gh` on the host and log in to pick from your repositories here.")
                            .font(CDS.caption).foregroundStyle(CDS.textMuted).listRowBackground(CDS.surface0)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .searchable(text: $search, prompt: "Filter")
            .navigationTitle("Clone a repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onChange(of: model.cloneMessage) { _, message in
                // Hand a fresh clone straight back to whoever asked for it.
                guard let message, !message.isError, let path = model.projects.first(where: { $0.name == lastCloned })?.path else { return }
                onCloned?(path)
            }
            .onChange(of: model.projects) { _, projects in
                if let name = lastCloned, let path = projects.first(where: { $0.name == name })?.path { onCloned?(path) }
            }
        }
        .onAppear { if model.host?.hasGitHubCLI == true, model.remoteRepositories.isEmpty { model.requestRemoteRepositories() } }
    }

    /// The folder name the last clone went to.
    private var lastCloned: String? {
        let s = source.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var last = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? s
        if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
        return last
    }

    private func row(_ repo: RemoteRepository) -> some View {
        Button {
            source = repo.nameWithOwner
            model.cloneRepository(repo.nameWithOwner)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(repo.nameWithOwner).font(CDS.body).foregroundStyle(CDS.textPrimary).lineLimit(1)
                        if repo.isPrivate { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(CDS.textMuted) }
                    }
                    if let description = repo.description { Text(description).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(2) }
                }
                Spacer(minLength: 0)
                if model.cloning == repo.nameWithOwner {
                    ProgressView().controlSize(.small)
                } else if repo.localPath != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CDS.success)
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(CDS.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.cloning != nil || repo.localPath != nil)
        .listRowBackground(CDS.surface0)
    }
}
