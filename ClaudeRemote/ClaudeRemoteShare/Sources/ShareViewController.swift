import UIKit
import UniformTypeIdentifiers

/// "Send to Mac" in the share sheet: the shared text or link goes to the app as
/// `ccremote://share?text=…`, where it becomes a task or lands in a session's composer. Nothing is
/// kept here — no App Group needed, so it works on a free Apple ID too.
final class ShareViewController: UIViewController {
    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.text = "Opening ClaudeRemote…"
        status.textAlignment = .center
        status.numberOfLines = 0
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
        Task { await hand() }
    }

    private func hand() async {
        let text = await sharedText()
        guard !text.isEmpty, var c = URLComponents(string: "ccremote://share") else {
            finish(message: "Nothing to send.")
            return
        }
        c.queryItems = [URLQueryItem(name: "text", value: String(text.prefix(20_000)))]
        guard let url = c.url, open(url) else {
            // Couldn't reach the app: leave it on the clipboard instead.
            UIPasteboard.general.string = text
            finish(message: "Copied — open ClaudeRemote and paste it.")
            return
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func finish(message: String) {
        status.text = message
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// The page title and link, or the text, of what was shared.
    private func sharedText() async -> String {
        var parts: [String] = []
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            if let title = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { parts.append(title) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    parts.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    parts.append(text)
                }
            }
        }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: "\n")
    }

    /// Extensions may not open URLs directly; the application object up the responder chain can.
    private func open(_ url: URL) -> Bool {
        typealias OpenURL = @convention(c) (AnyObject, Selector, URL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication, app.responds(to: selector) {
                let implementation = app.method(for: selector)
                unsafeBitCast(implementation, to: OpenURL.self)(app, selector, url, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}
