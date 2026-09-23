#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore

/// The digest, delivered: every day at a time set from the phone, what happened since the last one goes
/// to Telegram — read on the lock screen before the app is even opened.
extension SessionManager {
    public func currentDigestSchedule() -> DigestSchedule {
        var schedule = digestSchedule
        schedule.canSend = notifier?.canSendTelegram ?? false
        return schedule
    }

    public func setDigestSchedule(minutes: Int?) -> DigestSchedule {
        digestSchedule.minutes = minutes.map { min(max(0, $0), 24 * 60 - 1) }
        saveDigestSchedule()
        log(digestSchedule.minutes.map { "digest: daily at \(String(format: "%02d:%02d", $0 / 60, $0 % 60))" } ?? "digest: off")
        return currentDigestSchedule()
    }

    public func sendDigestNow() async throws -> DigestSchedule {
        try await deliverDigest()
        return currentDigestSchedule()
    }

    func loadDigestSchedule() {
        if let path = digestSchedulePath, let data = FileManager.default.contents(atPath: path),
           let stored = try? ProtocolCoding.decoder.decode(DigestSchedule.self, from: data) {
            digestSchedule = stored
        }
        startDigestTimer()
    }

    func saveDigestSchedule() {
        guard let path = digestSchedulePath, let data = try? ProtocolCoding.encoder.encode(digestSchedule) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func startDigestTimer() {
        digestTimer?.cancel()
        digestTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                await self.digestTick()
            }
        }
    }

    /// Sends when today's time has come and today's digest has not gone out yet.
    func digestTick(now: Date = Date()) async {
        guard let due = SessionManager.digestDue(schedule: digestSchedule, now: now) else { return }
        do {
            try await deliverDigest(now: now)
        } catch {
            // Try again at the next tick only for a while: stamp it so a broken bot doesn't retry forever.
            digestSchedule.lastSentAt = due
            saveDigestSchedule()
            log("digest: \(error)")
        }
    }

    /// Today's send time when it has passed and nothing was sent since; nil otherwise.
    static func digestDue(schedule: DigestSchedule, now: Date, calendar: Calendar = .current) -> Date? {
        guard let minutes = schedule.minutes else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        guard let today = calendar.date(from: components), now >= today else { return nil }
        // Only today's slot: a Mac that slept through it sends when it wakes, but not a day late.
        guard now.timeIntervalSince(today) < 12 * 3600 else { return nil }
        if let last = schedule.lastSentAt, last >= today { return nil }
        return today
    }

    func deliverDigest(now: Date = Date()) async throws {
        guard let notifier, notifier.canSendTelegram else {
            throw GitError.refused("Telegram is not set up on this host (bot token and chat in Settings, or --telegram-token / --telegram-chat).")
        }
        let since = digestSchedule.lastSentAt ?? now.addingTimeInterval(-24 * 3600)
        let report = digest(since: since)
        let recentDuels = duels.filter { ($0.decidedAt ?? $0.createdAt) > since }
        let text = DigestTelegram.message(report, hostName: SessionManager.digestHostName, duels: recentDuels, now: now)
        try await notifier.sendTelegramHTML(text)
        digestSchedule.lastSentAt = now
        saveDigestSchedule()
        log("digest: sent (\(report.sessions.count) sessions, \(report.tasks.count) tasks)")
    }

    static var digestHostName: String {
        HostPaths.machineName
    }
}
#endif
