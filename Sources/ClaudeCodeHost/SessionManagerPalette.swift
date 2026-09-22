#if os(macOS)
import Foundation
import ClaudeRemoteCore

extension SessionManager {
    /// Everything the composer can launch in this project: the slash commands the CLI advertised for
    /// the session, plus the commands, skills and sub-agents defined in `.claude/` — the project's
    /// own first, then yours from `~/.claude`.
    public func paletteItems(sessionId: String) -> [PaletteItem] {
        var items: [PaletteItem] = []
        var seen = Set<String>()

        func add(_ item: PaletteItem) {
            // A project definition shadows a personal one of the same name and kind.
            let key = "\(item.kind.rawValue):\(item.name)"
            guard seen.insert(key).inserted else { return }
            items.append(item)
        }

        let home = NSHomeDirectory() + "/.claude"
        let project = cwdFor(sessionId).map { ($0 as NSString).appendingPathComponent(".claude") }

        for (root, scope) in [(project, PaletteItem.Scope.project), (home, .user)].compactMap({ dir, scope in dir.map { ($0, scope) } }) {
            for item in SessionManager.markdownItems(in: (root as NSString).appendingPathComponent("commands"), kind: .command, scope: scope) { add(item) }
            for item in SessionManager.skillItems(in: (root as NSString).appendingPathComponent("skills"), scope: scope) { add(item) }
            for item in SessionManager.markdownItems(in: (root as NSString).appendingPathComponent("agents"), kind: .agent, scope: scope) { add(item) }
        }

        // Whatever the CLI itself offers (built-ins, plugins, MCP prompts) that we have not already listed.
        for name in hosted[sessionId]?.state.slashCommands ?? [] {
            let bare = name.hasPrefix("/") ? String(name.dropFirst()) : name
            guard !bare.isEmpty else { continue }
            add(PaletteItem(kind: .command, name: bare, detail: nil, scope: .builtin))
        }

        return items.sorted { a, b in
            if a.kind != b.kind { return kindOrder(a.kind) < kindOrder(b.kind) }
            if a.scope != b.scope { return scopeOrder(a.scope) < scopeOrder(b.scope) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func kindOrder(_ kind: PaletteItem.Kind) -> Int {
        switch kind {
        case .command: return 0
        case .skill: return 1
        case .agent: return 2
        }
    }

    private func scopeOrder(_ scope: PaletteItem.Scope) -> Int {
        switch scope {
        case .project: return 0
        case .user: return 1
        case .builtin: return 2
        }
    }

    /// `<dir>/<name>.md` — a slash command or a sub-agent, named by its file, described by its front matter.
    static func markdownItems(in directory: String, kind: PaletteItem.Kind, scope: PaletteItem.Scope) -> [PaletteItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.compactMap { file in
            let path = (directory as NSString).appendingPathComponent(file)
            let meta = SessionManager.frontMatter(path: path)
            let name = meta["name"] ?? String(file.dropLast(3))
            return PaletteItem(kind: kind, name: name, detail: meta["description"], scope: scope)
        }
    }

    /// `<dir>/<skill>/SKILL.md`.
    static func skillItems(in directory: String, scope: PaletteItem.Scope) -> [PaletteItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.compactMap { folder in
            let path = (directory as NSString).appendingPathComponent(folder + "/SKILL.md")
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let meta = SessionManager.frontMatter(path: path)
            return PaletteItem(kind: .skill, name: meta["name"] ?? folder, detail: meta["description"], scope: scope)
        }
    }

    /// The `key: value` pairs of a Markdown file's YAML front matter (flat keys only — name and
    /// description are all we show).
    static func frontMatter(path: String) -> [String: String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 8 * 1024), as: UTF8.self)
        var lines = head.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines.removeFirst()
        var result: [String: String] = [:]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            if value.count > 200 { value = String(value.prefix(200)) + "…" }
            result[key] = value
        }
        return result
    }
}
#endif
