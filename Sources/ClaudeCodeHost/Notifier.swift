#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    public var canSendTelegram: Bool { config.telegramToken != nil && config.telegramChatID != nil }

    public enum SendError: Error, CustomStringConvertible {
        case notConfigured
        case telegram(String)
        case unreachable(String)
        public var description: String {
            switch self {
            case .notConfigured: return "Telegram is not set up."
            case .telegram(let why): return "Telegram refused the message: \(why)"
            case .unreachable(let why): return "Telegram could not be reached from this Mac: \(why)"
            }
        }
    }

    /// A longer message with Telegram's HTML formatting (the digest), waiting for Telegram's answer. If it
    /// rejects the markup, the same text goes out without it rather than not at all.
    public func sendTelegramHTML(_ html: String) async throws {
        guard let token = config.telegramToken, let chat = config.telegramChatID else { throw SendError.notConfigured }
        func post(_ fields: [String: String]) async throws -> (Int, String) {
            var req = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(Notifier.formEncode(fields).utf8)
            // A URLError's description carries the request URL, and with it the bot token: it goes to
            // the phone as an error, so only the reason travels.
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw SendError.unreachable((error as? URLError)?.localizedDescription ?? "network error")
            }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        let (status, body) = try await post(["chat_id": chat, "text": html, "parse_mode": "HTML", "disable_web_page_preview": "true"])
        if status == 200 { return }
        log("telegram HTML refused (\(status)): \(body.prefix(200)) — sending plain")
        let plain = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        let (status2, body2) = try await post(["chat_id": chat, "text": plain, "disable_web_page_preview": "true"])
        guard status2 == 200 else { throw SendError.telegram("HTTP \(status2): \(body2.prefix(200))") }
    }

    /// `application/x-www-form-urlencoded`, strictly: only unreserved characters stay as they are, so an
    /// `&`, `=` or `+` inside the text (HTML entities have plenty) cannot split a field.
    static func formEncode(_ fields: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        return fields.sorted { $0.key < $1.key }.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&")
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
