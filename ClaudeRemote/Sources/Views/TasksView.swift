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
    @State private var confirmUndo: AgentTask?

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
                    if model.supportsPipelines && (model.hasBothAgents || model.supportsAutomation) {
                        Menu {
                            Button("New task", systemImage: "plus") { showNew = true }
                            Button(model.hasBothAgents ? "New duel: Claude vs Codex" : "New duel: model vs model", systemImage: "figure.fencing") { showNewDuel = true }
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
            .confirmationDialog("Put the project back as it was before this task?", isPresented: Binding(get: { confirmUndo != nil }, set: { if !$0 { confirmUndo = nil } }), titleVisibility: .visible) {
                Button("Undo the changes", role: .destructive) {
                    if let task = confirmUndo { model.taskAction(task.id, .restoreSnapshot) }
                    confirmUndo = nil
                }
            } message: {
                Text("Every file goes back to how it was when the task started — its edits, new files and commits are gone. Ignored files are left alone.")
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

    private func ciSymbol(_ state: TaskCI.State) -> String {
        switch state {
        case .pending: return "clock"
        case .passing: return "checkmark.circle.fill"
        case .failing, .gaveUp: return "xmark.circle.fill"
        case .repairing: return "wrench.and.screwdriver"
        case .fixReady: return "arrow.up.circle.fill"
        }
    }

    private func ciColor(_ state: TaskCI.State) -> Color {
        switch state {
        case .passing: return CDS.success
        case .failing, .gaveUp: return CDS.danger
        case .fixReady: return CDS.brand
        default: return CDS.textMuted
        }
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
            if let ci = task.ci {
                HStack(spacing: 6) {
                    Image(systemName: ciSymbol(ci.state)).foregroundStyle(ciColor(ci.state))
                    Text(ci.label).foregroundStyle(ciColor(ci.state)).lineLimit(1)
                    if ci.state == .fixReady {
                        Spacer(minLength: 0)
                        Button("Push the fix") { model.taskAction(task.id, .pushFix) }
                            .buttonStyle(CDSButtonStyle(variant: .primary))
                    }
                }
                .font(CDS.caption)
            } else if task.fixCI, task.pullRequestURL != nil {
                Label("watching CI", systemImage: "eye").font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            if let preview = task.preview { TaskPreviewStrip(preview: preview, title: task.title) }
            if let snapshot = task.snapshot, snapshot.restoredAt != nil {
                Label("rolled back", systemImage: "arrow.uturn.backward").font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            if let issue = task.issue {
                Label("#\(issue.number) \(issue.title)", systemImage: "smallcircle.filled.circle").font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1)
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
            if model.supportsOperations, let snapshot = task.snapshot, snapshot.restoredAt == nil, task.status.isFinished {
                Button("Undo the task's changes", systemImage: "arrow.uturn.backward", role: .destructive) { confirmUndo = task }
            }
            if model.supportsAutomation, task.pullRequestURL != nil, task.worktreePath != nil {
                if task.ci?.state == .fixReady {
                    Button("Push the CI fix", systemImage: "arrow.up.circle") { model.taskAction(task.id, .pushFix) }
                }
                Button(task.fixCI ? "Stop fixing CI" : "Fix CI failures", systemImage: task.fixCI ? "eye.slash" : "wrench.and.screwdriver") {
                    model.taskAction(task.id, .toggleFixCI)
                }
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
    /// A new task's prompt to start from (shared into the app).
    var initialPrompt: String? = nil
    /// Nobody watches a queued task: Claude edits without asking, Codex never stops to ask.
    static func defaultMode(for agent: AgentKind) -> String {
        agent == .claude ? PermissionMode.acceptEdits.rawValue : CodexApprovalPolicy.never.rawValue
    }

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
    @State private var issue: IssueRef?
    @State private var fixCI = false
    @State private var wantsPreview = false
    @State private var showIssues = false
    @State private var template: PromptTemplate?
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
                Section {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(3...10)
                        .font(CDS.prose)
                    if let issue {
                        HStack {
                            Label("Resolves #\(issue.number)", systemImage: "smallcircle.filled.circle").font(CDS.caption).foregroundStyle(CDS.success)
                            Text(issue.title).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1)
                            Spacer()
                            Button { self.issue = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(CDS.textMuted)
                        }
                    }
                } header: {
                    HStack {
                        Text("Prompt")
                        Spacer()
                        if model.supportsAutomation {
                            Menu {
                                if model.host?.hasGitHubCLI == true {
                                    Button("From a GitHub issue…", systemImage: "smallcircle.filled.circle") { showIssues = true }
                                }
                                let templates = model.templatesByCwd[cwd] ?? []
                                if !templates.isEmpty {
                                    Section("Templates") {
                                        ForEach(templates) { t in Button(t.name, systemImage: "text.badge.plus") { template = t } }
                                    }
                                }
                            } label: { Label("Start from", systemImage: "plus.circle") }
                            .font(CDS.caption).textCase(nil)
                        }
                    }
                }
                Section("Project") {
                    Picker("Folder", selection: $cwd) {
                        ForEach(projects) { project in
                            Text(project.name).tag(project.path)
                        }
                    }
                    if model.hasBothAgents {
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
                        if model.supportsAutomation {
                            Toggle("Fix CI failures on it", isOn: $fixCI)
                                .tint(CDS.brand)
                                .disabled(!inWorktree || !openPullRequest)
                        }
                        if model.supportsOperations {
                            Toggle("Screenshot before and after", isOn: $wantsPreview)
                                .tint(CDS.brand)
                        }
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
        .onChange(of: agent) { _, new in
            // Claude's modes and Codex's approval policies are different vocabularies.
            let valid = new == .claude ? PermissionMode.allCases.map(\.rawValue) : CodexApprovalPolicy.allCases.map(\.rawValue)
            if !valid.contains(permissionMode) { permissionMode = TaskEditor.defaultMode(for: new) }
        }
        .sheet(isPresented: $showClone) { CloneRepositoryView { path in cwd = path } }
        .sheet(isPresented: $showIssues) {
            IssuePicker(cwd: cwd) { picked in
                issue = IssueRef(number: picked.number, title: picked.title, url: picked.url)
                prompt = picked.taskPrompt
                if title.trimmingCharacters(in: .whitespaces).isEmpty { title = "#\(picked.number) \(picked.title)" }
                inWorktree = true
                if model.host?.hasGitHubCLI == true { openPullRequest = true }
            }
        }
        .sheet(item: $template) { t in
            TemplateForm(template: t) { filled in prompt = filled }
        }
        .onChange(of: cwd) { _, new in if model.supportsAutomation, !new.isEmpty { model.requestTemplates(cwd: new) } }
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
            issue = task.issue
            fixCI = task.fixCI
            wantsPreview = task.wantsPreview
            if let minutes = task.dailyAtMinutes {
                schedule = .daily
                time = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            } else if let at = task.runAt {
                schedule = .once
                time = at
            }
        } else {
            cwd = model.projects.first?.path ?? ""
            if let initialPrompt, prompt.isEmpty { prompt = initialPrompt }
            agent = model.defaultAgent
            permissionMode = TaskEditor.defaultMode(for: agent)
        }
        if model.projects.isEmpty { model.refresh() }
        if model.supportsAutomation, !cwd.isEmpty { model.requestTemplates(cwd: cwd) }
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
        built.issue = issue
        built.fixCI = built.openPullRequest && fixCI
        built.wantsPreview = wantsPreview
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
