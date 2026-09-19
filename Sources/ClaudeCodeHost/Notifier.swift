#if os(macOS)
import Foundation

/// Sends phone notifications for session events (permission needed, turn done, error) via
/// ntfy.sh and/or a Telegram bot — no Apple Developer account or APNs required.
public struct NotifierConfig: Sendable {
    public var ntfyURL: URL?
    public var telegramToken: String?
    public var telegramChatID: String?
    public var notifyDone: Bool

    public init(ntfyURL: URL? = nil, telegramToken: String? = nil, telegramChatID: String? = nil, notifyDone: Bool = true) {
        self.ntfyURL = ntfyURL
        self.telegramToken = telegramToken
        self.telegramChatID = telegramChatID
        self.notifyDone = notifyDone
    }

    /// Accepts a bare ntfy topic ("my-mac-xyz") or a full URL ("https://ntfy.example.com/topic").
    public static func ntfyURL(from value: String) -> URL? {
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return URL(string: value) }
        return URL(string: "https://ntfy.sh/\(value)")
    }

    public var isEnabled: Bool { ntfyURL != nil || (telegramToken != nil && telegramChatID != nil) }
}

public enum NotifyPriority: Sendable { case high, normal, low }

public final class Notifier: @unchecked Sendable {
    public enum Event: Sendable { case permission, done, error }

    private let config: NotifierConfig
    private let session: URLSession
    private let log: @Sendable (String) -> Void

    public init(config: NotifierConfig, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.config = config
        self.log = log
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: cfg)
    }

    public func notify(_ event: Event, body: String) {
        if event == .done && !config.notifyDone { return }
        let priority: NotifyPriority = (event == .permission || event == .error) ? .high : .low
        if let url = config.ntfyURL { sendNtfy(url: url, event: event, body: body, priority: priority) }
        if let token = config.telegramToken, let chat = config.telegramChatID {
            sendTelegram(token: token, chat: chat, text: "\(emoji(event)) \(title(event)): \(body)", silent: priority == .low)
        }
    }

    private func title(_ event: Event) -> String {
        switch event { case .permission: return "Needs approval"; case .done: return "Done"; case .error: return "Error" }
    }
    private func emoji(_ event: Event) -> String {
        switch event { case .permission: return "🔐"; case .done: return "✅"; case .error: return "⚠️" }
    }
    /// ntfy renders these tag names as emoji.
    private func ntfyTag(_ event: Event) -> String {
        switch event { case .permission: return "lock"; case .done: return "white_check_mark"; case .error: return "warning" }
    }

    private func sendNtfy(url: URL, event: Event, body: String, priority: NotifyPriority) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Title/Tags headers must be ASCII (project names may be non-ASCII, so they go in the body).
        req.setValue(title(event), forHTTPHeaderField: "Title")
        req.setValue(priority == .high ? "high" : priority == .low ? "low" : "default", forHTTPHeaderField: "Priority")
        req.setValue(ntfyTag(event), forHTTPHeaderField: "Tags")
        req.httpBody = Data(body.utf8)   // UTF-8 body carries the project + details
        send(req, to: "ntfy")
    }

    private func sendTelegram(token: String, chat: String, text: String, silent: Bool) {
        guard var comps = URLComponents(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return }
        comps.queryItems = [
            URLQueryItem(name: "chat_id", value: chat),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "disable_notification", value: silent ? "true" : "false"),
        ]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        send(req, to: "telegram")
    }

    private func send(_ req: URLRequest, to name: String) {
        let log = self.log
        session.dataTask(with: req) { _, response, error in
            if let error { log("notify \(name) failed: \(error.localizedDescription)") }
            else if let http = response as? HTTPURLResponse, http.statusCode >= 300 { log("notify \(name) HTTP \(http.statusCode)") }
        }.resume()
    }
}
#endif
