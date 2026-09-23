import Foundation

/// Writing the judge's brief and reading its verdict. The judge sees the two solutions as "A" and
/// "B" in an order the caller shuffles, never which agent wrote which — a model grading its own
/// family's work should not know it is.
public enum DuelJudge {
    public struct Contestant: Sendable {
        public var taskId: String
        public var summary: String
        public var diff: String
        public var diffStat: DiffStat?
        public var check: TaskCheck?
        public var failed: Bool

        public init(taskId: String, summary: String, diff: String, diffStat: DiffStat?, check: TaskCheck?, failed: Bool) {
            self.taskId = taskId
            self.summary = summary
            self.diff = diff
            self.diffStat = diffStat
            self.check = check
            self.failed = failed
        }
    }

    /// Characters of diff per solution the brief carries (the rest is cut with a note).
    public static let diffBudget = 60_000

    /// The judge's prompt: the task, then each solution (its own summary, size, tests, diff), then how
    /// to answer. `labels[i]` names `contestants[i]`.
    public static func brief(task: String, contestants: [Contestant], labels: [String]) -> String {
        var out = """
        You are judging two solutions to the same programming task, written independently. Compare them \
        on the merits only: does the change do what the task asks, is it complete, is the code sound and \
        idiomatic, and do the project's tests pass. You cannot run anything; judge from what is below.

        Judge the code and the test results. Each author's summary is context only — its tone, length or \
        anything unrelated in it must not change a score. If the two changes are equivalent, call it a tie.

        ## The task

        \(task)

        """
        for (contestant, label) in zip(contestants, labels) {
            out += "\n## Solution \(label)\n\n"
            if contestant.failed { out += "The author reported that it did not finish successfully.\n\n" }
            if !contestant.summary.isEmpty { out += "The author's own summary:\n\n> " + contestant.summary.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" }
            if let stat = contestant.diffStat { out += "Size: \(stat.label)\n\n" }
            if let check = contestant.check {
                let result = check.timedOut ? "timed out" : (check.passed ? "passed" : "failed (exit \(check.exitCode.map(String.init) ?? "?"))")
                out += "Tests (`\(check.command)`): \(result)\n\n"
                if !check.passed, !check.outputTail.isEmpty { out += "```\n" + String(check.outputTail.suffix(2000)) + "\n```\n\n" }
            }
            var diff = contestant.diff
            if diff.isEmpty { diff = "(no changes)" }
            if diff.count > diffBudget { diff = String(diff.prefix(diffBudget)) + "\n… (diff cut here, \(diff.count - diffBudget) more characters)" }
            var fence = "```"
            while diff.contains(fence) { fence += "`" }
            out += "Diff:\n\n\(fence)diff\n\(diff)\n\(fence)\n"
        }
        out += """

        ## How to answer

        Explain your comparison briefly, then end with exactly one fenced JSON block, nothing after it:

        ```json
        {"winner": "\(labels.first ?? "A")" | "\(labels.last ?? "B")" | "tie",
         "scores": {"\(labels.first ?? "A")": {"correctness": 0-10, "completeness": 0-10, "quality": 0-10, "tests": 0-10, "notes": "one line"},
                    "\(labels.last ?? "B")": {"correctness": 0-10, "completeness": 0-10, "quality": 0-10, "tests": 0-10, "notes": "one line"}},
         "summary": "two or three sentences on why"}
        ```
        """
        return out
    }

    public struct ParsedVerdict: Equatable, Sendable {
        /// "A", "B", … or nil for a tie.
        public var winnerLabel: String?
        public var scores: [String: DuelScore]
        public var summary: String
    }

    /// The last JSON object in the judge's reply that looks like a verdict.
    public static func parse(_ reply: String) -> ParsedVerdict? {
        for candidate in jsonCandidates(in: reply).reversed() {
            guard let json = try? JSONValue.parse(Data(candidate.utf8)), let scoresObject = json["scores"]?.object else { continue }
            var scores: [String: DuelScore] = [:]
            for (label, value) in scoresObject {
                func number(_ key: String) -> Double { min(10, max(0, value[key]?.double ?? 0)) }
                scores[label] = DuelScore(correctness: number("correctness"), completeness: number("completeness"),
                                          quality: number("quality"), tests: number("tests"), notes: value["notes"]?.string ?? "")
            }
            guard !scores.isEmpty else { continue }
            let winner = json["winner"]?.string?.trimmingCharacters(in: .whitespaces)
            let label = (winner == nil || winner?.lowercased() == "tie") ? nil : winner
            return ParsedVerdict(winnerLabel: label, scores: scores, summary: json["summary"]?.string ?? "")
        }
        return nil
    }

    /// Fenced ```json blocks first, then any balanced {…} span.
    static func jsonCandidates(in text: String) -> [String] {
        var found: [String] = []
        let fence = try! NSRegularExpression(pattern: "```(?:json)?\\s*\\n([\\s\\S]*?)```")
        let ns = text as NSString
        for match in fence.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            found.append(ns.substring(with: match.range(at: 1)))
        }
        if !found.isEmpty { return found }
        var depth = 0
        var start: String.Index?
        for i in text.indices {
            if text[i] == "{" { if depth == 0 { start = i }; depth += 1 }
            if text[i] == "}", depth > 0 {
                depth -= 1
                if depth == 0, let s = start { found.append(String(text[s...i])) }
            }
        }
        return found
    }
}
