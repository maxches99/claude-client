import Foundation
import ClaudeRemoteCore

/// Something written on the phone while its Mac was out of reach, waiting to go out. Only what the
/// person typed is kept — prompts and new tasks. Approvals, simulator input and the like are about
/// the moment and are never replayed later.
struct OutboxItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case prompt, task }

    var id: String = UUID().uuidString
    var kind: Kind
    /// The session a prompt belongs to (nil for tasks).
    var sessionId: String?
    /// What the list shows: the prompt's text or the task's title.
    var preview: String
    var createdAt = Date()
    var message: ClientMessage

    static func == (a: OutboxItem, b: OutboxItem) -> Bool { a.id == b.id }
}

/// The outbox of one paired Mac, on disk so a prompt written on a plane survives the app being
/// killed. Application Support, not Caches: the system must not purge what hasn't been sent.
struct OutboxStore {
    let macId: String

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ccremote/outbox", isDirectory: true).appendingPathComponent(macId + ".json")
    }

    func load() -> [OutboxItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? ProtocolCoding.decoder.decode([OutboxItem].self, from: data)) ?? []
    }

    func save(_ items: [OutboxItem]) {
        if items.isEmpty { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? ProtocolCoding.encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

extension AppModel {
    /// Prompts and tasks waiting for the active Mac.
    var pendingOutbox: [OutboxItem] { activeMacId.flatMap { outboxByMac[$0] } ?? [] }

    func pendingPrompts(for sessionId: String) -> [OutboxItem] {
        guard let macId = macId(forSession: sessionId) ?? activeMacId else { return [] }
        return (outboxByMac[macId] ?? []).filter { $0.sessionId == sessionId }
    }

    /// True when the message went out now; false when it was parked in the outbox for later.
    @discardableResult
    func sendOrPark(_ message: ClientMessage, kind: OutboxItem.Kind, preview: String, session sessionId: String? = nil) -> Bool {
        let macId = sessionId.flatMap { self.macId(forSession: $0) } ?? activeMacId
        guard let macId else { return false }
        if let link = connections[macId], link.status == .connected {
            link.send(message)
            return true
        }
        outboxByMac[macId, default: []].append(OutboxItem(kind: kind, sessionId: sessionId, preview: preview, message: message))
        OutboxStore(macId: macId).save(outboxByMac[macId] ?? [])
        return false
    }

    func cancelOutboxItem(_ id: String) {
        for (macId, items) in outboxByMac where items.contains(where: { $0.id == id }) {
            let removed = items.first { $0.id == id }
            outboxByMac[macId] = items.filter { $0.id != id }
            OutboxStore(macId: macId).save(outboxByMac[macId] ?? [])
            // A parked task is also shown optimistically in the queue; take it out of there too.
            if removed?.kind == .task, case .addTask(let task)? = removed?.message {
                tasks.removeAll { $0.id == task.id }
            }
        }
    }

    func loadOutboxes() {
        for mac in macs {
            let items = OutboxStore(macId: mac.id).load()
            if !items.isEmpty { outboxByMac[mac.id] = items }
        }
    }

    /// Sends what is parked for `macId`, oldest first. Called once the Mac said welcome. Tasks go out
    /// at once. Prompts wait until their session is attached again: after a restart the Mac only knows a
    /// hosted session once something opens it, and the Mac handles frames concurrently, so a prompt sent
    /// right behind its `open` could still find no session. Everything written for one session goes as
    /// one message, which also keeps the order it was written in.
    func flushOutbox(_ macId: String) {
        guard let items = outboxByMac[macId], !items.isEmpty, let link = connections[macId] else { return }
        let taskItems = items.filter { $0.kind == .task }
        for item in taskItems { link.send(item.message) }
        if !taskItems.isEmpty {
            outboxByMac[macId] = items.filter { $0.kind != .task }
            OutboxStore(macId: macId).save(outboxByMac[macId] ?? [])
            noteOutboxSent(prompts: 0, tasks: taskItems.count)
        }
        let alreadyOpening = Set(openSessionIds)
        for sessionId in Set(items.compactMap(\.sessionId)) {
            outboxAwaitingAttach.insert(sessionId)
            if !alreadyOpening.contains(sessionId) {
                link.send(.open(sessionId: sessionId, since: transcripts[sessionId] != nil ? lastSeq[sessionId] : nil))
            }
        }
    }

    /// The Mac attached `sessionId` (history or catch-up arrived): its parked prompts can go now. Also
    /// retries prompts whose first attach failed, the next time that session is opened.
    func releaseParkedPrompts(_ sessionId: String, from macId: String) {
        outboxAwaitingAttach.remove(sessionId)
        guard let link = connections[macId], link.status == .connected else { return }
        let parked = (outboxByMac[macId] ?? []).filter { $0.sessionId == sessionId }
        guard let merged = OutboxItem.merged(parked) else { return }
        link.send(merged)
        outboxByMac[macId] = (outboxByMac[macId] ?? []).filter { $0.sessionId != sessionId }
        OutboxStore(macId: macId).save(outboxByMac[macId] ?? [])
        noteOutboxSent(prompts: parked.count, tasks: 0)
    }

    /// The Mac could not attach the session: its prompts stay parked (and on disk) for next time.
    func parkedSessionFailed(_ sessionId: String) {
        outboxAwaitingAttach.remove(sessionId)
    }

    private func noteOutboxSent(prompts: Int, tasks: Int) {
        let parts = [prompts > 0 ? (prompts == 1 ? "1 prompt" : "\(prompts) prompts") : nil,
                     tasks > 0 ? (tasks == 1 ? "1 task" : "\(tasks) tasks") : nil].compactMap { $0 }
        outboxNotice = "Sent \(parts.joined(separator: " and ")) written offline."
    }
}

extension OutboxItem {
    /// One prompt carrying every parked prompt of a session, in the order they were written.
    static func merged(_ items: [OutboxItem]) -> ClientMessage? {
        var sessionId: String?
        var texts: [String] = []
        var images: [InlineImage] = []
        var attachments: [Attachment] = []
        for item in items {
            guard case .prompt(let id, let text, let imgs, let files) = item.message else { continue }
            sessionId = id
            if !text.isEmpty { texts.append(text) }
            images += imgs
            attachments += files ?? []
        }
        guard let sessionId else { return nil }
        return .prompt(sessionId: sessionId, text: texts.joined(separator: "\n\n"), images: images,
                       attachments: attachments.isEmpty ? nil : attachments)
    }
}
