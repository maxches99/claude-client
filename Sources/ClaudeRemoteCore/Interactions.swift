import Foundation

/// The two permission requests that are really dialogs, not yes/no questions: `AskUserQuestion`
/// (the agent wants answers) and `ExitPlanMode` (the agent wants its plan approved). Both are
/// answered through the same `permission` reply, with `updatedInput` carrying the answers.
public enum AskUserQuestion {
    public static let toolName = "AskUserQuestion"

    public struct Option: Equatable, Sendable, Identifiable {
        public var label: String
        public var description: String
        public var id: String { label }
        public init(label: String, description: String = "") {
            self.label = label
            self.description = description
        }
    }

    public struct Question: Equatable, Sendable, Identifiable {
        public var question: String
        public var header: String
        public var options: [Option]
        public var multiSelect: Bool
        public var id: String { question }
        public init(question: String, header: String = "", options: [Option] = [], multiSelect: Bool = false) {
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    /// The questions in a tool input, in order; empty when the input is not an AskUserQuestion.
    public static func questions(in input: JSONValue) -> [Question] {
        (input["questions"]?.array ?? []).compactMap { q in
            guard let text = q["question"]?.string, !text.isEmpty else { return nil }
            let options = (q["options"]?.array ?? []).compactMap { o -> Option? in
                guard let label = o["label"]?.string, !label.isEmpty else { return nil }
                return Option(label: label, description: o["description"]?.string ?? "")
            }
            return Question(question: text, header: q["header"]?.string ?? "", options: options, multiSelect: q["multiSelect"]?.bool ?? false)
        }
    }

    /// The optional heading the agent put above the questions.
    public static func heading(in input: JSONValue) -> String? {
        let h = input["heading"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return h.isEmpty ? nil : h
    }

    /// Builds the `updatedInput` that answers the questions: the original input plus
    /// `answers: {question: "label" | "label, label"}` and, per question, an optional free-text
    /// `notes` annotation. A free-text answer that matches no option is passed as the answer itself
    /// ("Other"), which is how the CLI's own dialog reports a typed reply.
    public static func answeredInput(_ input: JSONValue, answers: [String: [String]], notes: [String: String] = [:]) -> JSONValue {
        var fields = input.object ?? [:]
        var answerFields: [String: JSONValue] = [:]
        for (question, picked) in answers where !picked.isEmpty {
            answerFields[question] = .string(picked.joined(separator: ", "))
        }
        fields["answers"] = .object(answerFields)
        let annotations = notes.compactMapValues { note -> JSONValue? in
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .object(["notes": .string(trimmed)])
        }
        if !annotations.isEmpty { fields["annotations"] = .object(annotations) }
        return .object(fields)
    }
}

public enum PlanReview {
    public static let toolName = "ExitPlanMode"

    /// The plan Markdown the agent wants approved (the CLI injects it from the plan file).
    public static func plan(in input: JSONValue) -> String? {
        let text = input["plan"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    public static func planFilePath(in input: JSONValue) -> String? {
        input["planFilePath"]?.string
    }

    /// The permission mode the CLI suggests switching to on approval (`setMode` in
    /// `permission_suggestions`), e.g. `acceptEdits` — shown as "Approve & accept edits".
    public static func suggestedMode(in suggestions: JSONValue?) -> String? {
        for s in suggestions?.array ?? [] where s["type"]?.string == "setMode" {
            if let mode = s["mode"]?.string { return mode }
        }
        return nil
    }
}

public extension PermissionRequest {
    var isQuestion: Bool { toolName == AskUserQuestion.toolName }
    var isPlanReview: Bool { toolName == PlanReview.toolName }
    /// Answering a question or reading a plan runs nothing on the Mac, so no Face ID gate applies.
    var runsCode: Bool { !isQuestion && !isPlanReview }
}
