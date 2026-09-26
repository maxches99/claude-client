import SwiftUI
import CoreImage.CIFilterBuiltins
import ClaudeRemoteCore

// MARK: - Plan check

/// The plan a task wrote and how the change measured up to it.
struct PlanCheckView: View {
    let check: PlanCheck
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checklist").foregroundStyle(allDone ? CDS.success : CDS.warning)
                    Text(check.steps.isEmpty ? check.summary : "Plan: \(check.doneCount) of \(check.steps.count) steps done")
                        .foregroundStyle(CDS.textSecondary).lineLimit(1)
                    if !check.steps.isEmpty { Chevron(expanded: expanded) }
                }
                .font(CDS.caption)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(check.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol(step.status)).foregroundStyle(color(step.status)).font(.caption2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.text).font(CDS.caption).foregroundStyle(CDS.textPrimary)
                            if let note = step.note { Text(note).font(.caption2).foregroundStyle(CDS.textMuted) }
                        }
                    }
                }
                if !check.extras.isEmpty {
                    Text("Not in the plan: " + check.extras.joined(separator: "; ")).font(.caption2).foregroundStyle(CDS.textMuted)
                }
                if !check.summary.isEmpty, !check.steps.isEmpty {
                    Text(check.summary).font(.caption2).foregroundStyle(CDS.textSecondary)
                }
            }
        }
    }

    private var allDone: Bool { !check.steps.isEmpty && check.doneCount == check.steps.count }

    private func symbol(_ s: PlanCheck.Step.Status) -> String {
        switch s { case .done: return "checkmark.circle.fill"; case .partial: return "circle.lefthalf.filled"; case .missing: return "circle" }
    }

    private func color(_ s: PlanCheck.Step.Status) -> Color {
        switch s { case .done: return CDS.success; case .partial: return CDS.warning; case .missing: return CDS.danger }
    }
}

// MARK: - Handing a session over

/// Where a session can go next: another of your Macs (or the hub), someone else as a file, or another
/// person on this host.
struct HandoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    @State private var targetMac: String?

    private var state: PackageState? { model.packages[sessionId] }
    private var otherMacs: [PairingInfo] {
        model.macs.filter { $0.id != model.activeMacId && model.supportsPeople(mac: $0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let package = state?.package {
                        ShareLink(item: SessionPackageFile(package: package),
                                  preview: SharePreview(package.title, image: Image(systemName: "shippingbox"))) {
                            Label("Send the file…", systemImage: "square.and.arrow.up")
                        }
                        Text(summary(package)).font(CDS.caption).foregroundStyle(CDS.textMuted)
                    } else if state?.loading == true {
                        HStack { ProgressView(); Text("Packing the session…").foregroundStyle(CDS.textMuted) }
                    } else {
                        Button("Pack it up", systemImage: "shippingbox") { model.exportSession(sessionId) }
                    }
                    if let error = state?.error { Text(error).font(CDS.caption).foregroundStyle(CDS.danger) }
                } header: { Text("As a file") } footer: {
                    Text("The transcript and the branch — its commits and uncommitted changes. Whoever opens the file in ClaudeRemote continues on their own Mac.")
                }
                if !otherMacs.isEmpty {
                    Section("Continue on another Mac") {
                        ForEach(otherMacs) { mac in
                            Button {
                                targetMac = mac.id
                                if let package = state?.package { model.importSession(package, into: mac.id) } else { model.exportSession(sessionId) }
                            } label: {
                                HStack {
                                    Label(mac.displayName, systemImage: "desktopcomputer")
                                    Spacer()
                                    if targetMac == mac.id, model.importResult == nil { ProgressView().controlSize(.small) }
                                }
                            }
                        }
                        if let result = model.importResult, result.macId == targetMac {
                            if let error = result.error {
                                Text(error).font(CDS.caption).foregroundStyle(CDS.danger)
                            } else if let id = result.sessionId {
                                Button("Open it there", systemImage: "arrow.up.forward.app") {
                                    model.switchTo(result.macId)
                                    model.present(id, kind: .agent)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                if !model.isMember, !model.hostUsers.isEmpty {
                    Section("Give it to someone on this Mac") {
                        ForEach(model.hostUsers) { user in
                            Button(user.name, systemImage: "person") {
                                model.giveSession(sessionId, to: user.id)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Hand over")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            if model.packages[sessionId]?.package == nil { model.exportSession(sessionId) }
            if !model.isMember { model.requestUsers() }
            model.importResult = nil
        }
        .onChange(of: state?.package) { _, package in
            if let package, let mac = targetMac, model.importResult == nil { model.importSession(package, into: mac) }
        }
    }

    private func summary(_ p: SessionPackage) -> String {
        var parts = [p.agent.label]
        if let branch = p.branch { parts.append("branch \(branch)") }
        if p.gitBundle != nil { parts.append("with its commits") }
        if p.patch != nil { parts.append("uncommitted changes") }
        if p.remoteURL == nil { parts.append("no remote — lands in a new folder") }
        return parts.joined(separator: " · ")
    }
}

/// A `.ccsession` file opened with the app: pick the Mac to continue on.
struct PackageImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let package: SessionPackage
    @State private var chosen: String?

    private var targets: [PairingInfo] { model.macs.filter { model.supportsPeople(mac: $0.id) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Session", value: package.title)
                    LabeledContent("From", value: package.from)
                    LabeledContent("Agent", value: package.agent.label)
                    if let remote = package.remoteURL { LabeledContent("Repository", value: (remote as NSString).lastPathComponent) }
                }
                Section("Continue on") {
                    if targets.isEmpty { Text("No paired Mac takes sessions yet — update its Host app.").foregroundStyle(CDS.textMuted) }
                    ForEach(targets) { mac in
                        Button {
                            chosen = mac.id
                            model.importSession(package, into: mac.id)
                        } label: {
                            HStack {
                                Label(mac.displayName, systemImage: "desktopcomputer")
                                Spacer()
                                if chosen == mac.id, model.importResult == nil { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    if let result = model.importResult {
                        if let error = result.error {
                            Text(error).font(CDS.caption).foregroundStyle(CDS.danger)
                        } else if let id = result.sessionId {
                            Button("Open it", systemImage: "arrow.up.forward.app") {
                                model.switchTo(result.macId)
                                model.present(id, kind: .agent)
                                model.incomingPackage = nil
                            }
                            if let cwd = result.cwd { Text(cwd).font(CDS.caption).foregroundStyle(CDS.textMuted) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Take over a session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.incomingPackage = nil } } }
        }
        .onAppear { model.importResult = nil }
    }
}

// MARK: - People on a host

/// The owner's list of people on the host, and inviting someone: they scan the QR (or open the link) to
/// pair with their own token. Members see only their own chats, sessions and tasks.
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var confirmRemove: HostUser?

    var body: some View {
        Form {
            if let invitation = model.invitation {
                Section {
                    VStack(spacing: 10) {
                        if let qr = PeopleView.qr(invitation.url) {
                            Image(uiImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                        }
                        Text("\(invitation.user.name) scans this in ClaudeRemote (Add Mac → Scan QR code).")
                            .font(CDS.caption).foregroundStyle(CDS.textSecondary).multilineTextAlignment(.center)
                        ShareLink(item: invitation.url) { Label("Send the link instead", systemImage: "square.and.arrow.up") }
                    }
                    .frame(maxWidth: .infinity)
                } header: { Text("Invitation") } footer: {
                    Text("The link is their key to this host — send it only to them.")
                }
            }
            Section {
                ForEach(model.hostUsers) { user in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name)
                        Text(user.lastSeenAt.map { "last seen \($0.formatted(.relative(presentation: .named)))" } ?? "not connected yet")
                            .font(CDS.caption).foregroundStyle(CDS.textMuted)
                        if user.ownClaudeLogin { Text("own Claude account").font(CDS.caption).foregroundStyle(CDS.success) }
                    }
                    .swipeActions { Button("Remove", role: .destructive) { confirmRemove = user } }
                }
                HStack {
                    TextField("Name", text: $name)
                    Button("Invite") {
                        model.inviteUser(name)
                        name = ""
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error = model.inviteError { Text(error).font(CDS.caption).foregroundStyle(CDS.danger) }
            } header: { Text("People") } footer: {
                Text("Each person pairs with their own key and sees only their own chats, sessions and tasks; their work goes in their own folder of the workspace. They can sign in their own Claude account so their use counts against it.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CDS.surface0)
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.invitation = nil
            model.requestUsers()
        }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let user = confirmRemove { model.removeUser(user.id) }
                confirmRemove = nil
            }
        } message: {
            Text("Their phone can no longer reach this host. Their sessions stay on the Mac.")
        }
    }

    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// A member's own Claude account on the host: the token from `claude setup-token`, so their sessions run
/// on their subscription, not the owner's.
struct MemberAccountView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""

    private var me: HostUser? { model.activeMacId.flatMap { model.hostByMac[$0]?.me } ?? model.host?.me }

    var body: some View {
        Form {
            Section {
                LabeledContent("You are", value: me?.name ?? "—")
                LabeledContent("Claude", value: me?.ownClaudeLogin == true ? "your own account" : "the host's account")
            }
            Section {
                SecureField("Token from claude setup-token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Use my account") { model.setOwnClaudeToken(token); token = "" }
                    .disabled(token.trimmingCharacters(in: .whitespaces).count < 20)
                if me?.ownClaudeLogin == true {
                    Button("Go back to the host's account", role: .destructive) { model.setOwnClaudeToken(nil) }
                }
            } header: { Text("Your Claude account") } footer: {
                Text("On a computer with the claude CLI, run `claude setup-token`, then paste the token here. It stays on the host and is used only for your sessions.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CDS.surface0)
        .navigationTitle("Your account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.requestUsers() }
    }
}

/// A package as a sheet item.
struct IncomingPackage: Identifiable {
    let package: SessionPackage
    var id: String { package.sessionId }
}
