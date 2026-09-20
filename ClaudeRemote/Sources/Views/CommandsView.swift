import SwiftUI
import ClaudeRemoteCore

/// Quick commands for the project — build, test, generate — run on the Mac without the agent, with
/// the output streaming in. Commands come from `.ccremote.json` in the repo or are guessed from
/// its build files; anything else can be typed.
struct CommandsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    @State private var custom = ""
    @State private var run: AppModel.CommandRun?
    @FocusState private var customFocused: Bool

    private var commands: [ProjectCommand]? { model.projectCommands[sessionId] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("Any shell command…", text: $custom)
                            .font(CDS.code)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($customFocused)
                            .onSubmit { start(custom) }
                        Button { start(custom) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(CDSButtonStyle(variant: .primary))
                            .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .listRowBackground(CDS.surface0)
                } footer: {
                    Text("Runs in the project directory on the Mac with your login shell.")
                        .font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                if let commands {
                    let repo = commands.filter { $0.source == "repo" }
                    let guessed = commands.filter { $0.source != "repo" }
                    if !repo.isEmpty { section("From .ccremote.json", repo) }
                    if !guessed.isEmpty { section(repo.isEmpty ? "Commands" : "Also", guessed) }
                    if commands.isEmpty {
                        Text("Nothing recognised here — add a `.ccremote.json` with `{\"commands\": [{\"name\": \"Tests\", \"command\": \"swift test\"}]}`.")
                            .font(CDS.caption).foregroundStyle(CDS.textMuted).listRowBackground(CDS.surface0)
                    }
                } else {
                    ProgressView().tint(CDS.textMuted).listRowBackground(CDS.surface0)
                }
                let recent = model.commandRuns.values.filter { $0.sessionId == sessionId }.sorted { $0.startedAt > $1.startedAt }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent.prefix(8), id: \.id) { r in
                            Button { run = r } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: r.done ? (r.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill") : "circle.dotted")
                                        .foregroundStyle(r.done ? (r.exitCode == 0 ? CDS.success : CDS.danger) : CDS.textMuted)
                                    Text(r.command).font(CDS.code).foregroundStyle(CDS.textPrimary).lineLimit(1)
                                    Spacer()
                                    Text(r.startedAt, style: .time).font(CDS.caption).foregroundStyle(CDS.textMuted)
                                }
                            }
                            .listRowBackground(CDS.surface0)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.requestCommands(sessionId) } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .navigationDestination(item: $run) { run in CommandRunView(run: run) }
        }
        .onAppear { if commands == nil { model.requestCommands(sessionId) } }
    }

    private func section(_ title: String, _ items: [ProjectCommand]) -> some View {
        Section(title) {
            ForEach(items) { c in
                Button { start(c.command) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                        Text(c.command).font(CDS.codeSmall).foregroundStyle(CDS.textMuted).lineLimit(1)
                    }
                }
                .listRowBackground(CDS.surface0)
            }
        }
    }

    private func start(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customFocused = false
        model.runCommand(sessionId, command: trimmed) { started in
            if let started { run = started }
        }
    }
}

/// A command's live output, its exit status, and a way to hand the output to the agent.
struct CommandRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let run: AppModel.CommandRun

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(run.output.isEmpty ? (run.done ? "(no output)" : "…") : run.output)
                        .font(CDS.codeSmall).foregroundStyle(CDS.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(CDS.gutter)
            }
            .onChange(of: run.output.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(CDS.surface0)
        .safeAreaInset(edge: .bottom) { statusBar }
        .navigationTitle(run.command)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy output", systemImage: "doc.on.doc") { UIPasteboard.general.string = run.output }
                    Button("Send output to the agent", systemImage: "text.bubble") {
                        model.insertIntoComposer(run.sessionId, text: CommandRunView.quote(run))
                        dismiss()
                    }
                    .disabled(run.output.isEmpty)
                    Button("Run again", systemImage: "arrow.clockwise") {
                        model.runCommand(run.sessionId, command: run.command) { _ in }
                    }
                    .disabled(!run.done)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if run.done {
                let ok = run.exitCode == 0
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? CDS.success : CDS.danger)
                Text(ok ? "Finished" : (run.exitCode.map { $0 < 0 ? "Killed by signal \(-$0)" : "Exit code \($0)" } ?? "Finished"))
                    .font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                Spacer()
                Text(Media.humanSize(run.output.utf8.count)).font(CDS.caption).foregroundStyle(CDS.textMuted)
            } else {
                ProgressView().controlSize(.small).tint(CDS.textMuted)
                Text("Running…").font(CDS.bodyMedium).foregroundStyle(CDS.textSecondary)
                Spacer()
                Button("Cancel") { model.cancelCommand(run) }
                    .buttonStyle(CDSButtonStyle(variant: .secondary))
            }
        }
        .padding(12)
        .background(CDS.surface0)
        .overlay(alignment: .top) { Divider().overlay(CDS.border) }
    }

    /// The tail of the output as a fenced block the agent can read.
    static func quote(_ run: AppModel.CommandRun) -> String {
        var text = run.output
        if text.count > 6000 { text = "…\n" + String(text.suffix(6000)) }
        let status = run.exitCode.map { " (exit \($0))" } ?? ""
        return "Output of `\(run.command)`\(status):\n```\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n```"
    }
}
