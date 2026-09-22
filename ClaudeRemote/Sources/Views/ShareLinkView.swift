import SwiftUI
import ClaudeRemoteCore

/// Publish the transcript as a read-only link. The page is encrypted on this phone; the Mac and the
/// relay carry only ciphertext, and the key is the part of the link after `#`.
struct ShareLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    @State private var ttl = SharePayload.ttlChoices[1].seconds
    @State private var working = false
    @State private var error: String?
    @State private var created: ShareRecord?
    @State private var confirmRevoke: ShareRecord?

    private var existing: [ShareRecord] { model.shares.filter { $0.sessionId == sessionId && !$0.isExpired } }

    var body: some View {
        NavigationStack {
            List {
                if let created {
                    Section {
                        linkRow(created, highlighted: true)
                    } header: { Text("Your link") } footer: {
                        Text("Anyone with this link can read the transcript until \(created.expiresAt.formatted(date: .abbreviated, time: .shortened)).")
                    }
                } else {
                    Section {
                        Picker("Link works for", selection: $ttl) {
                            ForEach(SharePayload.ttlChoices, id: \.seconds) { choice in Text(choice.label).tag(choice.seconds) }
                        }
                        Button {
                            Task { await create() }
                        } label: {
                            HStack {
                                Label("Create link", systemImage: "link")
                                if working { Spacer(); ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(working || !model.isConnected)
                    } footer: {
                        Text("The page — prompts, replies and the tool work folded up — is encrypted on this phone before it leaves. The Mac and the relay only ever hold ciphertext; the key is the part of the link after #, which browsers never send to a server.")
                    }
                }
                if let error {
                    Section { Text(error).font(CDS.caption).foregroundStyle(CDS.danger) }
                }
                let others = existing.filter { $0.id != created?.id }
                if !others.isEmpty {
                    Section("Earlier links to this session") {
                        ForEach(others) { record in linkRow(record, highlighted: false) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Share as a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Revoke this link?", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }), titleVisibility: .visible) {
                Button("Revoke", role: .destructive) {
                    if let record = confirmRevoke {
                        model.revokeShare(record)
                        if created?.id == record.id { created = nil }
                    }
                    confirmRevoke = nil
                }
            } message: {
                Text("The relay deletes the page; the link stops working for everyone.")
            }
        }
    }

    private func create() async {
        working = true
        error = nil
        defer { working = false }
        do {
            created = try await model.shareTranscript(sessionId, ttlSeconds: ttl)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func linkRow(_ record: ShareRecord, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.url)
                .font(CDS.codeSmall).foregroundStyle(highlighted ? CDS.textPrimary : CDS.textSecondary)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let url = URL(string: record.url) {
                    ShareLink(item: url, subject: Text(record.title), message: Text(record.title)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(CDSButtonStyle(variant: highlighted ? .primary : .secondary))
                    .accessibilityLabel("Share")
                }
                Button { UIPasteboard.general.string = record.url } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(CDSButtonStyle(variant: .secondary))
                    .accessibilityLabel("Copy")
                Spacer()
                Button(role: .destructive) { confirmRevoke = record } label: { Text("Revoke") }
                    .buttonStyle(CDSButtonStyle(variant: .danger))
            }
            Text("Expires \(record.expiresAt.formatted(.relative(presentation: .named)))")
                .font(CDS.caption).foregroundStyle(CDS.textMuted)
        }
        .padding(.vertical, 4)
        .listRowBackground(CDS.surface0)
    }
}

/// Every link this phone published, across sessions and Macs.
struct SharedLinksView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRevoke: ShareRecord?

    var body: some View {
        List {
            if model.shares.isEmpty {
                Text("No links yet. Share one from a session's menu — Share as a link.")
                    .font(CDS.body).foregroundStyle(CDS.textMuted)
            }
            ForEach(model.shares) { record in
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(CDS.bodyMedium).lineLimit(1)
                    Text(record.isExpired ? "Expired" : "Expires \(record.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(CDS.caption).foregroundStyle(record.isExpired ? CDS.danger : CDS.textMuted)
                    Text(model.macName(record.macId)).font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                .contextMenu {
                    Button("Copy link", systemImage: "doc.on.doc") { UIPasteboard.general.string = record.url }
                    if !record.isExpired {
                        Button("Revoke", systemImage: "xmark.circle", role: .destructive) { confirmRevoke = record }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { confirmRevoke = record } label: { Label("Revoke", systemImage: "xmark.circle") }
                }
            }
        }
        .navigationTitle("Shared links")
        .toolbar {
            if model.shares.contains(where: \.isExpired) {
                ToolbarItem(placement: .topBarTrailing) { Button("Clear expired") { model.forgetExpiredShares() } }
            }
        }
        .confirmationDialog("Revoke this link?", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }), titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                if let record = confirmRevoke { model.revokeShare(record) }
                confirmRevoke = nil
            }
        }
    }
}
