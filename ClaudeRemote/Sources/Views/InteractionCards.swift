import SwiftUI
import ClaudeRemoteCore

// MARK: - AskUserQuestion

/// The agent's questions as a form: options as tappable chips (one or several per question), an
/// "Other" field for a typed answer, and notes. `compact` shows one question at a time — the shape
/// that fits above the keyboard; the sheet shows them all.
struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest
    var compact = false
    var onDetails: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil

    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @State private var notes: [String: String] = [:]
    @State private var step = 0
    @State private var showOther: Set<String> = []
    @State private var showNotes: Set<String> = []
    @FocusState private var otherFocused: String?

    private var questions: [AskUserQuestion.Question] { AskUserQuestion.questions(in: request.input) }
    private var heading: String? { AskUserQuestion.heading(in: request.input) }

    private func answer(for q: AskUserQuestion.Question) -> [String] {
        var labels = q.options.map(\.label).filter { picked[q.question, default: []].contains($0) }
        let typed = other[q.question, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { labels.append(typed) }
        return labels
    }
    private func isAnswered(_ q: AskUserQuestion.Question) -> Bool { !answer(for: q).isEmpty }
    private var allAnswered: Bool { questions.allSatisfy(isAnswered) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if compact {
                if questions.indices.contains(step) { questionView(questions[step]) }
                compactFooter
            } else {
                ForEach(questions) { q in
                    questionView(q)
                    if q.id != questions.last?.id { Divider().overlay(CDS.border) }
                }
            }
        }
        .padding(compact ? 10 : 0)
        .background(compact ? CDS.surface2 : .clear, in: RoundedRectangle(cornerRadius: CDS.radiusComposer))
        .overlay {
            if compact { RoundedRectangle(cornerRadius: CDS.radiusComposer).strokeBorder(CDS.accent.opacity(0.5)) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CDS.accent)
                .frame(width: 18)
            Text(heading ?? (questions.count == 1 ? "\(agentName) has a question" : "\(agentName) has \(questions.count) questions"))
                .font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(2)
            Spacer(minLength: 4)
            if compact, questions.count > 1 {
                Text("\(min(step + 1, questions.count)) of \(questions.count)").font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            if let onDetails {
                Button(action: onDetails) {
                    HStack(spacing: 4) {
                        Text("Expand").font(CDS.caption).foregroundStyle(CDS.textMuted)
                        Chevron(expanded: false)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var agentName: String { (model.states[request.sessionId]?.agent ?? .claude).label }

    @ViewBuilder private func questionView(_ q: AskUserQuestion.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !q.header.isEmpty {
                Text(q.header.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(CDS.textMuted).tracking(0.5)
            }
            Text(q.question).font(CDS.body).foregroundStyle(CDS.textPrimary).fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6) {
                ForEach(q.options) { option in
                    OptionChip(label: option.label, description: option.description,
                               selected: picked[q.question, default: []].contains(option.label)) {
                        toggle(option.label, in: q)
                    }
                }
                OptionChip(label: "Other…", description: "", selected: showOther.contains(q.question), dashed: true) {
                    if showOther.contains(q.question) {
                        showOther.remove(q.question); other[q.question] = ""
                    } else {
                        showOther.insert(q.question); otherFocused = q.question
                    }
                }
            }
            if showOther.contains(q.question) {
                TextField("Your answer", text: Binding(get: { other[q.question, default: ""] }, set: { other[q.question] = $0 }), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(CDS.body)
                    .padding(8)
                    .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radius - 2))
                    .focused($otherFocused, equals: q.question)
            }
            if !compact {
                if showNotes.contains(q.question) {
                    TextField("Notes for the agent", text: Binding(get: { notes[q.question, default: ""] }, set: { notes[q.question] = $0 }), axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .font(CDS.body)
                        .padding(8)
                        .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radius - 2))
                } else {
                    Button("Add a note") { showNotes.insert(q.question) }
                        .font(CDS.caption).foregroundStyle(CDS.textMuted).buttonStyle(.plain)
                }
            }
        }
    }

    private func toggle(_ label: String, in q: AskUserQuestion.Question) {
        var set = picked[q.question, default: []]
        if q.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
            picked[q.question] = set
        } else {
            picked[q.question] = set.contains(label) ? [] : [label]
            // A single choice answers the question; in the compact card move on (or finish).
            if compact, picked[q.question]?.isEmpty == false {
                if step + 1 < questions.count { withAnimation { step += 1 } } else { submit() }
            }
        }
    }

    private var compactFooter: some View {
        HStack(spacing: 8) {
            if step > 0 {
                Button { withAnimation { step -= 1 } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(CDSButtonStyle(variant: .secondary))
            }
            Spacer(minLength: 0)
            if step + 1 < questions.count {
                Button("Next") { withAnimation { step += 1 } }
                    .buttonStyle(CDSButtonStyle(variant: .secondary))
                    .disabled(!questions.indices.contains(step) || !isAnswered(questions[step]))
            } else {
                Button("Send answers") { submit() }
                    .buttonStyle(CDSButtonStyle(variant: .primary))
                    .disabled(!allAnswered)
            }
        }
    }

    /// The sheet's bottom bar.
    var actionBar: some View {
        HStack(spacing: 10) {
            Button("Skip") {
                model.decide(request, allow: false, reason: "The user skipped the question.")
                onDone?()
            }
            .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
            Button("Send answers") { submit() }
                .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
                .disabled(!allAnswered)
        }
    }

    private func submit() {
        var answers: [String: [String]] = [:]
        for q in questions { answers[q.question] = answer(for: q) }
        model.answer(request, answers: answers, notes: notes)
        onDone?()
    }
}

/// One selectable answer. The description shows under the label when there is one.
private struct OptionChip: View {
    let label: String
    let description: String
    let selected: Bool
    var dashed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(CDS.bodyMedium).foregroundStyle(selected ? CDS.onPrimary : CDS.textPrimary)
                if !description.isEmpty {
                    Text(description).font(CDS.caption).foregroundStyle(selected ? CDS.onPrimary.opacity(0.8) : CDS.textMuted)
                        .lineLimit(3).multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? CDS.fillPrimary : CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radius))
            .overlay {
                RoundedRectangle(cornerRadius: CDS.radius)
                    .strokeBorder(selected ? .clear : CDS.border, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            }
        }
        .buttonStyle(.plain)
    }
}

/// Wraps its children onto as many rows as needed (chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .init(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The question form as a sheet, with Skip / Send at the bottom.
struct QuestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: PermissionRequest

    var body: some View {
        NavigationStack {
            let card = QuestionCard(request: request, onDone: { dismiss() })
            ScrollView {
                card.padding()
            }
            .background(CDS.surface0)
            .safeAreaInset(edge: .bottom) {
                card.actionBar
                    .padding()
                    .background(CDS.surface0)
                    .overlay(alignment: .top) { Divider().overlay(CDS.border) }
            }
            .navigationTitle("Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
        }
    }
}

// MARK: - ExitPlanMode

/// The plan the agent wants approved, pinned above the composer: a glimpse of it, Review to read
/// the whole thing, Approve to start implementing.
struct PlanDockCard: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest
    let onReview: () -> Void

    private var plan: String? { PlanReview.plan(in: request.input) }
    private var glimpse: String {
        let lines = (plan ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.prefix(3).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onReview) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CDS.accent)
                        .frame(width: 18)
                    Text("Plan ready for review").font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("Read").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    Chevron(expanded: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !glimpse.isEmpty {
                Text(glimpse)
                    .font(CDS.body).foregroundStyle(CDS.textSecondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radius - 2))
            }
            HStack(spacing: 8) {
                Button("Review") { onReview() }
                    .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
                Button("Approve") { model.decide(request, allow: true) }
                    .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
            }
        }
        .padding(10)
        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radiusComposer))
        .overlay(RoundedRectangle(cornerRadius: CDS.radiusComposer).strokeBorder(CDS.accent.opacity(0.5)))
    }
}

/// The whole plan, rendered like a reply, with Approve / Approve & accept edits / feedback.
struct PlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PermissionRequest

    @State private var feedback = ""
    @State private var showFeedback = false
    @FocusState private var feedbackFocused: Bool

    private var plan: String { PlanReview.plan(in: request.input) ?? "_The plan text was not included in the request._" }
    private var suggestedMode: String? { PlanReview.suggestedMode(in: request.suggestions) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MarkdownText(text: plan)
                    if let path = PlanReview.planFilePath(in: request.input) {
                        Text(path).font(CDS.caption).foregroundStyle(CDS.textMuted).textSelection(.enabled)
                    }
                }
                .padding()
            }
            .background(CDS.surface0)
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: plan, preview: SharePreview("Plan", image: Image(systemName: "list.bullet.clipboard"))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if showFeedback {
                TextField("What should change?", text: $feedback, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(CDS.body)
                    .padding(10)
                    .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
                    .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
                    .focused($feedbackFocused)
                HStack(spacing: 10) {
                    Button("Cancel") { showFeedback = false; feedback = "" }
                        .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
                    Button("Send feedback") {
                        model.decide(request, allow: false, reason: feedback.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
                    .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                if let suggestedMode {
                    Button {
                        model.decide(request, allow: true, remember: true)
                        dismiss()
                    } label: {
                        Label("Approve & \(PlanSheet.modeLabel(suggestedMode))", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
                }
                HStack(spacing: 10) {
                    Button("Request changes") { showFeedback = true; feedbackFocused = true }
                        .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
                    Button("Approve") {
                        model.decide(request, allow: true)
                        dismiss()
                    }
                    .buttonStyle(CDSButtonStyle(variant: suggestedMode == nil ? .primary : .secondary, fullWidth: true))
                }
            }
        }
        .padding()
        .background(CDS.surface0)
        .overlay(alignment: .top) { Divider().overlay(CDS.border) }
    }

    static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "acceptEdits": return "accept edits"
        case "bypassPermissions": return "bypass permissions"
        case "dontAsk": return "don't ask again"
        case "auto": return "auto mode"
        default: return mode
        }
    }
}

// MARK: - Queue

/// Prompts waiting for the running turn to end, above the composer. Swipe-free: an × pulls one back.
struct QueuedPromptsStrip: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let queued: [QueuedPrompt]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.caption2)
                Text(queued.count == 1 ? "Queued · goes out when this turn ends" : "\(queued.count) queued · go out in order when this turn ends")
                    .font(CDS.caption)
            }
            .foregroundStyle(CDS.textMuted)
            ForEach(queued) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.text.isEmpty ? (item.attachmentCount > 0 ? "\(item.attachmentCount) attachment(s)" : " ") : item.text)
                        .font(CDS.body).foregroundStyle(CDS.textSecondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.attachmentCount > 0, !item.text.isEmpty {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(CDS.textMuted)
                    }
                    Button { model.dequeue(sessionId, promptId: item.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(CDS.textMuted)
                            .frame(width: 22, height: 22)
                            .background(CDS.fillNeutral, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove from queue")
                }
                .padding(8)
                .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
                .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
            }
        }
        .padding(.horizontal, 2)
    }
}
