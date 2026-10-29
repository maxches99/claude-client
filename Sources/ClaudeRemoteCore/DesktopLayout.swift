import Foundation

/// How Claude Desktop lays out its own sidebar on a host: pinned sessions, the sections someone made,
/// and the order of its projects — so a client can show the same sessions in the same places.
/// Session ids are CLI session ids (the ones every other message uses).
public struct DesktopLayout: Codable, Equatable, Sendable {
    public struct Section: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var sessionIds: [String]
        public var collapsed: Bool

        public init(id: String, name: String, sessionIds: [String], collapsed: Bool) {
            self.id = id
            self.name = name
            self.sessionIds = sessionIds
            self.collapsed = collapsed
        }
    }

    public var pinned: [String]
    public var sections: [Section]
    /// Project folders in Desktop's order (repository names like "owner/repo" are left out).
    public var projectOrder: [String]

    public init(pinned: [String] = [], sections: [Section] = [], projectOrder: [String] = []) {
        self.pinned = pinned
        self.sections = sections
        self.projectOrder = projectOrder
    }

    public var isEmpty: Bool { pinned.isEmpty && sections.isEmpty && projectOrder.isEmpty }

    /// Builds the layout from Desktop's `preferences.epitaxyPrefs` and its session records
    /// (`local_<uuid>` → CLI session id). The format is Desktop's own and undocumented: anything that
    /// doesn't look as expected is skipped rather than guessed at.
    public static func parse(prefs: JSONValue, cliIdForLocal: [String: String]) -> DesktopLayout {
        func ids(_ value: JSONValue?) -> [String] {
            (value?.array ?? []).compactMap { item -> String? in
                let raw = item.string ?? item["id"]?.string ?? item["sessionId"]?.string
                guard let raw else { return nil }
                return cliIdForLocal[raw] ?? (raw.hasPrefix("local_") ? nil : raw)
            }
        }
        /// Values nested under per-account keys ("<account>/<org>") — any of them.
        func accounts(_ value: JSONValue?) -> [JSONValue] {
            guard let value else { return [] }
            if value.array != nil { return [value] }
            return value.object.map { Array($0.values) } ?? []
        }

        var layout = DesktopLayout()
        layout.pinned = ids(prefs["starred-local-code-sessions"])
        for account in accounts(prefs["dframe-code-sections"]) {
            for section in account["sections"]?.array ?? [] {
                guard let id = section["id"]?.string, let kind = section["kind"]?.string,
                      !["pinned", "routines", "sessions"].contains(kind) else { continue }
                // Members under whichever key holds `local_…` ids.
                let members = section.object?.values.map { ids($0) }.max { $0.count < $1.count } ?? []
                let name = section["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Section"
                layout.sections.append(Section(id: id, name: name, sessionIds: members, collapsed: section["collapsed"]?.bool ?? false))
            }
        }
        // Kept per account, either nested or as "code-projects-order.<account>" keys.
        let orderValues = accounts(prefs["code-projects-order"])
            + (prefs.object ?? [:]).filter { $0.key.hasPrefix("code-projects-order.") }.sorted { $0.key < $1.key }.map(\.value)
        for account in orderValues {
            for path in account.array ?? [] {
                if let path = path.string, path.hasPrefix("/"), !layout.projectOrder.contains(path) { layout.projectOrder.append(path) }
            }
        }
        return layout
    }
}
