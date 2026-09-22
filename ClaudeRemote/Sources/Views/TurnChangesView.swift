import SwiftUI
import ClaudeRemoteCore

/// What each turn of the agent did to the files — read out of the transcript, newest turn first.
/// The point is to be able to undo exactly one turn: see the files it wrote, read the diff, throw
/// the changes away if it went the wrong way.
struct TurnChangesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    @State private var expanded: Set<String> = []
    @State private var confirmRevert: TurnChanges.Turn?
    @State private var openedFile: String?

    private var turns: [TurnChanges.Turn] { model.turnChanges(sessionId) }
    private var cwd: String { model.projectRoot(sessionId) }

    var body: some View {
        NavigationStack {
            List {
                if turns.isEmpty {
                    Text("No turn in this transcript has written a file yet.")
                        .font(CDS.body).foregroundStyle(CDS.textMuted)
                        .listRowBackground(CDS.surface0)
                }
                ForEach(turns) { turn in
                    Section {
                        ForEach(turn.paths, id: \.self) { path in fileRow(turn: turn, path: path) }
                        if !turn.commands.isEmpty {
                            DisclosureGroup("Commands it ran (\(turn.commands.count))") {
                                ForEach(Array(turn.commands.enumerated()), id: \.offset) { _, command in
                                    Text(command).font(CDS.codeSmall).foregroundStyle(CDS.textSecondary).lineLimit(3)
                                }
                            }
                            .font(CDS.caption)
                            .listRowBackground(CDS.surface0)
                        }
                        Button(role: .destructive) {
                            confirmRevert = turn
                        } label: {
                            Label("Undo this turn's file changes", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!model.isConnected || model.gitBusy.contains(sessionId))
                        .listRowBackground(CDS.surface0)
                    } header: {
                        header(turn)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Changes by turn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Undo this turn?", isPresented: Binding(get: { confirmRevert != nil }, set: { if !$0 { confirmRevert = nil } }), titleVisibility: .visible) {
                Button("Throw the changes away", role: .destructive) {
                    if let turn = confirmRevert { model.revert(sessionId, paths: turn.paths) }
                    confirmRevert = nil
                }
            } message: {
                Text("The \(confirmRevert?.paths.count ?? 0) file(s) go back to the last commit — anything uncommitted in them is lost, including edits made after this turn. The conversation is untouched; rewind it from the message menu if you also want the agent to forget.")
            }
            .sheet(item: Binding(get: { openedFile.map { FilePath(path: $0) } }, set: { openedFile = $0?.path })) { file in
                NavigationStack {
                    // The diff comes from git, so the file is addressed the way the repo sees it.
                    GitFileDiffView(sessionId: sessionId,
                                    file: model.gitStatuses[sessionId]?.files.first { $0.path == relative(file.path) }
                                        ?? GitFile(path: relative(file.path), indexStatus: ".", workStatus: "M"))
                }
            }
        }
    }

    private struct FilePath: Identifiable { let path: String; var id: String { path } }

    private func header(_ turn: TurnChanges.Turn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(turn.prompt.isEmpty ? "Turn" : turn.prompt)
                .font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                .lineLimit(2)
                .textCase(nil)
            HStack(spacing: 5) {
                if let at = turn.startedAt { Text(RelativeTime.string(at)) }
                Text("·")
                Text("\(turn.paths.count) file\(turn.paths.count == 1 ? "" : "s")")
                if turn.isCurrent {
                    Text("·")
                    Text("still running")
                }
            }
            .font(CDS.caption).foregroundStyle(CDS.textMuted).textCase(nil)
        }
        .padding(.vertical, 4)
    }

    private func fileRow(turn: TurnChanges.Turn, path: String) -> some View {
        Button {
            openedFile = path
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(CDS.textMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent).font(CDS.body).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    Text(relative(path)).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(CDS.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(CDS.surface0)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.revert(sessionId, paths: [path])
            } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
        }
    }

    private func relative(_ path: String) -> String {
        TurnChanges.repoRelative([path], cwd: cwd).first ?? path
    }
}
