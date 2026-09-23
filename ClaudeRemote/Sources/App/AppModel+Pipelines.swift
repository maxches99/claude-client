import Foundation
import ClaudeRemoteCore

@MainActor
extension AppModel {

    // MARK: branch review

    func requestReview(_ sessionId: String, base: String? = nil) {
        reviews[sessionId, default: ReviewState()].loading = true
        reviews[sessionId]?.error = nil
        sendMessage(.reviewDiff(sessionId: sessionId, base: base), session: sessionId)
    }

    func addReviewComment(_ sessionId: String, _ comment: ReviewComment) {
        reviewDrafts[sessionId, default: []].append(comment)
    }

    func removeReviewComment(_ sessionId: String, id: String) {
        reviewDrafts[sessionId]?.removeAll { $0.id == id }
    }

    /// All remarks, as one message in the session's composer (to read over and send).
    func sendReview(_ sessionId: String) {
        let comments = reviewDrafts[sessionId] ?? []
        guard !comments.isEmpty else { return }
        insertIntoComposer(sessionId, text: ReviewPrompt.compose(comments: comments, base: reviews[sessionId]?.base))
        reviewDrafts[sessionId] = nil
    }

    // MARK: workspace

    func requestRemoteRepositories() {
        remoteRepositoriesLoading = true
        remoteRepositoriesError = nil
        sendMessage(.listRemoteRepositories)
    }

    func cloneRepository(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, cloning == nil else { return }
        cloning = trimmed
        cloneMessage = nil
        sendMessage(.cloneRepository(source: trimmed))
    }

    // MARK: duels

    func startDuel(title: String, prompt: String, cwd: String, claudeMode: String?, codexPolicy: String?, judge: AgentKind) {
        sendMessage(.startDuel(title: title, prompt: prompt, cwd: cwd, claudeMode: claudeMode, codexPolicy: codexPolicy, judge: judge))
    }

    func duelAction(_ id: String, _ action: DuelAction) {
        if action == .delete { duels.removeAll { $0.id == id } }
        sendMessage(.duelAction(id: id, action: action))
    }

    func tasks(of duel: Duel) -> [AgentTask] {
        duel.taskIds.compactMap { id in tasks.first { $0.id == id } }
    }

    // MARK: scheduled digest

    func requestDigestSchedule() {
        guard supportsPipelines else { return }
        sendMessage(.getDigestSchedule)
    }

    func setDigestSchedule(minutes: Int?) {
        digestSchedule?.minutes = minutes
        sendMessage(.setDigestSchedule(minutes: minutes))
    }

    func sendDigestNow() {
        digestScheduleError = nil
        sendMessage(.sendDigestNow)
    }
}
