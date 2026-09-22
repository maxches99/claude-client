import Foundation
import CryptoKit
import ClaudeRemoteCore

/// A link this phone published. The key lives only here (and in the link itself): lose the record
/// and the link still works for whoever has it, but this phone can no longer show or re-share it.
struct ShareRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let macId: String
    let sessionId: String
    let title: String
    /// The full link, key included.
    let url: String
    let createdAt: Date
    let expiresAt: Date

    var isExpired: Bool { expiresAt <= Date() }

    private static let key = "ccremote.shares"

    static func load() -> [ShareRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([ShareRecord].self, from: data) else { return [] }
        // Expired links are dead weight; keep a day of them so "it just expired" is still visible.
        return items.filter { $0.expiresAt > Date().addingTimeInterval(-86_400) }
    }

    static func save(_ items: [ShareRecord]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum ShareFailure: LocalizedError {
    case empty
    case mac(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .empty: return "There is nothing in this transcript to share yet."
        case .mac(let why): return why
        case .timeout: return "The Mac did not answer in time."
        }
    }
}

/// A terminal screen this phone shows, fed by the Mac's pseudo-terminal output.
@MainActor
@Observable
final class TerminalModel: Identifiable {
    let id: String
    var screen: TerminalScreen
    var exited = false
    var exitCode: Int32?
    /// The Mac has the shell (opened, or attached to an existing one).
    var connected = false

    init(id: String, cols: Int = 80, rows: Int = 24) {
        self.id = id
        self.screen = TerminalScreen(cols: cols, rows: rows)
    }

    /// Applies output; returns the replies the terminal owes the program (status queries).
    func feed(_ bytes: [UInt8]) -> [UInt8] { screen.feed(bytes) }
}

@MainActor
extension AppModel {

    // MARK: digest

    private func lastSeenKey(_ macId: String) -> String { "ccremote.lastSeen.\(macId)" }

    func lastSeen(_ macId: String) -> Date? {
        UserDefaults.standard.object(forKey: lastSeenKey(macId)) as? Date
    }

    /// The phone was looking at every connected Mac until now.
    func markSeen() {
        for (macId, link) in connections where link.status == .connected {
            UserDefaults.standard.set(Date(), forKey: lastSeenKey(macId))
        }
    }

    /// On (re)connecting after a while away, ask what happened meanwhile.
    func requestDigestIfAway(_ macId: String) {
        guard supportsMacTools(macId), let since = lastSeen(macId), Date().timeIntervalSince(since) > 10 * 60 else { return }
        connections[macId]?.send(.digest(since: since))
    }

    /// "Catch up" by hand: what happened on every connected Mac since `since`.
    func requestDigest(since: Date) {
        for (macId, link) in connections where link.status == .connected && supportsMacTools(macId) {
            link.send(.digest(since: since))
        }
    }

    func receiveDigest(_ report: DigestReport, from macId: String) {
        if report.isEmpty { digests[macId] = nil } else { digests[macId] = report }
    }

    func dismissDigests() {
        digests = [:]
        markSeen()
    }

    var digestSessionCount: Int { digests.values.reduce(0) { $0 + $1.sessions.count } }
    var digestTaskCount: Int { digests.values.reduce(0) { $0 + $1.tasks.count } }

    // MARK: handoff

    func requestHandoffTargets(_ sessionId: String) {
        sendMessage(.listHandoffTargets(sessionId: sessionId), session: sessionId)
    }

    func handoff(_ sessionId: String, to target: HandoffTarget) {
        handoffMessage = nil
        sendMessage(.handoff(sessionId: sessionId, targetId: target.id), session: sessionId)
    }

    // MARK: share links

    /// Renders the transcript, seals it with a fresh key, and has the Mac publish the ciphertext
    /// through its relay. Returns the full link (the key is its `#fragment`).
    func shareTranscript(_ sessionId: String, ttlSeconds: Int) async throws -> ShareRecord {
        guard let transcript = transcripts[sessionId], !transcript.items.isEmpty else { throw ShareFailure.empty }
        let summary = summary(for: sessionId)
        let agent = states[sessionId]?.agent ?? summary?.agent ?? .claude
        let title = summary?.title ?? "Transcript"
        var subtitle = [summary?.projectName, activeMac?.displayName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if subtitle.isEmpty { subtitle = agent.label }
        let html = TranscriptHTML.page(items: transcript.items,
                                       options: TranscriptExport.Options(title: title, subtitle: subtitle, agentName: agent.label))
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(Data(html.utf8), using: key)
        let payload = SharePayload(ivBase64: Data(sealed.nonce).base64EncodedString(),
                                   ciphertextBase64: (sealed.ciphertext + sealed.tag).base64EncodedString(),
                                   ttlSeconds: ttlSeconds)
        guard payload.ciphertextBase64.count <= SharePayload.maxBytes * 4 / 3 else { throw ShareFailure.mac("That transcript is too large to share as a link.") }
        guard let macId = activeMacId else { throw ShareFailure.mac("Not connected to a Mac.") }

        let info: ShareInfo = try await withThrowingTaskGroup(of: ShareInfo.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.shareWaiters[sessionId]?.resume(throwing: CancellationError())
                    self.shareWaiters[sessionId] = continuation
                    self.sendMessage(.shareTranscript(sessionId: sessionId, title: title, payload: payload), session: sessionId)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 40_000_000_000)
                throw ShareFailure.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ShareFailure.timeout }
            return first
        }
        let keyText = key.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = ShareRecord(id: info.id, macId: macId, sessionId: sessionId, title: title, url: info.url + "#" + keyText,
                                 createdAt: info.createdAt, expiresAt: info.expiresAt)
        shares.insert(record, at: 0)
        ShareRecord.save(shares)
        return record
    }

    func revokeShare(_ record: ShareRecord) {
        connections[record.macId]?.send(.revokeShare(shareId: record.id))
        shares.removeAll { $0.id == record.id }
        ShareRecord.save(shares)
    }

    func forgetExpiredShares() {
        shares.removeAll(where: \.isExpired)
        ShareRecord.save(shares)
    }

    var canShareLinks: Bool { supportsMacTools && host?.canShare == true }

    // MARK: terminals

    func requestTerminals() {
        guard supportsMacTools else { return }
        sendMessage(.listTerminals)
    }

    /// Opens a new shell on the Mac (Face ID-gated like running a command). Returns the screen model.
    func openTerminal(_ sessionId: String?, cols: Int, rows: Int, completion: @escaping (TerminalModel?) -> Void) {
        let start = { [self] in
            let id = UUID().uuidString.lowercased()
            let model = TerminalModel(id: id, cols: cols, rows: rows)
            model.connected = true
            terminalScreens[id] = model
            sendMessage(.terminalOpen(sessionId: sessionId, terminalId: id, cols: cols, rows: rows), session: sessionId)
            completion(model)
        }
        if requireBiometricsForApproval {
            Task { @MainActor in
                guard await Biometrics.authenticate(reason: "Open a terminal on the Mac") else { completion(nil); return }
                start()
            }
        } else {
            start()
        }
    }

    /// Shows a shell that is already running: the Mac replays its screen.
    func attachTerminal(_ info: TerminalInfo) -> TerminalModel {
        let model = terminalScreens[info.id] ?? TerminalModel(id: info.id, cols: info.cols, rows: info.rows)
        model.screen = TerminalScreen(cols: model.screen.cols, rows: model.screen.rows)   // the replay repaints it
        model.connected = true
        terminalScreens[info.id] = model
        sendMessage(.terminalAttach(terminalId: info.id, attached: true))
        return model
    }

    func detachTerminal(_ id: String) {
        terminalScreens[id]?.connected = false
        sendMessage(.terminalAttach(terminalId: id, attached: false))
    }

    func sendTerminal(_ id: String, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        sendMessage(.terminalInput(terminalId: id, dataBase64: Data(bytes).base64EncodedString()))
    }

    func resizeTerminal(_ id: String, cols: Int, rows: Int) {
        guard let model = terminalScreens[id], model.screen.cols != cols || model.screen.rows != rows else { return }
        model.screen.resize(cols: cols, rows: rows)
        sendMessage(.terminalResize(terminalId: id, cols: cols, rows: rows))
    }

    func closeTerminal(_ id: String) {
        sendMessage(.terminalClose(terminalId: id))
        terminals.removeAll { $0.id == id }
    }
}
