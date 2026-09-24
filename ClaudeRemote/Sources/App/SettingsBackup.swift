import Foundation
import CryptoKit
import CommonCrypto
import UniformTypeIdentifiers
import SwiftUI

/// Everything the app keeps about itself — paired Macs (with their tokens), saved prompts, pins and
/// archives, share links, preferences — as one file for a new phone. All of it lives in UserDefaults under
/// `ccremote.`; with a passphrase the file is sealed (AES-GCM, key from PBKDF2-SHA256).
enum SettingsBackup {
    static let prefix = "ccremote."
    static let format = "ccremote-settings"
    static let rounds: UInt32 = 310_000

    enum BackupError: Error, CustomStringConvertible {
        case notABackup, needsPassphrase, wrongPassphrase, unreadable
        var description: String {
            switch self {
            case .notABackup: return "That file is not a ClaudeRemote settings backup."
            case .needsPassphrase: return "This backup is locked with a passphrase."
            case .wrongPassphrase: return "Wrong passphrase."
            case .unreadable: return "The backup could not be read."
            }
        }
    }

    /// The app's own UserDefaults entries.
    static func snapshot(_ defaults: UserDefaults = .standard) -> [String: Any] {
        defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(prefix) }
    }

    static func export(passphrase: String?, defaults: UserDefaults = .standard) throws -> Data {
        let payload = try PropertyListSerialization.data(fromPropertyList: snapshot(defaults), format: .binary, options: 0)
        var file: [String: Any] = ["format": format, "version": 1, "createdAt": ISO8601DateFormatter().string(from: Date())]
        if let passphrase, !passphrase.isEmpty {
            let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let sealed = try AES.GCM.seal(payload, using: key(passphrase, salt: salt))
            file["salt"] = salt.base64EncodedString()
            file["sealed"] = sealed.combined?.base64EncodedString()
        } else {
            file["plain"] = payload.base64EncodedString()
        }
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
    }

    static func isSealed(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["sealed"] != nil
    }

    /// The entries in a backup (not written anywhere yet).
    static func read(_ data: Data, passphrase: String?) throws -> [String: Any] {
        guard let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], file["format"] as? String == format else {
            throw BackupError.notABackup
        }
        let payload: Data
        if let sealed = (file["sealed"] as? String).flatMap({ Data(base64Encoded: $0) }),
           let salt = (file["salt"] as? String).flatMap({ Data(base64Encoded: $0) }) {
            guard let passphrase, !passphrase.isEmpty else { throw BackupError.needsPassphrase }
            do {
                payload = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key(passphrase, salt: salt))
            } catch {
                throw BackupError.wrongPassphrase
            }
        } else if let plain = (file["plain"] as? String).flatMap({ Data(base64Encoded: $0) }) {
            payload = plain
        } else {
            throw BackupError.unreadable
        }
        guard let entries = try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any] else {
            throw BackupError.unreadable
        }
        return entries.filter { $0.key.hasPrefix(prefix) }
    }

    static func key(_ passphrase: String, salt: Data) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let password = Array(passphrase.utf8)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }, pw.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw BackupError.unreadable }
        return SymmetricKey(data: derived)
    }
}

/// The backup file for the share sheet / Files.
struct SettingsBackupFile: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName { _ in "ClaudeRemote settings \(Date().formatted(.iso8601.year().month().day())).json" }
    }
}

extension AppModel {
    /// Writes a backup's entries into UserDefaults and takes up its Macs and prompts right away.
    func restoreSettings(_ entries: [String: Any]) {
        let defaults = UserDefaults.standard
        for (key, value) in entries { defaults.set(value, forKey: key) }
        snippets = PromptSnippet.load()
        // Each Mac goes through pairing (which merges with one already here and connects).
        let restored = PairedMacs.load()
        let previous = activeMacId
        for mac in restored.macs { pair(mac) }
        if let id = restored.activeId ?? previous, macs.contains(where: { $0.id == id }) { switchTo(id) }
    }
}
