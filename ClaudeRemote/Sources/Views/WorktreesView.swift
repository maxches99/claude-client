import SwiftUI
import ClaudeRemoteCore

/// The repo's worktrees — extra checkouts next to it, each on its own branch. Starting a session in
/// one means two agents can work at the same time without editing the same files.
struct WorktreesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    @State private var showNew = false
    @State private var name = ""
    @State private var branch = ""
    @State private var base = ""
    @State private var confirmRemove: Worktree?
    @State private var startIn: Worktree?

    private var items: [Worktree] { model.worktrees[sessionId] ?? [] }
    private var error: String? { model.worktreeErrors[sessionId] }
    private var branches: [String] { model.gitStatuses[sessionId]?.branches ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    CDSBanner(kind: .danger, text: error, systemImage: "exclamationmark.triangle.fill")
                        .listRowBackground(CDS.surface0)
                }
                Section {
                    ForEach(items) { worktree in row(worktree) }
                    if items.isEmpty && error == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("Reading the repo…").font(CDS.caption).foregroundStyle(CDS.textMuted)
                        }
                        .listRowBackground(CDS.surface0)
                    }
                } footer: {
                    Text("A worktree is a second checkout of the same repository, on its own branch. Removing one deletes its directory — commit or push anything you want to keep first.")
                        .font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Worktrees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.worktreeBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Menu {
                            Button("New worktree…", systemImage: "plus") { name = ""; branch = ""; base = ""; showNew = true }
                            Button("Refresh", systemImage: "arrow.clockwise") { model.requestWorktrees(sessionId) }
                            Button("Prune missing", systemImage: "scissors") { model.worktreeAction(sessionId, .prune) }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(CDS.textSecondary)
                        }
                    }
                }
            }
            .alert("New worktree", isPresented: $showNew) {
                TextField("Name (folder suffix)", text: $name)
                TextField("Branch (defaults to the name)", text: $branch)
                TextField("From (defaults to HEAD)", text: $base)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    let wanted = branch.trimmingCharacters(in: .whitespaces)
                    model.worktreeAction(sessionId, .add(name: trimmed, branch: wanted.isEmpty ? trimmed : wanted,
                                                         base: base.trimmingCharacters(in: .whitespaces).isEmpty ? nil : base))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It lands next to the repository as <repo>-<name>.")
            }
            .confirmationDialog("Remove this worktree?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let worktree = confirmRemove { model.worktreeAction(sessionId, .remove(path: worktree.path, force: false)) }
                    confirmRemove = nil
                }
                Button("Remove, discarding changes", role: .destructive) {
                    if let worktree = confirmRemove { model.worktreeAction(sessionId, .remove(path: worktree.path, force: true)) }
                    confirmRemove = nil
                }
            } message: {
                Text(confirmRemove?.path ?? "")
            }
            .sheet(item: $startIn) { worktree in
                NewSessionView(initialCwd: worktree.path)
            }
        }
        .onAppear {
            model.requestWorktrees(sessionId)
            if model.gitStatuses[sessionId] == nil { model.requestGitStatus(sessionId) }
        }
    }

    private func row(_ worktree: Worktree) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: worktree.isMain ? "house" : "arrow.triangle.branch")
                    .font(.system(size: 12)).foregroundStyle(CDS.textMuted)
                Text(worktree.branch ?? worktree.head ?? "detached")
                    .font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(1)
                if worktree.isMain { CDSChip(text: "Main") }
                if worktree.locked { CDSChip(text: "Locked", style: .warning) }
                if worktree.prunable { CDSChip(text: "Missing", style: .danger) }
                Spacer(minLength: 0)
            }
            Text(worktree.path)
                .font(CDS.caption).foregroundStyle(CDS.textMuted)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .listRowBackground(CDS.surface0)
        .contentShape(Rectangle())
        .onTapGesture { startIn = worktree }
        .contextMenu {
            Button("Start a session here", systemImage: "plus.bubble") { startIn = worktree }
            Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = worktree.path }
            if !worktree.isMain {
                Button("Remove…", systemImage: "trash", role: .destructive) { confirmRemove = worktree }
            }
        }
        .swipeActions(edge: .trailing) {
            if !worktree.isMain {
                Button(role: .destructive) { confirmRemove = worktree } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }
}
