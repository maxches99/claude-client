import SwiftUI
import ClaudeRemoteCore

/// Crashes from the projects' crash reporters (Sentry), as the Mac last saw them: each with a button
/// that starts a task fixing it, and the reporters themselves to add or change.
struct CrashesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CrashSource?
    @State private var adding = false

    private var open: [CrashIssue] { model.crashIssues.filter { !$0.ignored } }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.crashError {
                    Text(error).font(CDS.caption).foregroundStyle(CDS.danger).listRowBackground(CDS.surface0)
                }
                if model.crashSources.isEmpty, model.crashesLoaded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect Sentry and the Mac checks every 15 minutes for crashes it hasn't seen. Each new one comes with a button that has an agent fix it in a worktree and open a draft pull request.")
                            .font(CDS.body).foregroundStyle(CDS.textSecondary)
                        Button("Connect Sentry…") { adding = true }
                            .buttonStyle(CDSButtonStyle(variant: .primary))
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(CDS.surface0)
                } else if !model.crashesLoaded {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(CDS.surface0)
                }
                if !open.isEmpty {
                    Section("Crashes") {
                        ForEach(open) { issue in crashRow(issue) }
                    }
                }
                if !model.crashSources.isEmpty {
                    Section("Watching") {
                        ForEach(model.crashSources) { source in sourceRow(source) }
                        Button("Add a Sentry project…", systemImage: "plus") { adding = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Crashes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !model.crashSources.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.checkCrashesNow() } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(!model.isConnected)
                            .accessibilityLabel("Check now")
                    }
                }
            }
            .refreshable { model.checkCrashesNow() }
        }
        .onAppear { model.requestCrashes(); model.requestTasks() }
        .sheet(isPresented: $adding) { CrashSourceEditor(source: nil) }
        .sheet(item: $editing) { source in CrashSourceEditor(source: source) }
    }

    private func crashRow(_ issue: CrashIssue) -> some View {
        let task = issue.taskId.flatMap { id in model.tasks.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "ant.fill").font(.caption).foregroundStyle(issue.level == "warning" ? CDS.warning : CDS.danger)
                Text(issue.title).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(3)
            }
            if let culprit = issue.culprit, !culprit.isEmpty {
                Text(culprit).font(CDS.codeSmall).foregroundStyle(CDS.textSecondary).lineLimit(2)
            }
            HStack(spacing: 5) {
                if let shortId = issue.shortId { Text(shortId) ; Text("·") }
                Text(issue.impactLabel)
                if let last = issue.lastSeen { Text("·"); Text(last, style: .relative) + Text(" ago") }
            }
            .font(CDS.caption).foregroundStyle(CDS.textMuted)
            HStack(spacing: 8) {
                if let task {
                    fixState(task.status.isFinished ? "Fix \(task.status.label.lowercased())" : "Being fixed…",
                             symbol: task.status.isFinished ? "checkmark.circle" : "hammer")
                    if let pr = task.pullRequestURL, let url = URL(string: pr) {
                        Link(destination: url) { Label("Pull request", systemImage: "arrow.triangle.pull").font(CDS.caption.weight(.medium)) }
                    }
                } else if issue.taskId != nil {
                    fixState("Being fixed…", symbol: "hammer")
                } else {
                    Button("Fix it") { model.fixCrash(issue.id) }
                        .buttonStyle(CDSButtonStyle(variant: .primary))
                        .disabled(!model.isConnected)
                }
                Spacer(minLength: 0)
                if let link = issue.permalink, let url = URL(string: link) {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .accessibilityLabel("Open in Sentry")
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
        .listRowBackground(CDS.surface0)
        .swipeActions(edge: .trailing) {
            Button("Ignore", systemImage: "eye.slash") { model.ignoreCrash(issue.id) }
        }
    }

    private func fixState(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption)
            Text(text).font(CDS.caption)
        }
        .foregroundStyle(CDS.textSecondary)
    }

    private func sourceRow(_ source: CrashSource) -> some View {
        Button { editing = source } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(source.label).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                    Spacer(minLength: 0)
                    if source.autoFix { Text("auto-fix").font(CDS.caption).foregroundStyle(CDS.brand) }
                }
                Text("→ \((source.cwd as NSString).lastPathComponent)").font(CDS.caption).foregroundStyle(CDS.textMuted)
                if let error = source.lastError {
                    Text(error).font(CDS.caption).foregroundStyle(CDS.danger).lineLimit(3)
                } else if let checked = source.lastCheckedAt {
                    (Text("checked ") + Text(checked, style: .relative) + Text(" ago")).font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
            }
        }
        .listRowBackground(CDS.surface0)
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) { model.removeCrashSource(source.id) }
        }
    }
}

/// Add or change a Sentry project: where it lives, which repository fixes go into, and the token.
struct CrashSourceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: CrashSource?

    @State private var baseURL = "https://sentry.io"
    @State private var organization = ""
    @State private var project = ""
    @State private var cwd = ""
    @State private var token = ""
    @State private var autoFix = false

    private var canSave: Bool {
        !organization.trimmingCharacters(in: .whitespaces).isEmpty && !project.trimmingCharacters(in: .whitespaces).isEmpty
            && !cwd.isEmpty && (source?.hasToken == true || !token.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Organization slug", text: $organization)
                    TextField("Project slug", text: $project)
                    TextField("Address", text: $baseURL).keyboardType(.URL)
                } header: { Text("Sentry project") } footer: {
                    Text("The slugs are in the project's address: sentry.io/organizations/<organization>/projects/<project>. Change the address only for a self-hosted Sentry.")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Section {
                    SecureField(source?.hasToken == true ? "Stored on the Mac — paste to replace" : "Auth token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Token") } footer: {
                    Text("An auth token with the event:read scope (Settings → Auth Tokens). It is kept on the Mac only and never sent back to a phone.")
                }
                Section {
                    Picker("Repository", selection: $cwd) {
                        ForEach(model.projects) { Text($0.name).tag($0.path) }
                    }
                    Toggle("Fix new crashes by itself", isOn: $autoFix)
                } header: { Text("Fixes") } footer: {
                    Text("Each fix runs in its own worktree and opens a draft pull request. Off, a new crash waits for you to tap Fix it.")
                }
                if let source {
                    Section {
                        Button("Stop watching", role: .destructive) {
                            model.removeCrashSource(source.id)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle(source == nil ? "Connect Sentry" : source!.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave || !model.isConnected) }
            }
        }
        .onAppear {
            if let source {
                baseURL = source.baseURL
                organization = source.organization
                project = source.project
                cwd = source.cwd
                autoFix = source.autoFix
            } else {
                cwd = model.projects.first?.path ?? ""
            }
            if model.projects.isEmpty { model.refresh() }
        }
    }

    private func save() {
        var built = source ?? CrashSource(organization: "", project: "", cwd: "")
        built.baseURL = baseURL
        built.organization = organization
        built.project = project
        built.cwd = cwd
        built.autoFix = autoFix
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        built.token = trimmed.isEmpty ? nil : trimmed
        model.saveCrashSource(built)
        dismiss()
    }
}
