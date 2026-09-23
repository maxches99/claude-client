import Foundation

/// The digest as a Telegram message (HTML parse mode): what is waiting first, then what moved, then the
/// queue and the duels — short enough for a phone's lock screen to be useful, cut to Telegram's limit.
public enum DigestTelegram {
    public static let limit = 4096

    public static func message(_ report: DigestReport, hostName: String, duels: [Duel] = [], now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(report.since, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        var lines: [String] = ["☀️ <b>\(escape(hostName))</b> — since \(f.string(from: report.since))"]

        let waiting = report.sessions.filter(\.waiting)
        let moved = report.sessions.filter { !$0.waiting }
        if report.isEmpty && duels.isEmpty {
            lines.append("")
            lines.append("Quiet night: nothing moved.")
            return lines.joined(separator: "\n")
        }
        if !waiting.isEmpty {
            lines.append("")
            lines.append("⏳ <b>Waiting for you (\(waiting.count))</b>")
            for item in waiting.prefix(8) { lines.append("• " + sessionLine(item)) }
        }
        if !moved.isEmpty {
            lines.append("")
            lines.append("🛠 <b>Worked on (\(moved.count))</b>")
            for item in moved.prefix(10) {
                lines.append("• " + sessionLine(item))
                if let reply = item.lastReply, !reply.isEmpty { lines.append("   <i>" + escape(plain(reply, max: 160)) + "</i>") }
            }
            if moved.count > 10 { lines.append("… and \(moved.count - 10) more") }
        }
        if !report.tasks.isEmpty {
            lines.append("")
            lines.append("📋 <b>Tasks</b>")
            for task in report.tasks.prefix(10) {
                let mark = task.status == .failed ? "❌" : (task.status == .cancelled ? "⏹" : "✅")
                var line = "\(mark) \(escape(plain(task.title, max: 80)))"
                if let pr = task.pullRequestURL, let url = URL(string: pr) { line += " — <a href=\"\(escape(url.absoluteString))\">PR</a>" }
                else if task.status == .failed, let error = task.error { line += " — " + escape(plain(error, max: 90)) }
                lines.append(line)
            }
        }
        let decided = duels.filter { $0.status == .decided || $0.status == .failed }
        if !decided.isEmpty {
            lines.append("")
            lines.append("⚔️ <b>Duels</b>")
            for duel in decided.prefix(5) { lines.append(duelLine(duel)) }
        }
        let stopped = report.processes.filter { ($0.exitCode ?? 0) != 0 }
        if !stopped.isEmpty {
            lines.append("")
            lines.append("⚠️ <b>Processes that failed</b>")
            for process in stopped.prefix(5) { lines.append("• <code>\(escape(plain(process.displayName, max: 60)))</code> exit \(process.exitCode.map(String.init) ?? "?")") }
        }
        var text = lines.joined(separator: "\n")
        if text.count > limit {
            // Cut at a line boundary; an unclosed tag would make Telegram reject the whole message.
            var kept: [String] = []
            var size = 40
            for line in lines {
                if size + line.count + 1 > limit { break }
                kept.append(line)
                size += line.count + 1
            }
            text = kept.joined(separator: "\n") + "\n… (cut — open the app for the rest)"
        }
        return text
    }

    static func sessionLine(_ item: DigestItem) -> String {
        var parts: [String] = []
        if item.prompts > 0 { parts.append("\(item.prompts) prompt\(item.prompts == 1 ? "" : "s")") }
        if item.fileCount > 0 { parts.append("\(item.fileCount) file\(item.fileCount == 1 ? "" : "s")") }
        if item.errors > 0 { parts.append("\(item.errors) error\(item.errors == 1 ? "" : "s")") }
        let place = item.kind == .chat ? "chat" : item.projectName
        return "<b>\(escape(plain(item.title, max: 70)))</b> · \(escape(place))" + (parts.isEmpty ? "" : " — " + parts.joined(separator: ", "))
    }

    static func duelLine(_ duel: Duel) -> String {
        let title = escape(plain(duel.title, max: 60))
        guard duel.status == .decided, let verdict = duel.verdict else { return "• \(title): no verdict" + (duel.error.map { " — " + escape(plain($0, max: 80)) } ?? "") }
        let totals = duel.taskIds.compactMap { verdict.scores[$0]?.total }.map { String(format: "%.1f", $0) }.joined(separator: " vs ")
        let outcome = verdict.winnerTaskId == nil ? "tie" : "winner decided"
        return "• \(title): \(outcome) (\(totals))"
    }

    /// Markdown down to plain words, on one line, shortened.
    static func plain(_ text: String, max: Int) -> String {
        var s = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`", "~~", "#"] { s = s.replacingOccurrences(of: mark, with: "") }
        s = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return s.count > max ? String(s.prefix(max)) + "…" : s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
