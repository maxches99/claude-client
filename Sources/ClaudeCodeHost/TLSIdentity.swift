#if os(macOS)
import Foundation
import Security
import Network
import CryptoKit

/// A self-signed TLS identity for the daemon's WebSocket server.
///
/// There is no public API to mint a self-signed X.509 identity from Security.framework,
/// so we shell out to the system `openssl` once, persist the material in the support
/// directory (0600), and load it back as a `SecIdentity`. Clients don't trust a CA —
/// they pin `fingerprint` (SHA-256 of the DER cert), which the daemon publishes in the
/// pairing URL/QR.
public struct TLSIdentity {
    public let identity: sec_identity_t
    public let fingerprint: String   // lowercase hex SHA-256 of the DER certificate

    private static let p12Passphrase = "ccremote"

    public static func loadOrCreate(directory: String) throws -> TLSIdentity {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p12Path = directory + "/tls-identity.p12"
        if !fm.fileExists(atPath: p12Path) {
            try generate(directory: directory, p12Path: p12Path)
        }
        guard let data = fm.contents(atPath: p12Path) else { throw TLSError.read("cannot read \(p12Path)") }
        let (secIdentity, certificate) = try importPKCS12(data)
        guard let identity = sec_identity_create(secIdentity) else { throw TLSError.identity("sec_identity_create failed") }
        return TLSIdentity(identity: identity, fingerprint: TLSIdentity.fingerprint(of: certificate))
    }

    public static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: generation

    private static func generate(directory: String, p12Path: String) throws {
        let keyPath = directory + "/tls-key.pem"
        let certPath = directory + "/tls-cert.pem"
        try runOpenSSL(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
                        "-keyout", keyPath, "-out", certPath, "-subj", "/CN=ccremote"])
        try runOpenSSL(["pkcs12", "-export", "-inkey", keyPath, "-in", certPath,
                        "-out", p12Path, "-name", "ccremote", "-passout", "pass:\(p12Passphrase)"])
        for path in [keyPath, p12Path] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private static func runOpenSSL(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { throw TLSError.openssl("cannot launch openssl: \(error.localizedDescription)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TLSError.openssl("openssl \(args.first ?? "") failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: import

    private static func importPKCS12(_ data: Data) throws -> (SecIdentity, SecCertificate) {
        let options = [kSecImportExportPassphrase as String: p12Passphrase]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first else {
            throw TLSError.identity("SecPKCS12Import failed (OSStatus \(status))")
        }
        guard let identityAny = first[kSecImportItemIdentity as String] else {
            throw TLSError.identity("PKCS12 has no identity")
        }
        let identity = identityAny as! SecIdentity
        var certificate: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certStatus == errSecSuccess, let certificate else {
            throw TLSError.identity("SecIdentityCopyCertificate failed (OSStatus \(certStatus))")
        }
        return (identity, certificate)
    }

    public enum TLSError: Error, CustomStringConvertible {
        case openssl(String), identity(String), read(String)
        public var description: String {
            switch self {
            case .openssl(let m), .identity(let m), .read(let m): return m
            }
        }
    }
}
#endif
