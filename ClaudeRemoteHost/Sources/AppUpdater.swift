import AppKit
import CryptoKit
import ClaudeRemoteCore
import ClaudeRemoteDaemon

/// Updates the Host app from the newest GitHub release: downloads `ClaudeRemote-Host.zip`, checks it
/// against the release's `SHA256SUMS`, swaps the bundle in place and relaunches. Asked for from the
/// menu or from a phone.
final class AppUpdater: HostUpdater, @unchecked Sendable {
    static let repository = "maxches99/claude-client"
    static let asset = "ClaudeRemote-Host.zip"

    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var running = false

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    struct Release {
        var tag: String
        var page: String?
        var assets: [String: URL]
    }

    func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try? JSONValue.parse(data),
              let tag = json["tag_name"]?.string else { throw UpdateError.noRelease }
        var assets: [String: URL] = [:]
        for asset in json["assets"]?.array ?? [] {
            if let name = asset["name"]?.string, let url = asset["browser_download_url"]?.string.flatMap(URL.init(string:)) { assets[name] = url }
        }
        return Release(tag: tag, page: json["html_url"]?.string, assets: assets)
    }

    enum UpdateError: Error, CustomStringConvertible {
        case noRelease, noAsset, checksum, unpack(String), notWritable(String)
        var description: String {
            switch self {
            case .noRelease: return "Could not read the newest release from GitHub."
            case .noAsset: return "The release has no Mac app in it."
            case .checksum: return "The download does not match the release's checksum — nothing was changed."
            case .unpack(let why): return "Could not unpack the update: \(why)"
            case .notWritable(let dir): return "No permission to replace the app in \(dir) — update with brew or by hand."
            }
        }
    }

    func check() async -> HostUpdate {
        do {
            let release = try await latestRelease()
            let newer = HostUpdate.isNewer(release.tag, than: current)
            return HostUpdate(state: newer ? .available : .upToDate, current: current, latest: release.tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
                              notesURL: release.page)
        } catch {
            return HostUpdate(state: .failed, current: current, message: "\(error)")
        }
    }

    func update(progress: @escaping @Sendable (HostUpdate) -> Void) async {
        guard lock.withLock({ () -> Bool in if running { return false }; running = true; return true }) else {
            progress(HostUpdate(state: .updating, current: current, message: "An update is already running."))
            return
        }
        defer { lock.withLock { running = false } }
        let current = self.current
        do {
            let release = try await latestRelease()
            let latest = release.tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard HostUpdate.isNewer(release.tag, than: current) else {
                progress(HostUpdate(state: .upToDate, current: current, latest: latest))
                return
            }
            let bundle = Bundle.main.bundleURL
            let parent = bundle.deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: parent) else { throw UpdateError.notWritable(parent) }
            guard let zipURL = release.assets[Self.asset] else { throw UpdateError.noAsset }

            progress(HostUpdate(state: .updating, current: current, latest: latest, message: "Downloading \(release.tag)…"))
            log("update: downloading \(release.tag)")
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ccremote-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (zipTemp, _) = try await URLSession.shared.download(from: zipURL)
            let zip = work.appendingPathComponent(Self.asset)
            try FileManager.default.moveItem(at: zipTemp, to: zip)

            if let sumsURL = release.assets["SHA256SUMS"] {
                let (sums, _) = try await URLSession.shared.data(from: sumsURL)
                let expected = String(decoding: sums, as: UTF8.self).split(separator: "\n")
                    .first { $0.hasSuffix(Self.asset) }.map { String($0.split(separator: " ").first ?? "") }
                let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                guard let expected, expected == actual else { throw UpdateError.checksum }
            }

            progress(HostUpdate(state: .updating, current: current, latest: latest, message: "Installing…"))
            let unpacked = work.appendingPathComponent("app")
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            guard let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.unpack("no app in the archive") }
            _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

            // Swap the bundle once this process is gone, then open the new one.
            let script = """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.3; done
            /bin/rm -rf \(shell(bundle.path)).old
            /bin/mv \(shell(bundle.path)) \(shell(bundle.path)).old && /bin/mv \(shell(app.path)) \(shell(bundle.path)) && /bin/rm -rf \(shell(bundle.path)).old
            /usr/bin/open \(shell(bundle.path))
            /bin/rm -rf \(shell(work.path))
            """
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/sh")
            swap.arguments = ["-c", script]
            try swap.run()
            progress(HostUpdate(state: .updating, current: current, latest: latest, message: "Restarting into \(release.tag)…"))
            log("update: installing \(release.tag) and restarting")
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run { NSApp.terminate(nil) }
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
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateError.unpack(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }

    private func shell(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
