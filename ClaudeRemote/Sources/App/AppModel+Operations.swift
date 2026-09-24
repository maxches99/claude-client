import Foundation
import ClaudeRemoteCore

/// Text or a link shared into the app from another one, before it becomes a task or a prompt.
struct SharedDraft: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

/// One event of the merged feed, with the Mac it came from.
struct FeedEvent: Identifiable, Equatable {
    var macId: String
    var macName: String
    var event: HostEvent
    var id: String { macId + ":" + event.id }
}

extension AppModel {
    func supportsOperations(mac macId: String) -> Bool {
        (hostByMac[macId]?.protocolVersion ?? 1) >= 8
    }

    /// Every Mac's events, newest first.
    var feed: [FeedEvent] {
        var out: [FeedEvent] = []
        for (macId, events) in eventsByMac {
            let name = macs.first { $0.id == macId }?.displayName ?? hostByMac[macId]?.hostName ?? "Mac"
            out += events.map { FeedEvent(macId: macId, macName: name, event: $0) }
        }
        return out.sorted { $0.event.date > $1.event.date }
    }

    func refreshFeed() {
        for (macId, link) in connections where supportsOperations(mac: macId) {
            link.send(.listEvents(since: eventsByMac[macId]?.last?.date))
        }
    }

    func requestHealth(mac macId: String) {
        send(.health, toMac: macId)
    }

    func receiveOperations(_ message: ServerMessage, from macId: String) {
        switch message {
        case .events(let items, _):
            var known = eventsByMac[macId] ?? []
            let ids = Set(known.map(\.id))
            known += items.filter { !ids.contains($0.id) }
            known.sort { $0.date < $1.date }
            eventsByMac[macId] = Array(known.suffix(1500))
        case .health(let report):
            healthByMac[macId] = report
        default:
            break
        }
    }

    // MARK: sharing in

    /// `ccremote://share?text=…` from the share extension.
    func receiveShare(_ url: URL) -> Bool {
        guard url.scheme == "ccremote", url.host == "share",
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        incomingShare = SharedDraft(text: text)
        return true
    }
}
