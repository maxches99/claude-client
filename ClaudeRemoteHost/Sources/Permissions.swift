import AppKit
import ApplicationServices
import CoreGraphics
import Network
import Observation

/// The macOS privacy permissions an agent run from the phone can trip over. The CLI and everything it
/// spawns count as this app to TCC, so every "ClaudeRemote Host would like to…" alert blocks the agent
/// until someone clicks it at the Mac — this asks for all of them at once while the user is there.
///
/// An ad-hoc signed build gets a new identity with every update, and macOS forgets what it granted the
/// old one; that is why the answers are remembered per build (`buildStamp`) and the window comes back.
@MainActor
@Observable
final class Permissions {
    enum State: Equatable {
        case granted
        case denied
        /// Never asked on this build — the first agent that needs it would stop on an alert.
        case notAsked
        /// Can't be read without asking (App Management) — only System Settings shows it.
        case unknown
        /// An Automation target that is not running, so macOS can't ask about it yet.
        case notRunning
    }

    enum Kind: Equatable {
        case folder(String)
        case fullDisk
        case automation(bundleId: String)
        case localNetwork
        case screenRecording
        case accessibility
        case appManagement
    }

    struct Item: Identifiable, Equatable {
        var id: String
        var kind: Kind
        var title: String
        var why: String
        var symbol: String
        var state: State
    }

    private(set) var items: [Item] = []
    private(set) var granting = false

    /// Items the next agent could stop on: never asked on this build. Denials are the user's answer, and
    /// Full Disk Access is optional.
    var pendingCount: Int { items.filter { $0.state == .notAsked && $0.kind != .fullDisk }.count }
    var needsAttention: Bool { pendingCount > 0 }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let asked = "permissionsAsked"
        static let windowShownBuild = "permissionsWindowShownBuild"
    }

    init() {
        refresh()
    }

    // MARK: the list

    private static let folders: [(id: String, name: String, path: String, symbol: String)] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list = [
            ("documents", "Documents", home + "/Documents", "doc"),
            ("desktop", "Desktop", home + "/Desktop", "menubar.dock.rectangle"),
            ("downloads", "Downloads", home + "/Downloads", "arrow.down.circle"),
        ]
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: iCloud) { list.append(("icloud", "iCloud Drive", iCloud, "icloud")) }
        return list
    }()

    /// Apps agents drive with `osascript`. Finder and System Events are always offered; the rest only
    /// when installed.
    private static let automationTargets: [(bundleId: String, name: String)] = [
        ("com.apple.finder", "Finder"),
        ("com.apple.systemevents", "System Events"),
        ("com.apple.Terminal", "Terminal"),
        ("com.apple.dt.Xcode", "Xcode"),
        ("com.apple.iphonesimulator", "Simulator"),
    ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }

    func refresh() {
        let fullDisk = Self.hasFullDiskAccess
        var list: [Item] = []
        for folder in Self.folders {
            let state: State = fullDisk ? .granted : folderState(folder.id, path: folder.path)
            list.append(Item(id: "folder." + folder.id, kind: .folder(folder.path), title: folder.name,
                             why: "Agents read and write projects kept in \(folder.name).", symbol: folder.symbol, state: state))
        }
        list.append(Item(id: "fullDisk", kind: .fullDisk, title: "Full Disk Access",
                         why: "Optional. Covers every folder, external drives and other apps' data in one switch.",
                         symbol: "internaldrive", state: fullDisk ? .granted : (wasAsked("fullDisk") ? .denied : .notAsked)))
        for target in Self.automationTargets {
            list.append(Item(id: "automation." + target.bundleId, kind: .automation(bundleId: target.bundleId),
                             title: "Control \(target.name)", why: "Agents script \(target.name) with osascript.",
                             symbol: "applescript", state: automationState(target.bundleId)))
        }
        list.append(Item(id: "localNetwork", kind: .localNetwork, title: "Local Network",
                         why: "The phone finds this Mac on Wi‑Fi; agents reach dev servers and devices on the LAN.",
                         symbol: "network", state: localNetworkState))
        list.append(Item(id: "screenRecording", kind: .screenRecording, title: "Screen Recording",
                         why: "Screenshots for before/after checks and `screencapture` from agents.",
                         symbol: "rectangle.dashed.badge.record",
                         state: CGPreflightScreenCaptureAccess() ? .granted : (wasAsked("screenRecording") ? .denied : .notAsked)))
        list.append(Item(id: "accessibility", kind: .accessibility, title: "Accessibility",
                         why: "Agents click and type in other apps through System Events.",
                         symbol: "accessibility",
                         state: AXIsProcessTrusted() ? .granted : (wasAsked("accessibility") ? .denied : .notAsked)))
        list.append(Item(id: "appManagement", kind: .appManagement, title: "App Management",
                         why: "Agents install or replace apps in /Applications (a build with --install). macOS can't report it — check in Settings.",
                         symbol: "app.badge", state: .unknown))
        items = list
    }

    // MARK: asking

    /// Asks for everything askable in a row: the alerts come up one after another while the user is here.
    /// Automation is asked only for apps that are running (plus System Events, which is started for it).
    func grantAll() {
        guard !granting else { return }
        granting = true
        Task {
            for item in items where item.state == .notAsked || item.state == .notRunning {
                switch item.kind {
                case .fullDisk, .appManagement:
                    continue   // Settings-only; offered per row
                case .automation(let bundleId) where bundleId != "com.apple.systemevents" && !Self.isRunning(bundleId):
                    continue
                default:
                    await ask(item, openSettingsIfDenied: false)
                }
            }
            granting = false
            refresh()
        }
    }

    /// Asks for one item; one that was already denied (or can only be switched on there) opens its pane in
    /// System Settings instead, since macOS never asks twice.
    func grant(_ item: Item) {
        Task {
            await ask(item, openSettingsIfDenied: true)
            refresh()
        }
    }

    private func ask(_ item: Item, openSettingsIfDenied: Bool) async {
        if openSettingsIfDenied, item.state == .denied || item.state == .unknown {
            openSettings(for: item.kind)
            return
        }
        switch item.kind {
        case .folder(let path):
            // Listing the folder is what brings up the alert; the call waits for the answer.
            _ = await Task.detached { try? FileManager.default.contentsOfDirectory(atPath: path) }.value
            markAsked(item.id)
        case .fullDisk, .appManagement:
            markAsked(item.id)
            openSettings(for: item.kind)
        case .automation(let bundleId):
            await askAutomation(bundleId)
        case .localNetwork:
            _ = await Self.probeLocalNetwork()
            markAsked(item.id)
        case .screenRecording:
            markAsked(item.id)
            if !CGRequestScreenCaptureAccess() {
                // Shows its alert only once per build; after that it just says no.
                if openSettingsIfDenied { openSettings(for: item.kind) }
            }
        case .accessibility:
            markAsked(item.id)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    // MARK: folders

    private func folderState(_ id: String, path: String) -> State {
        // Listing an unanswered folder would bring the alert up by itself, so only look once asked.
        guard wasAsked("folder." + id) else { return .notAsked }
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil ? .granted : .denied
    }

    /// The user TCC database is readable only with Full Disk Access; reading it never prompts.
    static var hasFullDiskAccess: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    // MARK: automation

    private func automationState(_ bundleId: String) -> State {
        guard Self.isRunning(bundleId) else {
            // Not running: macOS can't answer, but a grant from earlier on this build still holds.
            return defaults.bool(forKey: Keys.asked + ".granted.automation." + bundleId + "." + Self.buildStamp) ? .granted : .notRunning
        }
        switch Self.automationStatus(bundleId, ask: false) {
        case noErr:
            defaults.set(true, forKey: Keys.asked + ".granted.automation." + bundleId + "." + Self.buildStamp)
            return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .notRunning
        }
    }

    /// Starts the app if needed (hidden, without taking focus), asks, and quits it again if it was started
    /// only for this.
    private func askAutomation(_ bundleId: String) async {
        var launched: NSRunningApplication?
        if !Self.isRunning(bundleId), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            launched = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            for _ in 0..<20 where !Self.isRunning(bundleId) {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        // Blocks until the user answers the alert.
        let status = await Task.detached { Self.automationStatus(bundleId, ask: true) }.value
        if status == noErr {
            defaults.set(true, forKey: Keys.asked + ".granted.automation." + bundleId + "." + Self.buildStamp)
        }
        if let launched, bundleId != "com.apple.finder" { launched.terminate() }
    }

    nonisolated private static func automationStatus(_ bundleId: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    // MARK: local network

    private var localNetworkState: State {
        // macOS 14 has no Local Network permission; on 15+ the daemon's own Bonjour advert asks at launch.
        guard #available(macOS 15, *) else { return .granted }
        guard wasAsked("localNetwork") else { return .notAsked }
        return defaults.object(forKey: Keys.asked + ".localNetworkDenied." + Self.buildStamp) as? Bool == true ? .denied : .granted
    }

    /// Browses for our own Bonjour service: that asks on first use, and a refusal comes back as a
    /// policy-denied DNS error.
    private static func probeLocalNetwork() async -> Bool {
        let denied = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let browser = NWBrowser(for: .bonjour(type: "_ccremote._tcp", domain: nil), using: .tcp)
            let queue = DispatchQueue(label: "ccremote.permissions.localnetwork")
            var finished = false
            let finish: (Bool) -> Void = { denied in
                guard !finished else { return }
                finished = true
                browser.cancel()
                done.resume(returning: denied)
            }
            browser.stateUpdateHandler = { state in
                if case .waiting(let error) = state, case .dns(let code) = error, code == -65570 { finish(true) }
                if case .failed = state { finish(false) }
            }
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { finish(false) }
            }
            browser.start(queue: queue)
            // Long enough for someone at the Mac to answer the alert.
            queue.asyncAfter(deadline: .now() + 15) { finish(false) }
        }
        UserDefaults.standard.set(denied, forKey: Keys.asked + ".localNetworkDenied." + buildStamp)
        return !denied
    }

    // MARK: settings panes

    func openSettings(for kind: Kind) {
        let anchor: String
        switch kind {
        case .folder: anchor = "Privacy_FilesAndFolders"
        case .fullDisk: anchor = "Privacy_AllFiles"
        case .automation: anchor = "Privacy_Automation"
        case .localNetwork: anchor = "Privacy_LocalNetwork"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .appManagement: anchor = "Privacy_AppBundles"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: per-build memory

    /// What TCC keys an ad-hoc signed app by changes with every build, so "asked" is remembered per build.
    static let buildStamp: String = {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        guard let exe = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path) else { return version }
        let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return "\(version)-\(Int(date))-\(size)"
    }()

    private func wasAsked(_ id: String) -> Bool {
        (defaults.stringArray(forKey: Keys.asked + "." + Self.buildStamp) ?? []).contains(id)
    }

    private func markAsked(_ id: String) {
        var asked = defaults.stringArray(forKey: Keys.asked + "." + Self.buildStamp) ?? []
        if !asked.contains(id) { asked.append(id) }
        defaults.set(asked, forKey: Keys.asked + "." + Self.buildStamp)
    }

    /// The window opens itself once per build when something was never asked.
    var shouldShowOnLaunch: Bool {
        needsAttention && defaults.string(forKey: Keys.windowShownBuild) != Self.buildStamp
    }

    func markWindowShown() {
        defaults.set(Self.buildStamp, forKey: Keys.windowShownBuild)
    }
}
