import SwiftUI
import ClaudeRemoteCore

/// The strip at the top of the session list after time away: how much happened, one tap to see it.
struct DigestCard: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    var body: some View {
        let reports = Array(model.digests.values)
        let sessions = reports.reduce(0) { $0 + $1.sessions.count }
        let waiting = reports.reduce(0) { $0 + $1.waitingCount }
        let failed = reports.reduce(0) { $0 + $1.errorCount }
        let tasks = reports.reduce(0) { $0 + $1.tasks.count }
        let since = reports.map(\.since).min()
        Button { isPresented = true } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sun.horizon")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CDS.brand)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("While you were away").font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                    Text(DigestCard.summary(sessions: sessions, waiting: waiting, failed: failed, tasks: tasks, since: since))
                        .font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button { model.dismissDigests() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(CDS.textMuted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(10)
            .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
            .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func summary(sessions: Int, waiting: Int, failed: Int, tasks: Int, since: Date?) -> String {
        var parts: [String] = []
        if sessions > 0 { parts.append("\(sessions) session\(sessions == 1 ? "" : "s") moved") }
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if failed > 0 { parts.append("\(failed) with errors") }
        if tasks > 0 { parts.append("\(tasks) task\(tasks == 1 ? "" : "s") finished") }
        var text = parts.isEmpty ? "Nothing new" : parts.joined(separator: " · ")
        if let since { text += " — since \(RelativeTime.string(since))" }
        return text
    }
}

/// Everything the digest found, per Mac: sessions with what their agent did, the queue's finished
/// tasks, and processes that stopped.
struct DigestView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var macIds: [String] { model.macs.map(\.id).filter { model.digests[$0] != nil } }

    var body: some View {
        NavigationStack {
            List {
                if macIds.isEmpty {
                    Text("Nothing happened in that window.")
                        .font(CDS.body).foregroundStyle(CDS.textMuted)
                        .listRowBackground(CDS.surface0)
                }
                ForEach(macIds, id: \.self) { macId in
                    if let report = model.digests[macId] { sections(report, macId: macId) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Catch up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Show what happened in") {
                            Button("The last hour") { model.requestDigest(since: Date().addingTimeInterval(-3600)) }
                            Button("Today") { model.requestDigest(since: Calendar.current.startOfDay(for: Date())) }
                            Button("The last 24 hours") { model.requestDigest(since: Date().addingTimeInterval(-86_400)) }
                            Button("The last week") { model.requestDigest(since: Date().addingTimeInterval(-7 * 86_400)) }
                        }
                        Button("Mark all as seen", systemImage: "checkmark") {
                            model.dismissDigests()
                            dismiss()
                        }
                    } label: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
        }
    }

    @ViewBuilder
    private func sections(_ report: DigestReport, macId: String) -> some View {
        let showMac = model.macs.count > 1
        if !report.sessions.isEmpty {
            Section {
                ForEach(report.sessions) { item in sessionRow(item, macId: macId) }
            } header: {
                Text(showMac ? "\(model.macName(macId)) · since \(RelativeTime.string(report.since))" : "Since \(RelativeTime.string(report.since))")
            }
        }
        if !report.tasks.isEmpty {
            Section(showMac ? "Tasks · \(model.macName(macId))" : "Tasks") {
                ForEach(report.tasks) { task in
                    Button {
                        if let sessionId = task.sessionId { open(sessionId, macId: macId, kind: .agent) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: task.status == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(task.status == .failed ? CDS.danger : CDS.success)
                                Text(task.title).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(2)
                            }
                            if let text = task.error ?? task.resultSummary, !text.isEmpty {
                                Text(text).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(3)
                            }
                        }
                    }
                    .listRowBackground(CDS.surface0)
                }
            }
        }
        if !report.processes.isEmpty {
            Section(showMac ? "Stopped processes · \(model.macName(macId))" : "Stopped processes") {
                ForEach(report.processes) { process in
                    HStack(spacing: 6) {
                        Image(systemName: process.exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(process.exitCode == 0 ? CDS.success : CDS.danger)
                        Text(process.displayName).font(CDS.code).foregroundStyle(CDS.textPrimary).lineLimit(1)
                        Spacer()
                        Text(process.exitCode.map { "exit \($0)" } ?? "").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    }
                    .listRowBackground(CDS.surface0)
                }
            }
        }
    }

    private func sessionRow(_ item: DigestItem, macId: String) -> some View {
        Button { open(item.sessionId, macId: macId, kind: item.kind) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusDot(status: item.status, origin: .host, agent: item.agent)
                    Text(item.title).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(2)
                    Spacer(minLength: 0)
                    Text(RelativeTime.string(item.updatedAt)).font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                HStack(spacing: 5) {
                    if item.kind == .agent { Text(item.projectName).lineLimit(1) } else { Text("Chat") }
                    if item.waiting { CDSChip(text: "Waiting for you", style: .warning) }
                    if item.errors > 0 { CDSChip(text: "\(item.errors) error\(item.errors == 1 ? "" : "s")", style: .danger) }
                }
                .font(CDS.caption).foregroundStyle(CDS.textMuted)
                let stats = DigestView.stats(item)
                if !stats.isEmpty { Text(stats).font(CDS.caption).foregroundStyle(CDS.textSecondary) }
                if !item.files.isEmpty {
                    Text(item.files.joined(separator: ", ") + (item.fileCount > item.files.count ? " +\(item.fileCount - item.files.count)" : ""))
                        .font(CDS.codeSmall).foregroundStyle(CDS.textMuted).lineLimit(2).truncationMode(.middle)
                }
                if let reply = item.lastReply {
                    Text(DigestView.plain(reply)).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(3)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(item.agent.tint.opacity(0.5)).frame(width: 2) }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(CDS.surface0)
    }

    /// A reply's Markdown reduced to its words: links to their labels, no emphasis, heading or code marks.
    static func plain(_ markdown: String) -> String {
        var s = markdown
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "• ", options: .regularExpression)
        for mark in ["**", "__", "`", "~~"] { s = s.replacingOccurrences(of: mark, with: "") }
        s = s.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stats(_ item: DigestItem) -> String {
        var parts: [String] = []
        if item.prompts > 0 { parts.append("\(item.prompts) prompt\(item.prompts == 1 ? "" : "s")") }
        if item.fileCount > 0 { parts.append("\(item.fileCount) file\(item.fileCount == 1 ? "" : "s") changed") }
        if item.commands > 0 { parts.append("\(item.commands) command\(item.commands == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func open(_ sessionId: String, macId: String, kind: SessionKind) {
        if macId != model.activeMacId { model.switchTo(macId) }
        model.present(sessionId, kind: kind)
        dismiss()
    }
}
