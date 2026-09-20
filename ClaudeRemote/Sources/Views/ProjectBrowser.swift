import SwiftUI
import ClaudeRemoteCore

/// The session's project on the Mac: folders and files to browse, a search over file contents,
/// and any file opened in the viewer — from where it can be attached to the next prompt.
struct ProjectBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    private var cwd: String { model.states[sessionId]?.cwd ?? model.summary(for: sessionId)?.cwd ?? "" }
    private var projectName: String { (cwd as NSString).lastPathComponent }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    DirectoryListView(sessionId: sessionId, cwd: cwd, path: "")
                } else {
                    searchResults
                }
            }
            .background(CDS.surface0)
            .navigationTitle(projectName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: BrowserTarget.self) { target in
                switch target {
                case .directory(let path):
                    DirectoryListView(sessionId: sessionId, cwd: cwd, path: path)
                case .file(let path, let line):
                    RemoteFileContent(path: (cwd as NSString).appendingPathComponent(path), line: line, sessionId: sessionId, attachPath: path)
                }
            }
        }
        .searchable(text: $query, prompt: "Search file contents")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: query) { _, q in
            searchTask?.cancel()
            let trimmed = q.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else { return }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                model.searchProject(sessionId, query: trimmed)
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let result = model.searchResults[sessionId]
        let current = result?.query == query.trimmingCharacters(in: .whitespaces)
        if model.searchInFlight.contains(sessionId), !current {
            ProgressView().tint(CDS.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result, current {
            if let error = result.error {
                ContentUnavailableView(error, systemImage: "magnifyingglass")
            } else if result.matches.isEmpty {
                ContentUnavailableView.search(text: result.query)
            } else {
                List {
                    ForEach(groupedMatches(result.matches), id: \.path) { group in
                        Section {
                            ForEach(group.matches) { match in
                                NavigationLink(value: BrowserTarget.file(path: match.path, line: match.line)) {
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(match.line)").font(CDS.codeSmall).foregroundStyle(CDS.textMuted).frame(minWidth: 32, alignment: .trailing)
                                        Text(match.text).font(CDS.codeSmall).foregroundStyle(CDS.textPrimary).lineLimit(2)
                                    }
                                }
                                .listRowBackground(CDS.surface0)
                            }
                        } header: {
                            Text(group.path).font(.caption2.weight(.semibold)).foregroundStyle(CDS.textSecondary).textCase(nil)
                        }
                    }
                    if result.truncated {
                        Text("Showing the first \(result.matches.count) matches — narrow the search for more.")
                            .font(CDS.caption).foregroundStyle(CDS.textMuted).listRowBackground(CDS.surface0)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
            Text("Type at least two characters.").font(CDS.caption).foregroundStyle(CDS.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().tint(CDS.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func groupedMatches(_ matches: [SearchMatch]) -> [(path: String, matches: [SearchMatch])] {
        var order: [String] = []
        var byPath: [String: [SearchMatch]] = [:]
        for m in matches {
            if byPath[m.path] == nil { order.append(m.path) }
            byPath[m.path, default: []].append(m)
        }
        return order.map { ($0, byPath[$0] ?? []) }
    }
}

enum BrowserTarget: Hashable {
    case directory(path: String)
    case file(path: String, line: Int?)
}

/// One folder of the project.
struct DirectoryListView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let cwd: String
    /// Relative to the project root; empty for the root itself.
    let path: String

    private var key: AppModel.DirectoryKey { AppModel.DirectoryKey(sessionId: sessionId, path: path) }
    private var entries: [DirectoryEntry]? { model.directories[key] }
    private var error: String? { model.directoryErrors[key] }

    var body: some View {
        Group {
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                } else {
                    List(entries) { entry in
                        let child = path.isEmpty ? entry.name : path + "/" + entry.name
                        NavigationLink(value: entry.isDirectory ? BrowserTarget.directory(path: child) : BrowserTarget.file(path: child, line: nil)) {
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : RemoteFileViewer.symbol(for: entry.name))
                                    .font(.system(size: 14))
                                    .foregroundStyle(entry.isDirectory ? CDS.accent : CDS.textMuted)
                                    .frame(width: 22)
                                Text(entry.name).font(CDS.body).foregroundStyle(CDS.textPrimary).lineLimit(1)
                                Spacer(minLength: 4)
                                if let size = entry.size {
                                    Text(Media.humanSize(size)).font(CDS.caption).foregroundStyle(CDS.textMuted)
                                }
                            }
                        }
                        .listRowBackground(CDS.surface0)
                        .contextMenu {
                            Button("Copy path", systemImage: "link") { UIPasteboard.general.string = child }
                            if !entry.isDirectory {
                                Button("Attach to prompt", systemImage: "at") { model.attachMacFile(sessionId, path: child) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            } else if let error {
                ContentUnavailableView(error, systemImage: "folder.badge.questionmark")
            } else {
                ProgressView().tint(CDS.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CDS.surface0)
        .navigationTitle(path.isEmpty ? (cwd as NSString).lastPathComponent : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
        .refreshable { model.requestDirectory(sessionId, path: path) }
        .onAppear { if entries == nil { model.requestDirectory(sessionId, path: path) } }
    }
}
