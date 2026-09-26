import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import ClaudeRemoteCore

/// A file saved from the phone's editor.
struct FileSave: Equatable {
    var saving = true
    var error: String?
}

/// A session being packed to hand over.
struct PackageState: Equatable {
    var package: SessionPackage?
    var error: String?
    var loading = true
}

struct ImportResult: Equatable, Identifiable {
    var id = UUID()
    var sessionId: String?
    var cwd: String?
    var error: String?
    var macId: String
}

/// A packed session as a file for the share sheet (AirDrop, Messages, Files).
struct SessionPackageFile: Transferable {
    let package: SessionPackage
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { try ProtocolCoding.encoder.encode($0.package) }
            .suggestedFileName { "\(AgentTask.title(fromPrompt: $0.package.title)).\(SessionPackage.fileExtension).json" }
    }
}

extension AppModel {
    func supportsPeople(mac macId: String) -> Bool {
        (hostByMac[macId]?.protocolVersion ?? 1) >= 9
    }

    // MARK: editing files

    func saveFile(sessionId: String, path: String, content: String, baseHash: String?) {
        savedFiles[path] = FileSave()
        sendMessage(.writeFile(sessionId: sessionId, path: path, content: content, baseHash: baseHash), session: sessionId)
    }

    // MARK: people

    func requestUsers() { sendMessage(.listUsers) }
    func inviteUser(_ name: String) {
        inviteError = nil
        sendMessage(.inviteUser(name: name))
    }
    func removeUser(_ id: String) { sendMessage(.removeUser(id: id)) }
    func setOwnClaudeToken(_ token: String?) { sendMessage(.setOwnClaudeToken(token: token)) }
    func giveSession(_ sessionId: String, to userId: String?) { sendMessage(.giveSession(sessionId: sessionId, userId: userId)) }

    // MARK: handing sessions over

    func exportSession(_ sessionId: String) {
        packages[sessionId] = PackageState()
        sendMessage(.exportSession(sessionId: sessionId), session: sessionId)
    }

    /// Unpacks a session on a paired Mac (this one, another of yours, or the hub).
    func importSession(_ package: SessionPackage, into macId: String) {
        importResult = nil
        send(.importSession(package: package, cwd: nil), toMac: macId)
    }

    /// A `.ccsession` file opened with the app.
    func receivePackageFile(_ url: URL) -> Bool {
        guard url.isFileURL, url.lastPathComponent.contains(".\(SessionPackage.fileExtension)") else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let package = try? ProtocolCoding.decoder.decode(SessionPackage.self, from: data) else { return false }
        incomingPackage = package
        return true
    }

    func receivePeople(_ message: ServerMessage, from macId: String, isActive: Bool) {
        switch message {
        case .fileWritten(_, let path, let hash, let error):
            savedFiles[path] = FileSave(saving: false, error: error)
            if error == nil, hash != nil { requestFile(path, force: true) }
        case .users(let items, let me):
            if isActive, me == nil || !items.isEmpty { hostUsers = items }
            if let me, var host = hostByMac[macId] { host.me = me; hostByMac[macId] = host }
        case .userInvited(let user, let url, let error):
            if let user, let url { invitation = (user, url) } else { inviteError = error }
        case .sessionPackage(let sessionId, let package, let error):
            packages[sessionId] = PackageState(package: package, error: error, loading: false)
        case .sessionImported(let sessionId, let cwd, let error):
            importResult = ImportResult(sessionId: sessionId, cwd: cwd, error: error, macId: macId)
        default:
            break
        }
    }
}
