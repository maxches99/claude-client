import SwiftUI
import ClaudeRemoteCore

/// The Mac's task queue: prompts you line up from the phone that the daemon works off on its own —
/// one at a time or several in parallel, now or every morning. Each task runs in its own session,
/// so tapping a running one drops you into the transcript.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AgentTask?
    @State private var showNew = false
    @State private var confirmDelete: AgentTask?

    @State private var showNewDuel = false
    @State private var reviewing: String?

    private var solo: [AgentTask] { model.tasks.filter { $0.duelId == nil } }
    private var running: [AgentTask] { solo.filter { $0.status == .running } }
    private var waiting: [AgentTask] {
        solo.filter { $0.status == .queued || $0.status == .scheduled }
            .sorted { a, b in
                if (a.status == .queued) != (b.status == .queued) { return a.status == .queued }
                return (a.runAt ?? a.createdAt) < (b.runAt ?? b.createdAt)
            }
    }
    private var finished: [AgentTask] {
        solo.filter { $0.status.isFinished }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                settingsSection
                if !running.isEmpty { section("Running", running) }
                if !waiting.isEmpty { section("Up next", waiting) }
                if !model.duels.isEmpty {
                    Section("Duels") {
                        ForEach(model.duels) { duel in
                            NavigationLink { DuelView(duelId: duel.id) } label: { DuelRow(duel: duel) }
                                .listRowBackground(CDS.surface0)
                        }
                    }
                }
                if !finished.isEmpty { section("Finished", Array(finished.prefix(20))) }
                if model.tasks.isEmpty && model.duels.isEmpty {
                    Text("Nothing queued. Add a few chores — “run the tests and fix what fails”, “update the changelog” — and the Mac works them off while you're away.")
                        .font(CDS.body).foregroundStyle(CDS.textMuted)
                        .listRowBackground(CDS.surface0)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.supportsPipelines && model.hasCodex {
                        Menu {
                            Button("New task", systemImage: "plus") { showNew = true }
                            Button("New duel: Claude vs Codex", systemImage: "figure.fencing") { showNewDuel = true }
                        } label: { Image(systemName: "plus") }
                        .disabled(!model.isConnected)
                    } else {
                        Button { showNew = true } label: { Image(systemName: "plus") }
                            .disabled(!model.isConnected)
                    }
                }
            }
            .sheet(isPresented: $showNew) { TaskEditor(task: nil) }
            .sheet(isPresented: $showNewDuel) { DuelEditor() }
            .sheet(item: Binding(get: { reviewing.map { ReviewTarget(sessionId: $0) } }, set: { reviewing = $0?.sessionId })) { target in
                ReviewView(sessionId: target.sessionId)
            }
            .sheet(item: $editing) { task in TaskEditor(task: task) }
            // A session opened from in here (a duel side, a review sent) lands behind this sheet.
            .onChange(of: model.sessionPath) { dismiss() }
            .confirmationDialog("Delete this task?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let task = confirmDelete { model.taskAction(task.id, .delete) }
                    confirmDelete = nil
                }
            }
            .refreshable { model.requestTasks() }
        }
        .onAppear { model.requestTasks() }
    }

    private var settingsSection: some View {
        Section {
            Picker("Run at once", selection: Binding(
                get: { model.taskSettings.maxParallel },
                set: { model.setTaskSettings(TaskQueueSettings(maxParallel: $0, paused: model.taskSettings.paused)) }
            )) {
                Text("One at a time").tag(1)
                Text("Two").tag(2)
                Text("Three").tag(3)
                Text("Four").tag(4)
            }
            Toggle("Paused", isOn: Binding(
                get: { model.taskSettings.paused },
                set: { model.setTaskSettings(TaskQueueSettings(maxParallel: model.taskSettings.maxParallel, paused: $0)) }
            ))
            .tint(CDS.brand)
        } footer: {
            Text(model.taskSettings.paused
                 ? "Nothing new starts while paused; a task already running finishes."
                 : "Tasks run unattended, so pick a permission mode that doesn't stop to ask — or they'll wait for you in the inbox.")
                .font(CDS.caption).foregroundStyle(CDS.textMuted)
        }
        .listRowBackground(CDS.surface0)
    }

    private func section(_ title: String, _ items: [AgentTask]) -> some View {
        Section(title) {
            ForEach(items) { task in row(task) }
        }
    }

    private func row(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusIcon(task)
                Text(task.title).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                Text(task.projectName).lineLimit(1)
                Text("·")
                Text(task.agent.label).foregroundStyle(task.agent.tint)
                if task.inWorktree {
                    Text("·")
                    Label("worktree", systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                }
                if let daily = task.dailyLabel {
                    Text("·")
                    Label("daily \(daily)", systemImage: "clock.arrow.circlepath").labelStyle(.titleAndIcon)
                } else if task.status == .scheduled, let at = task.runAt {
                    Text("·")
                    Text(at, style: .time)
                }
            }
            .font(CDS.caption).foregroundStyle(CDS.textMuted)
            if let summary = task.resultSummary, !summary.isEmpty, task.status != .running {
                Text(summary).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(3)
            }
            if task.diffStat != nil || task.pullRequestURL != nil || (task.openPullRequest && !task.status.isFinished) {
                HStack(spacing: 8) {
                    if let stat = task.diffStat { Text(stat.label).font(CDS.caption).foregroundStyle(CDS.textMuted) }
                    if let pr = task.pullRequestURL, let url = URL(string: pr) {
                        Link(destination: url) {
                            Label("Pull request", systemImage: "arrow.triangle.pull").font(CDS.caption.weight(.medium))
                        }
                    } else if task.openPullRequest && !task.status.isFinished {
                        Label("draft PR when done", systemImage: "arrow.triangle.pull").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    }
                }
            }
            if let error = task.error, !error.isEmpty {
                Text(error).font(CDS.caption).foregroundStyle(CDS.danger).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(CDS.surface0)
        .contentShape(Rectangle())
        .onTapGesture {
            if let sessionId = task.sessionId {
                model.present(sessionId, kind: .agent)
                dismiss()
            } else if !task.status.isFinished {
                editing = task
            }
        }
        .contextMenu {
            if let sessionId = task.sessionId {
                Button("Open the session", systemImage: "arrow.up.forward.app") {
                    model.present(sessionId, kind: .agent)
                    dismiss()
                }
            }
            if task.status == .queued || task.status == .scheduled {
                Button("Run now", systemImage: "play.fill") { model.taskAction(task.id, .runNow) }
                Button("Edit…", systemImage: "pencil") { editing = task }
            }
            if task.status == .running || task.status == .queued || task.status == .scheduled {
                Button("Cancel", systemImage: "stop.fill", role: .destructive) { model.taskAction(task.id, .cancel) }
            }
            if task.status.isFinished {
                Button("Run again", systemImage: "arrow.clockwise") { model.taskAction(task.id, .retry) }
            }
            if model.supportsPipelines, let sessionId = task.sessionId, task.worktreePath != nil {
                Button("Review the changes…", systemImage: "text.magnifyingglass") { reviewing = sessionId }
            }
            if model.supportsPipelines, task.status == .done, task.worktreePath != nil, task.pullRequestURL == nil {
                Button("Open a draft pull request", systemImage: "arrow.triangle.pull") { model.taskAction(task.id, .openPullRequest) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = task }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { confirmDelete = task } label: { Label("Delete", systemImage: "trash") }
            if task.status == .queued || task.status == .scheduled {
                Button { model.taskAction(task.id, .runNow) } label: { Label("Run now", systemImage: "play.fill") }
                    .tint(CDS.accent)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ task: AgentTask) -> some View {
        switch task.status {
        case .running:
            ProgressView().controlSize(.mini).tint(task.agent.tint)
        case .queued:
            Image(systemName: "circle.dotted").foregroundStyle(CDS.textMuted)
        case .scheduled:
            Image(systemName: "clock").foregroundStyle(CDS.textMuted)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(CDS.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(CDS.danger)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(CDS.textMuted)
        }
    }
}

/// Add or edit one task: what to do, where, and when.
struct TaskEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: AgentTask?

    @State private var prompt = ""
    @State private var title = ""
    @State private var cwd = ""
    @State private var agent: AgentKind = .claude
    @State private var permissionMode = PermissionMode.acceptEdits.rawValue
    @State private var inWorktree = false
    @State private var openPullRequest = false
    @State private var showClone = false
    @State private var schedule = Schedule.now
    @State private var time = Date()

    private enum Schedule: String, CaseIterable, Identifiable {
        case now, once, daily
        var id: String { rawValue }
        var label: String {
            switch self {
            case .now: return "As soon as there's a slot"
            case .once: return "At a time today"
            case .daily: return "Every day"
            }
        }
    }

    private var projects: [ProjectInfo] { model.projects }
    private var canSave: Bool { !prompt.trimmingCharacters(in: .whitespaces).isEmpty && !cwd.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Prompt") {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(3...10)
                        .font(CDS.prose)
                }
                Section("Project") {
                    Picker("Folder", selection: $cwd) {
                        ForEach(projects) { project in
                            Text(project.name).tag(project.path)
                        }
                    }
                    if model.hasCodex {
                        Picker("Agent", selection: $agent) {
                            ForEach(AgentKind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Run in a fresh worktree", isOn: $inWorktree)
                        .tint(CDS.brand)
                    if model.supportsPipelines {
                        Toggle("Open a draft pull request when done", isOn: $openPullRequest)
                            .tint(CDS.brand)
                            .disabled(!inWorktree || model.host?.hasGitHubCLI != true)
                        Button("Clone a repository…", systemImage: "square.and.arrow.down.on.square") { showClone = true }
                    }
                }
                Section {
                    if agent == .claude {
                        Picker("Permissions", selection: $permissionMode) {
                            ForEach([PermissionMode.acceptEdits, .auto, .dontAsk, .manual], id: \.self) { mode in
                                Text(mode.label).tag(mode.rawValue)
                            }
                        }
                    } else {
                        Picker("Approvals", selection: $permissionMode) {
                            ForEach(CodexApprovalPolicy.allCases, id: \.self) { policy in
                                Text(policy.label).tag(policy.rawValue)
                            }
                        }
                    }
                } footer: {
                    Text("Nobody is watching a queued task, so anything it stops to ask lands in the approvals inbox and the queue waits.")
                        .font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                Section("When") {
                    Picker("Start", selection: $schedule) {
                        ForEach(Schedule.allCases) { option in Text(option.label).tag(option) }
                    }
                    if schedule != .now {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }
                Section("Name") {
                    TextField("Optional — the first line of the prompt otherwise", text: $title)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle(task == nil ? "New task" : "Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(task == nil ? "Add" : "Save") { save() }.disabled(!canSave)
                }
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showClone) { CloneRepositoryView { path in cwd = path } }
        .onChange(of: model.projects) { _, projects in
            if cwd.isEmpty { cwd = projects.first?.path ?? "" }
        }
    }

    private func load() {
        if let task {
            prompt = task.prompt
            title = task.title
            cwd = task.cwd
            agent = task.agent
            permissionMode = task.permissionMode ?? PermissionMode.acceptEdits.rawValue
            inWorktree = task.inWorktree
            openPullRequest = task.openPullRequest
            if let minutes = task.dailyAtMinutes {
                schedule = .daily
                time = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            } else if let at = task.runAt {
                schedule = .once
                time = at
            }
        } else {
            cwd = model.projects.first?.path ?? ""
            agent = .claude
            permissionMode = PermissionMode.acceptEdits.rawValue
        }
        if model.projects.isEmpty { model.refresh() }
    }

    private func save() {
        let minutes = Calendar.current.component(.hour, from: time) * 60 + Calendar.current.component(.minute, from: time)
        var built = task ?? AgentTask(title: "", prompt: "", cwd: cwd)
        built.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        built.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? AgentTask.title(fromPrompt: built.prompt) : title
        built.cwd = cwd
        built.agent = agent
        built.permissionMode = permissionMode
        built.inWorktree = inWorktree
        built.openPullRequest = inWorktree && openPullRequest
        switch schedule {
        case .now:
            built.dailyAtMinutes = nil
            built.runAt = nil
        case .once:
            built.dailyAtMinutes = nil
            built.runAt = TaskEditor.nextOccurrence(minutes: minutes)
        case .daily:
            built.dailyAtMinutes = minutes
            built.runAt = TaskEditor.nextOccurrence(minutes: minutes)
        }
        if task == nil { model.addTask(built) } else { model.updateTask(built) }
        dismiss()
    }

    /// Today at that time, or tomorrow when it has already passed.
    static func nextOccurrence(minutes: Int, from now: Date = Date(), calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        let today = calendar.date(from: components) ?? now
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? now)
    }
}


/// A session to review, as a sheet item.
struct ReviewTarget: Identifiable {
    let sessionId: String
    var id: String { sessionId }
}
