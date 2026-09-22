import SwiftUI
import ClaudeRemoteCore

/// Commands left running on the Mac — a dev server, a watcher, a long build. They outlive the
/// phone's connection: the daemon keeps them and buffers the output, so coming back attaches to
/// what is still running instead of starting over.
struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The session whose project new commands start in (nil = the Mac's home directory).
    var sessionId: String?

    @State private var command = ""
    @State private var opened: AppModel.CommandRun?
    @State private var confirmKill: BackgroundProcess?

    private var running: [BackgroundProcess] { model.backgroundProcesses.filter(\.running) }
    private var finished: [BackgroundProcess] { model.backgroundProcesses.filter { !$0.running } }

    var body: some View {
        NavigationStack {
            List {
                if sessionId != nil {
                    Section {
                        HStack(spacing: 8) {
                            TextField("npm run dev, swift build --watch…", text: $command)
                                .font(CDS.code)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .onSubmit { start() }
                            Button { start() } label: { Image(systemName: "play.fill") }
                                .buttonStyle(CDSButtonStyle(variant: .primary))
                                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || !model.isConnected)
                        }
                        .listRowBackground(CDS.surface0)
                    } header: {
                        Text("Start in the background")
                    } footer: {
                        Text("Keeps running on the Mac when you leave the app. Stop it here when you're done — nothing else will.")
                            .font(CDS.caption).foregroundStyle(CDS.textMuted)
                    }
                }
                if !running.isEmpty { section("Running", running) }
                if !finished.isEmpty { section("Finished", finished) }
                if model.backgroundProcesses.isEmpty {
                    Text("Nothing running. A background command survives leaving the app — good for dev servers and watchers.")
                        .font(CDS.body).foregroundStyle(CDS.textMuted)
                        .listRowBackground(CDS.surface0)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Processes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.requestProcesses() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .navigationDestination(item: $opened) { run in CommandRunView(run: run) }
            .confirmationDialog("Stop this process?", isPresented: Binding(get: { confirmKill != nil }, set: { if !$0 { confirmKill = nil } }), titleVisibility: .visible) {
                Button("Stop", role: .destructive) {
                    if let process = confirmKill { model.killProcess(process) }
                    confirmKill = nil
                }
            } message: {
                Text(confirmKill?.command ?? "")
            }
            .refreshable { model.requestProcesses() }
        }
        .onAppear { model.requestProcesses() }
    }

    private func section(_ title: String, _ items: [BackgroundProcess]) -> some View {
        Section(title) {
            ForEach(items) { process in row(process) }
        }
    }

    private func row(_ process: BackgroundProcess) -> some View {
        Button {
            opened = model.attachProcess(process, attached: true)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if process.running {
                        Circle().fill(CDS.successFill).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: process.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(process.exitCode == 0 ? CDS.success : CDS.danger)
                    }
                    Text(process.label ?? process.command)
                        .font(CDS.code).foregroundStyle(CDS.textPrimary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    Text(process.projectName).lineLimit(1)
                    Text("·")
                    if process.running {
                        Text("started \(RelativeTime.string(process.startedAt))")
                    } else if let code = process.exitCode {
                        Text(code == 0 ? "finished" : (code < 0 ? "killed by signal \(-code)" : "exit \(code)"))
                    }
                    if process.outputBytes > 0 {
                        Text("·")
                        Text(Media.humanSize(process.outputBytes))
                    }
                }
                .font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(CDS.surface0)
        .swipeActions(edge: .trailing) {
            if process.running {
                Button(role: .destructive) { confirmKill = process } label: { Label("Stop", systemImage: "stop.fill") }
            }
        }
        .contextMenu {
            if process.running {
                Button("Stop", systemImage: "stop.fill", role: .destructive) { confirmKill = process }
            }
            Button("Copy command", systemImage: "doc.on.doc") { UIPasteboard.general.string = process.command }
        }
    }

    private func start() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.startProcess(sessionId, command: trimmed, label: nil) { run in
            guard let run else { return }
            command = ""
            opened = run
        }
    }
}
