import SwiftUI
import ClaudeRemoteDaemon
import ClaudeRemoteCore
import ClaudeCodeHost

/// The popover under the menu-bar icon: status, phones, a scannable QR and the main actions.
struct MenuPanel: View {
    @Bindable var model: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let update = model.update, update.state == .available || update.state == .updating || (update.state == .failed && update.latest != nil) {
                updateBanner(update)
                Divider()
            }
            if let legacy = model.legacyAgent, legacy.isLoaded {
                legacyBanner
                Divider()
            } else if case .failed(let why) = model.phase {
                failureBanner(why)
                Divider()
            } else if let status = model.status, case .failed(let why) = status.listener {
                failureBanner(why)
                Divider()
            }
            PhonesSection(model: model)
            Divider()
            if !model.recentPhoneWork.isEmpty {
                PhoneWorkSection(model: model)
                Divider()
            }
            qrSection
            Divider()
            claudeRow
            if model.status?.codex != nil {
                Divider()
                codexRow
            }
            Divider()
            toggles
            Divider()
            footer
        }
        .frame(width: 330)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 52)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .onAppear {
            model.refreshLoginItem()
            model.refreshLegacyAgent()
            model.refreshPhoneSessions()
        }
    }

    // MARK: sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(model.isHealthy ? Color.green : (model.phase == .starting ? Color.orange : Color.red))
                .frame(width: 9, height: 9)
                .offset(y: -1)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hostName).font(.headline)
                Text(model.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("v\(Daemon.version)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var legacyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("The old ccremote LaunchAgent is still running and holds the port.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Switch to the app") { model.takeOverLegacyAgent() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func failureBanner(_ why: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(why).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { model.restart() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var qrSection: some View {
        VStack(spacing: 8) {
            if let qr = model.qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 168, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 168, height: 168)
            }
            Text("Scan with ClaudeRemote on your iPhone")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Copy link") { model.copyPairingURL() }
                OpenWindowButton(id: WindowID.pairing) { Text("Open pairing…") }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func updateBanner(_ update: HostUpdate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: update.state == .failed ? "exclamationmark.triangle" : "arrow.down.circle.fill")
                .foregroundStyle(update.state == .failed ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(update.state == .updating ? (update.message ?? "Updating…") : "Version \(update.latest ?? "?") is out").font(.callout)
                Text(update.state == .failed ? (update.message ?? "The update failed") : "You have \(update.current)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if update.state == .updating {
                ProgressView().controlSize(.small)
            } else {
                Button("Update") { model.installUpdate() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var claudeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if let claude = model.status?.claude, !claude.installed {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude not installed").font(.callout)
                    Text("Codex sessions and chats work without it").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else if let claude = model.status?.claude {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude CLI \(claude.version ?? "…")").font(.callout)
                    Group {
                        if claude.loggedIn == true {
                            Text(claude.email.map { "Logged in as \($0)" } ?? "Logged in")
                        } else if claude.loggedIn == false {
                            Text("Not logged in").foregroundStyle(.orange)
                        } else {
                            Text("Checking login…")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if claude.loggedIn == false {
                    Button("Log in…") { model.logInToClaude() }.controlSize(.small)
                } else {
                    Button { model.refreshClaude() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Re-check the CLI login")
                }
            } else {
                Text("Claude CLI").font(.callout)
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Codex shares its login with the Codex desktop app, so there is nothing to log in here.
    private var codexRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if let codex = model.status?.codex {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex CLI \(codex.version ?? "…")").font(.callout)
                    Group {
                        if codex.loggedIn == true {
                            Text("Logged in (shared with the Codex app)")
                        } else if codex.loggedIn == false {
                            Text("Not logged in — run `codex login`").foregroundStyle(.orange)
                        } else {
                            Text("Checking login…")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) })) {
                HStack(spacing: 6) {
                    Text("Open at login")
                    if model.loginItemNeedsApproval {
                        Button("Allow in System Settings…") { LoginItem.openSystemSettings() }
                            .buttonStyle(.link).controlSize(.small)
                    }
                }
            }
            Toggle(isOn: $model.keepAwake) {
                HStack(spacing: 6) {
                    Text("Keep Mac awake while on power")
                    if model.keepAwake && !model.keepAwakeActive {
                        Text("(on battery now)").foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            OpenWindowButton(id: WindowID.settings) { Text("Settings…") }
            OpenWindowButton(id: WindowID.log) { Text("Log") }
            Button("Approvals…") { model.openApprovalLog() }
            Button(model.checkingUpdate ? "Checking…" : "Updates") { model.checkForUpdateNow() }
                .disabled(model.checkingUpdate || model.update?.state == .updating)
                .help("Check for a newer ClaudeRemote Host — it also looks every half hour")
            Spacer()
            Button("Quit") { model.quit() }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

extension HostModel {
    /// The last few phone sessions worth offering on the Mac: Claude ones not yet in Claude Desktop.
    var recentPhoneWork: [PhoneSessionRecord] {
        guard hasClaudeDesktop else { return [] }
        return Array(phoneSessions.filter { $0.agent == .claude && $0.openedInDesktop != true }.prefix(4))
    }
}

/// Sessions started on the phone, each one click away from Claude Desktop.
struct PhoneWorkSection: View {
    let model: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Started on the phone").font(.caption).foregroundStyle(.secondary)
            ForEach(model.recentPhoneWork) { session in
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble").foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title ?? "New session").font(.callout).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(session.projectName)
                            Text("·")
                            Text(session.updatedAt, style: .relative)
                            Text("ago")
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { model.openInClaudeDesktop(session.id) } label: { Image(systemName: "macwindow") }
                        .buttonStyle(.borderless)
                        .help("Continue in Claude Desktop (the phone lets go of it)")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Connected phones (live), otherwise the remembered pairings, otherwise a hint.
struct PhonesSection: View {
    let model: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.connectedPhones.isEmpty && model.pairedDevices.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "iphone.gen3").foregroundStyle(.secondary).frame(width: 16)
                    Text("No phone paired yet — scan the QR below.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(model.connectedPhones) { phone in
                HStack(spacing: 8) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .foregroundStyle(.green).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phone.displayName).font(.callout)
                        HStack(spacing: 4) {
                            Text("Connected · \(phone.route.label)")
                            Text("·")
                            Text(phone.since, style: .relative)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let deviceId = phone.deviceId {
                        Menu {
                            Button("Disconnect & block", role: .destructive) { model.blockDevice(deviceId, true) }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    Spacer()
                }
            }
            // Paired phones that are not connected right now.
            ForEach(model.pairedDevices.filter { device in
                !model.connectedPhones.contains { ($0.deviceId ?? "client:\($0.client)") == device.id }
            }) { device in
                HStack(spacing: 8) {
                    Image(systemName: device.blocked ? "iphone.gen3.slash" : "iphone.gen3").foregroundStyle(device.blocked ? .red : .secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.callout)
                        HStack(spacing: 4) {
                            Text(device.blocked ? "Blocked · last seen" : "Paired · last seen")
                            Text(device.lastSeen, style: .relative)
                            Text("ago")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        if device.blocked {
                            Button("Unblock") { model.blockDevice(device.id, false) }
                        } else {
                            Button("Block", role: .destructive) { model.blockDevice(device.id, true) }
                        }
                        Button("Forget") { model.forgetDevice(device.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
