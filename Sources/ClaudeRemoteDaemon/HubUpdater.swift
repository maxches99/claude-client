#if os(Linux)
import Foundation
import ClaudeRemoteCore

/// Updates the Linux hub from the newest GitHub release: `ccremote-linux-x86_64.tar.gz` (the binary and
/// its VERSION), checked against the release's `.sha256`, swapped in next to the running binary; then the
/// process exits and systemd (`Restart=always`) starts the new one. Needs the install directory to be
/// writable by the service user (`scripts/deploy-linux-hub.sh` sets that up).
public final class HubUpdater: HostUpdater, @unchecked Sendable {
    static let repository = "maxches99/claude-client"
    static let asset = "ccremote-linux-x86_64.tar.gz"

    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var running = false

    public init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// The running binary, symlinks resolved.
    static var binaryPath: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
    }

    /// What the release that installed this binary wrote next to it.
    public static var installedVersion: String? {
        let dir = (binaryPath as NSString).deletingLastPathComponent
        let v = (try? String(contentsOfFile: dir + "/VERSION", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    private var current: String { HubUpdater.installedVersion ?? "0" }

    enum UpdateError: Error, CustomStringConvertible {
        case noRelease, noAsset, checksum, tool(String), notWritable(String)
        var description: String {
            switch self {
            case .noRelease: return "Could not read the newest release from GitHub."
            case .noAsset: return "The newest release has no hub build yet."
            case .checksum: return "The download does not match the release's checksum — nothing was changed."
            case .tool(let why): return why
            case .notWritable(let dir): return "The hub cannot write to \(dir) — redeploy it with scripts/deploy-linux-hub.sh once."
            }
        }
    }

    private struct Release { var tag: String; var page: String?; var assets: [String: String] }

    private func latestRelease() throws -> Release {
        let out = try run("/usr/bin/curl", ["-fsSL", "-H", "Accept: application/vnd.github+json", "--max-time", "20",
                                            "https://api.github.com/repos/\(HubUpdater.repository)/releases/latest"])
        guard let json = try? JSONValue.parse(Data(out.utf8)), let tag = json["tag_name"]?.string else { throw UpdateError.noRelease }
        var assets: [String: String] = [:]
        for asset in json["assets"]?.array ?? [] {
            if let name = asset["name"]?.string, let url = asset["browser_download_url"]?.string { assets[name] = url }
        }
        return Release(tag: tag, page: json["html_url"]?.string, assets: assets)
    }

    public func check() async -> HostUpdate {
        do {
            let release = try latestRelease()
            let latest = release.tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard release.assets[HubUpdater.asset] != nil else {
                return HostUpdate(state: .upToDate, current: current, latest: latest, notesURL: release.page, message: "The newest release has no hub build yet.")
            }
            return HostUpdate(state: HostUpdate.isNewer(release.tag, than: current) ? .available : .upToDate, current: current,
                              latest: latest, notesURL: release.page)
        } catch {
            return HostUpdate(state: .failed, current: current, message: "\(error)")
        }
    }

    public func update(progress: @escaping @Sendable (HostUpdate) -> Void) async {
        guard lock.withLock({ () -> Bool in if running { return false }; running = true; return true }) else {
            progress(HostUpdate(state: .updating, current: current, message: "An update is already running."))
            return
        }
        defer { lock.withLock { running = false } }
        let current = self.current
        do {
            let release = try latestRelease()
            let latest = release.tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard HostUpdate.isNewer(release.tag, than: current) else {
                progress(HostUpdate(state: .upToDate, current: current, latest: latest))
                return
            }
            guard let url = release.assets[HubUpdater.asset], let sumURL = release.assets[HubUpdater.asset + ".sha256"] else { throw UpdateError.noAsset }
            let binary = HubUpdater.binaryPath
            let dir = (binary as NSString).deletingLastPathComponent
            guard FileManager.default.isWritableFile(atPath: dir) else { throw UpdateError.notWritable(dir) }

            progress(HostUpdate(state: .updating, current: current, latest: latest, message: "Downloading \(release.tag)…"))
            log("update: downloading \(release.tag)")
            let work = dir + "/.update-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: work) }
            let tarball = work + "/" + HubUpdater.asset
            try run("/usr/bin/curl", ["-fsSL", "--max-time", "600", "-o", tarball, url])
            let expected = try run("/usr/bin/curl", ["-fsSL", "--max-time", "30", sumURL]).split(separator: " ").first.map(String.init) ?? ""
            let actual = try run("/usr/bin/sha256sum", [tarball]).split(separator: " ").first.map(String.init) ?? ""
            guard !expected.isEmpty, expected == actual else { throw UpdateError.checksum }

            progress(HostUpdate(state: .updating, current: current, latest: latest, message: "Installing…"))
            try run("/usr/bin/tar", ["-xzf", tarball, "-C", work])
            let fresh = work + "/ccremote"
            guard FileManager.default.isExecutableFile(atPath: fresh) else { throw UpdateError.tool("The archive has no ccremote binary.") }
            // Rename over the running binary: the old inode lives on until this process exits.
            guard rename(fresh, binary) == 0 else { throw UpdateError.tool("Could not replace the binary (errno \(errno)).") }
            try? latest.write(toFile: dir + "/VERSION", atomically: true, encoding: .utf8)

            progress(HostUpdate(state: .updating, current: current, latest: latest, message: "Restarting into \(release.tag)…"))
            log("update: installed \(release.tag), restarting")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            exit(0)
        } catch {
            log("update failed: \(error)")
            progress(HostUpdate(state: .failed, current: current, message: "\(error)"))
        }
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.tool("\((tool as NSString).lastPathComponent) failed: \(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
