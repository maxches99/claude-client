import AppKit
import Observation
import ClaudeRemoteDaemon
import ClaudeRemoteCore
import ClaudeCodeHost

/// Owns the daemon and everything the menu-bar UI shows: its status, the pairing QR, the saved
/// config, login-item and keep-awake state, and the legacy LaunchAgent (if one is installed).
@MainActor
@Observable
final class HostModel {
    enum Phase: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .stopped
    private(set) var status: DaemonStatus?
    private(set) var config: DaemonConfig
    private(set) var qrImage: NSImage?
    private(set) var legacyAgent: LegacyLaunchAgent.Info?
    private(set) var loginItemEnabled = LoginItem.isEnabled
    private(set) var loginItemNeedsApproval = LoginItem.needsApproval
    private(set) var keepAwakeActive = false
    /// Transient message for the UI (copied, error…), cleared automatically.
    private(set) var toast: String?
    private(set) var recentLog: [String] = []
    /// Work sessions started from the phone, newest first (refreshed when the panel opens).
    private(set) var phoneSessions: [PhoneSessionRecord] = []
    /// The newest release against this build, and an update in progress.
    private(set) var update: HostUpdate?
    private var updater: AppUpdater?
    private(set) var checkingUpdate = false

    var keepAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: Keys.keepAwake)
            awake.enabled = keepAwake
        }
    }

    private enum Keys {
        static let keepAwake = "keepAwake"
        static let pairingWindowShown = "pairingWindowShown"
    }

    private var daemon: Daemon?
    private let log = FileLog()
    private let awake = KeepAwake()
    private var toastTask: Task<Void, Never>?

    init() {
        config = DaemonConfig.load()
        keepAwake = UserDefaults.standard.object(forKey: Keys.keepAwake) as? Bool ?? true
        legacyAgent = LegacyLaunchAgent.detect()
        // First run on a Mac that used the LaunchAgent: adopt its flags (relay, notifications…).
        if !DaemonConfig.exists(), let legacy = legacyAgent {
            config = legacy.config
            try? config.save()
            log.write("imported settings from the ccremote LaunchAgent")
        }
        awake.enabled = keepAwake
        keepAwakeActive = awake.active
        awake.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.keepAwakeActive = self.awake.active
            }
        }
        recentLog = log.recent
        log.onLine = { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recentLog.append(line)
                if self.recentLog.count > 300 { self.recentLog.removeFirst(self.recentLog.count - 300) }
            }
        }
        let updater = AppUpdater(log: log.write)
        self.updater = updater
        HostControl.shared.updater = updater
        start()
        Task { [weak self] in
            // Look for a new release now and every half hour.
            while !Task.isCancelled {
                await self?.checkForUpdate()
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            }
        }
    }

    // MARK: updates

    func checkForUpdate() async {
        guard let updater else { return }
        let result = await updater.check()
        if update?.state != .updating { update = result }
    }

    /// "Check for updates" from the menu: asks now and says what it found.
    func checkForUpdateNow() {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        Task {
            await checkForUpdate()
            checkingUpdate = false
            switch update?.state {
            case .upToDate?: show("You have the newest version (\(update?.current ?? "?")).")
            case .failed?: show(update?.message ?? "Could not check for updates.")
            default: break   // .available shows its own banner with Update
            }
        }
    }

    func installUpdate() {
        guard let updater else { return }
        Task {
            await updater.update { [weak self] progress in
                Task { @MainActor [weak self] in self?.update = progress }
            }
        }
    }

    /// The relay this Mac is on, as a link another Mac (through a phone) can join with.
    var relaySetup: RelaySetup? {
        guard config.relayEnabled, let url = config.relayURL, let secret = config.relaySecret, !secret.isEmpty else { return nil }
        return RelaySetup(url: url, secret: secret)
    }

    // MARK: derived

    var hostName: String { daemon?.serviceName ?? Host.current().localizedName ?? "Mac" }
    var connectedPhones: [PhoneLink] { status?.phones ?? [] }
    var pairedDevices: [PairedDevice] { status?.paired ?? [] }
    var hasEverPaired: Bool { !pairedDevices.isEmpty }
    var pairingURLString: String? { status?.pairing.absoluteString }

    /// One-line summary for the panel header.
    var headline: String {
        switch phase {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .failed(let why): return why
        case .running:
            guard let status else { return "Starting…" }
            switch status.listener {
            case .failed(let why): return why
            case .starting, .stopped: return "Starting…"
            case .listening(let port):
                var parts = ["\(status.pairing.scheme)://…:\(port)"]
                switch status.relay {
                case .off: break
                case .connected: parts.append("relay online")
                case .connecting: parts.append("relay connecting…")
                case .waiting: parts.append("relay waiting for network")
                case .failed: parts.append("relay unreachable")
                }
                return parts.joined(separator: " · ")
            }
        }
    }

    var isHealthy: Bool {
        guard phase == .running, let status, status.isListening else { return false }
        if case .failed = status.relay { return false }
        return true
    }

    /// Menu-bar glyph: waves when a phone is connected, plain when paired-but-away, slashed on failure.
    var menuSymbol: String {
        if !isHealthy { return "iphone.gen3.slash" }
        return connectedPhones.isEmpty ? "iphone.gen3" : "iphone.gen3.radiowaves.left.and.right"
    }

    /// The pairing window opens itself on the very first launch, so a fresh install is not just a
    /// new icon in the menu bar.
    var shouldShowPairingOnLaunch: Bool {
        !UserDefaults.standard.bool(forKey: Keys.pairingWindowShown) && !hasEverPaired
    }

    func markPairingShown() {
        UserDefaults.standard.set(true, forKey: Keys.pairingWindowShown)
    }

    // MARK: lifecycle

    func start() {
        guard daemon == nil else { return }
        phase = .starting
        do {
            let d = try Daemon(config: config, log: log.write)
            d.onStatus = { [weak self] status in
                Task { @MainActor [weak self] in self?.apply(status) }
            }
            // A phone set the relay: config.json has it, so reload and start over.
            d.onRestartRequest = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.config = DaemonConfig.load()
                    self.log.write("settings changed from a phone — restarting")
                    self.restart()
                }
            }
            daemon = d
            apply(d.status)
            try d.start()
            phase = .running
            log.write("ClaudeRemote Host \(Daemon.version) started")
        } catch {
            daemon = nil
            phase = .failed("\(error)")
            log.write("start failed: \(error)")
        }
    }

    func stop() async {
        guard let d = daemon else { return }
        daemon = nil
        await d.stop()
        phase = .stopped
        status = nil
    }

    func restart() {
        Task {
            await stop()
            start()
        }
    }

    /// Saves and restarts with the new settings. Phone-hosted CLI sessions end (they can be resumed).
    func apply(_ newConfig: DaemonConfig) {
        do {
            try newConfig.save()
        } catch {
            show("Could not save settings: \(error.localizedDescription)")
            return
        }
        config = newConfig
        restart()
    }

    private func apply(_ status: DaemonStatus) {
        let previousURL = self.status?.pairing.absoluteString
        self.status = status
        if qrImage == nil || previousURL != status.pairing.absoluteString {
            qrImage = QRImage.render(status.pairing.absoluteString, scale: 8, quiet: 2)
        }
    }

    // MARK: actions

    func rotateToken() {
        daemon?.rotateToken()
        show("New pairing token — scan the QR again on each phone")
    }

    func copyPairingURL() {
        guard let url = pairingURLString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        show("Pairing link copied")
    }

    func revealPairingImage() {
        guard let daemon, daemon.writePairingImage() else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: daemon.pairingImagePath))
    }

    func openLog() {
        NSWorkspace.shared.open(log.fileURL)
    }

    func openApprovalLog() {
        guard let daemon else { return }
        let path = daemon.approvalLogPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func blockDevice(_ id: String, _ blocked: Bool) {
        daemon?.setDeviceBlocked(id, blocked)
        show(blocked ? "Phone blocked — it can't connect until unblocked" : "Phone unblocked")
    }

    func forgetDevice(_ id: String) {
        daemon?.forgetDevice(id)
    }

    /// Claude Desktop is installed, so phone sessions can be continued there.
    var hasClaudeDesktop: Bool { SessionManager.applicationPath("Claude") != nil }

    func refreshPhoneSessions() {
        guard let manager = daemon?.manager else { return }
        Task { phoneSessions = await manager.recentPhoneSessions() }
    }

    /// Imports a phone session into Claude Desktop's Code tab and opens it there.
    func openInClaudeDesktop(_ id: String) {
        guard let manager = daemon?.manager else { return }
        Task {
            do {
                try await manager.openInClaudeDesktop(sessionId: id)
            } catch {
                show("\(error)")
            }
            phoneSessions = await manager.recentPhoneSessions()
        }
    }

    func refreshClaude() {
        daemon?.refreshClaudeStatusInBackground()
    }

    /// `claude auth login` is interactive (opens the browser, waits), so run it in Terminal:
    /// opening a `.command` file does that without needing Automation permission.
    func logInToClaude() {
        guard let daemon else { return }
        let script = """
        #!/bin/sh
        echo "Logging the Claude CLI in for ClaudeRemote Host…"
        \(daemon.loginCommand)
        echo
        echo "Done — you can close this window. ClaudeRemote Host re-checks the login itself."
        """
        let path = daemon.supportDirectory + "/claude-login.command"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            // Poll the login state for a couple of minutes while the user works through the browser flow.
            Task { [weak self] in
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self else { return }
                    self.refreshClaude()
                    if self.status?.claude.loggedIn == true { return }
                }
            }
        } catch {
            show("Could not start login: \(error.localizedDescription)")
        }
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
        } catch {
            show("Login item: \(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        loginItemEnabled = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.needsApproval
    }

    /// Unloads the old LaunchAgent (which holds the port) and starts the in-app daemon once the
    /// port is free — the old daemon shuts its CLI sessions down before it exits, which takes a moment.
    func takeOverLegacyAgent() {
        do {
            try LegacyLaunchAgent.disable()
            log.write("disabled the ccremote LaunchAgent")
        } catch {
            show("Could not disable the LaunchAgent: \(error.localizedDescription)")
        }
        legacyAgent = LegacyLaunchAgent.detect()
        Task {
            for _ in 0..<20 where LegacyLaunchAgent.isLoaded() {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await stop()
                start()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if status?.isListening == true { return }
                log.write("port still busy after takeover (attempt \(attempt))")
            }
        }
    }

    func refreshLegacyAgent() {
        legacyAgent = LegacyLaunchAgent.detect()
    }

    func quit() {
        Task {
            await stop()
            NSApp.terminate(nil)
        }
    }

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
