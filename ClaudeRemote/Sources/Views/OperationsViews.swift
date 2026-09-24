import SwiftUI
import ClaudeRemoteCore

// MARK: - Feed

/// One timeline of what happened on every paired Mac and the hub: sessions, approvals, tasks, CI,
/// duels, host warnings. Filters by kind and Mac, and searches.
struct FeedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kinds = Set(HostEvent.Kind.allCases)
    @State private var macId: String?
    @State private var problemsOnly = false
    @State private var query = ""

    private var items: [FeedEvent] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.feed.filter { item in
            kinds.contains(item.event.kind)
                && (macId == nil || item.macId == macId)
                && (!problemsOnly || item.event.severity == .error || item.event.severity == .warning)
                && (q.isEmpty || item.event.title.lowercased().contains(q) || (item.event.detail?.lowercased().contains(q) ?? false))
        }
    }

    private var grouped: [(day: Date, items: [FeedEvent])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: items.prefix(600)) { cal.startOfDay(for: $0.event.date) }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0] ?? []) }
    }

    private var macsWithEvents: [PairingInfo] { model.macs.filter { model.eventsByMac[$0.id] != nil } }

    var body: some View {
        NavigationStack {
            List {
                if model.feed.isEmpty {
                    Text(model.connections.keys.contains(where: model.supportsOperations(mac:))
                         ? "Nothing yet — sessions, tasks, CI and warnings show up here as they happen."
                         : "The Macs need the newest Host app for the feed.")
                        .foregroundStyle(CDS.textMuted).listRowBackground(CDS.surface0)
                } else if items.isEmpty {
                    Text("Nothing matches.").foregroundStyle(CDS.textMuted).listRowBackground(CDS.surface0)
                }
                ForEach(grouped, id: \.day) { group in
                    Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(group.items) { row($0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .searchable(text: $query, prompt: "Search the feed")
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Problems only", isOn: $problemsOnly)
                        if macsWithEvents.count > 1 {
                            Picker("Mac", selection: $macId) {
                                Text("Every Mac").tag(String?.none)
                                ForEach(macsWithEvents) { Text($0.displayName).tag(Optional($0.id)) }
                            }
                        }
                        Section("Show") {
                            ForEach(HostEvent.Kind.allCases, id: \.self) { kind in
                                Toggle(isOn: Binding(get: { kinds.contains(kind) }, set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } })) {
                                    Label(kind.label, systemImage: kind.systemImage)
                                }
                            }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
            }
            .refreshable { model.refreshFeed() }
        }
        .onAppear { model.refreshFeed() }
    }

    private func row(_ item: FeedEvent) -> some View {
        let event = item.event
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color(event.severity))
                .frame(width: 22, height: 22)
                .background(color(event.severity).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(2)
                if let detail = event.detail { Text(detail).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(3) }
                HStack(spacing: 5) {
                    Text(event.date, style: .time)
                    if model.macs.count > 1 { Text("·"); Text(item.macName) }
                }
                .font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(CDS.surface0)
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
    }

    private func open(_ item: FeedEvent) {
        if let link = item.event.url, let url = URL(string: link), item.event.sessionId == nil {
            UIApplication.shared.open(url)
            return
        }
        guard let sessionId = item.event.sessionId else { return }
        if item.macId != model.activeMacId { model.switchTo(item.macId) }
        model.present(sessionId, kind: .agent)
        dismiss()
    }

    private func color(_ severity: HostEvent.Severity) -> Color {
        switch severity {
        case .info: return CDS.textSecondary
        case .success: return CDS.success
        case .warning: return CDS.warning
        case .error: return CDS.danger
        }
    }
}

// MARK: - Health

/// How a host's machine is doing: disk, memory, load, battery, logins — with what needs attention on top.
struct HealthView: View {
    @Environment(AppModel.self) private var model
    let macId: String

    private var report: HostHealth? { model.healthByMac[macId] }

    var body: some View {
        List {
            if let report {
                if !report.warnings.isEmpty {
                    Section {
                        ForEach(report.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(CDS.warning) }
                    }
                }
                Section("Machine") {
                    if let free = report.diskFree, let total = report.diskTotal {
                        gauge("Disk", used: Double(total - free), total: Double(total), text: "\(HostHealth.bytes(free)) free of \(HostHealth.bytes(total))")
                    }
                    if let used = report.memoryUsed, let total = report.memoryTotal {
                        gauge("Memory", used: Double(used), total: Double(total), text: "\(HostHealth.bytes(used)) of \(HostHealth.bytes(total))")
                    }
                    if let load = report.load1 {
                        LabeledContent("Load", value: String(format: "%.2f on %d cores", load, report.cpuCount))
                    }
                    if let battery = report.battery {
                        LabeledContent("Battery", value: "\(battery)%" + (report.charging == true ? " · charging" : (report.onAC == true ? " · on power" : " · on battery")))
                    } else if report.onAC == true {
                        LabeledContent("Power", value: "On power")
                    }
                    if let uptime = report.uptime {
                        LabeledContent("Up for", value: Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))
                    }
                }
                Section("Logins") {
                    if let claude = report.claudeLoggedIn { login("Claude", ok: claude) }
                    if let codex = report.codexLoggedIn { login("Codex", ok: codex) }
                    if report.githubInstalled {
                        LabeledContent("GitHub", value: report.githubLogin.map { "@\($0)" } ?? "not logged in")
                    }
                }
                Section {
                    Text("Checked \(report.checkedAt.formatted(date: .omitted, time: .shortened)). The host checks every ten minutes and tells you once when something needs attention.")
                        .font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
            } else {
                HStack { ProgressView(); Text("Asking the host…").foregroundStyle(CDS.textMuted) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CDS.surface0)
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { model.requestHealth(mac: macId) }
        .onAppear { model.requestHealth(mac: macId) }
    }

    private func gauge(_ title: String, used: Double, total: Double, text: String) -> some View {
        let share = total > 0 ? used / total : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(text).font(CDS.caption).foregroundStyle(CDS.textSecondary) }
            ProgressView(value: share).tint(share > 0.92 ? CDS.danger : (share > 0.8 ? CDS.warning : CDS.brand))
        }
    }

    private func login(_ name: String, ok: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            // Not a Label: in a list row it takes the row's icon layout and the row grows tall.
            HStack(spacing: 4) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                Text(ok ? "logged in" : "logged out")
            }
            .foregroundStyle(ok ? CDS.success : CDS.danger)
        }
    }
}

// MARK: - Shared into the app

/// Text or a link shared from another app: make it a task on the Mac, or drop it into a session.
struct ShareDraftView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: SharedDraft
    @State private var makingTask = false

    private var recent: [SessionSummary] {
        Array(model.sessions.filter { $0.kind != .chat }.sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Shared") {
                    Text(draft.text).font(CDS.body).foregroundStyle(CDS.textSecondary).lineLimit(8)
                }
                Section {
                    Button("New task on the Mac…", systemImage: "list.bullet.rectangle") { makingTask = true }
                        .disabled(!model.supportsQueue)
                }
                if !recent.isEmpty {
                    Section("Into a session") {
                        ForEach(recent) { session in
                            Button {
                                model.insertIntoComposer(session.id, text: draft.text)
                                model.present(session.id, kind: session.kind)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title).foregroundStyle(CDS.textPrimary).lineLimit(1)
                                    Text(session.projectName).font(CDS.caption).foregroundStyle(CDS.textMuted)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Send to the Mac")
            .navigationBarTitleDisplayMode(.inline)
            .tint(CDS.brand)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $makingTask, onDismiss: { dismiss() }) {
                TaskEditor(initialPrompt: draft.text, task: nil)
            }
        }
    }
}

// MARK: - Before / after

/// The two Simulator stills of a task side by side; a tap opens them full screen.
struct TaskPreviewStrip: View {
    @Environment(AppModel.self) private var model
    let preview: TaskPreview
    let title: String

    private func image(_ path: String?) -> UIImage? { path.flatMap { model.imageCache.images["file:\($0)"] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                thumb("Before", preview.beforePath)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(CDS.textMuted)
                thumb("After", preview.afterPath)
                Spacer(minLength: 0)
            }
            switch preview.state {
            case .before: Label("Screenshot before…", systemImage: "camera").font(CDS.caption).foregroundStyle(CDS.textMuted)
            case .after: Label("Screenshot after…", systemImage: "camera").font(CDS.caption).foregroundStyle(CDS.textMuted)
            case .failed: Text(preview.error ?? "No screenshot").font(CDS.caption).foregroundStyle(CDS.danger).lineLimit(2)
            case .done: EmptyView()
            }
        }
        .onAppear {
            for path in [preview.beforePath, preview.afterPath].compactMap({ $0 }) where image(path) == nil { model.requestFile(path) }
        }
        .onChange(of: preview) { _, new in
            for path in [new.beforePath, new.afterPath].compactMap({ $0 }) where image(path) == nil { model.requestFile(path) }
        }
    }

    private func thumb(_ label: String, _ path: String?) -> some View {
        VStack(spacing: 2) {
            Group {
                if let ui = image(path) {
                    Image(uiImage: ui).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(CDS.fillNeutral)
                        .overlay { if path != nil { ProgressView().controlSize(.mini) } }
                }
            }
            .frame(width: 54, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(CDS.border))
            Text(label).font(.caption2).foregroundStyle(CDS.textMuted)
        }
        .onTapGesture {
            let shots = [image(preview.beforePath), image(preview.afterPath)].compactMap { $0 }
            guard !shots.isEmpty else { return }
            model.imageViewer = ImageViewerTarget(images: shots, index: label == "After" && shots.count > 1 ? 1 : 0, name: "preview")
        }
    }
}

// MARK: - Backup

/// Export the app's settings to a file (optionally sealed with a passphrase), or bring them onto a new phone.
struct SettingsBackupView: View {
    @Environment(AppModel.self) private var model
    @State private var passphrase = ""
    @State private var exported: SettingsBackupFile?
    @State private var importing = false
    @State private var pendingImport: Data?
    @State private var importPassphrase = ""
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Form {
            Section {
                SecureField("Passphrase (recommended)", text: $passphrase)
                Button("Make the backup", systemImage: "doc.badge.arrow.up") {
                    do {
                        exported = SettingsBackupFile(data: try SettingsBackup.export(passphrase: passphrase))
                        message = nil
                    } catch {
                        message = ("\(error)", true)
                    }
                }
                if let exported {
                    ShareLink(item: exported, preview: SharePreview("ClaudeRemote settings", image: Image(systemName: "gearshape"))) {
                        Label("Save or send it…", systemImage: "square.and.arrow.up")
                    }
                }
            } header: { Text("Back up") } footer: {
                Text(passphrase.isEmpty
                     ? "Without a passphrase the file holds your pairing tokens in the clear — anyone with it can drive your Macs."
                     : "Paired Macs (with their tokens), saved prompts, pins and archives, share links and preferences, sealed with the passphrase.")
            }
            Section {
                Button("Restore from a file…", systemImage: "doc.badge.arrow.down") { importing = true }
                if let message {
                    Text(message.text).font(CDS.caption).foregroundStyle(message.isError ? CDS.danger : CDS.success)
                }
            } header: { Text("Restore") } footer: {
                Text("Adds the Macs from the backup (a Mac already here is refreshed, not doubled) and takes over its prompts and preferences.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CDS.surface0)
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { message = ("Could not read that file.", true); return }
            if SettingsBackup.isSealed(data) {
                importPassphrase = ""
                pendingImport = data
            } else {
                restore(data, passphrase: nil)
            }
        }
        .alert("Passphrase", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            SecureField("Passphrase", text: $importPassphrase)
            Button("Restore") { if let data = pendingImport { restore(data, passphrase: importPassphrase) }; pendingImport = nil }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("The backup is sealed with a passphrase.")
        }
    }

    private func restore(_ data: Data, passphrase: String?) {
        do {
            let entries = try SettingsBackup.read(data, passphrase: passphrase)
            model.restoreSettings(entries)
            message = ("Restored — \(model.macs.count) Mac\(model.macs.count == 1 ? "" : "s") paired.", false)
        } catch {
            message = ("\(error)", true)
        }
    }
}
