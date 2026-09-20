import Foundation
import ClaudeRemoteCore

/// What the phone keeps of a Mac between connections: the session list and the raw entries of the
/// transcripts it has opened, so the app opens to something useful with the Mac asleep or away.
/// Lives in Caches (per paired Mac); the system may purge it, and that is fine.
struct OfflineCache {
    let macId: String

    private var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ccremote", isDirectory: true).appendingPathComponent(macId, isDirectory: true)
    }
    private var sessionsURL: URL { directory.appendingPathComponent("sessions.json") }
    private func transcriptURL(_ id: String) -> URL {
        directory.appendingPathComponent("transcripts", isDirectory: true).appendingPathComponent(id + ".json")
    }

    private static let encoder = ProtocolCoding.encoder
    private static let decoder = ProtocolCoding.decoder

    func loadSessions() -> [SessionSummary] {
        guard let data = try? Data(contentsOf: sessionsURL) else { return [] }
        return (try? Self.decoder.decode([SessionSummary].self, from: data)) ?? []
    }

    func saveSessions(_ sessions: [SessionSummary]) {
        guard let data = try? Self.encoder.encode(sessions) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: sessionsURL, options: .atomic)
    }

    func loadTranscript(_ id: String) -> [JSONValue]? {
        guard let data = try? Data(contentsOf: transcriptURL(id)) else { return nil }
        return try? Self.decoder.decode([JSONValue].self, from: data)
    }

    func saveTranscript(_ id: String, entries: [JSONValue]) {
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: transcriptURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: transcriptURL(id), options: .atomic)
    }

    /// Keeps the cache from growing without bound: the newest `keep` transcripts stay.
    func prune(keep: Int = 30) {
        let dir = directory.appendingPathComponent("transcripts", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for url in sorted.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }
}
