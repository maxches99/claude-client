import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// End-to-end encryption for a phone ↔ Mac link that crosses something untrusted (the relay).
///
/// Both ends know the pairing token. A handshake exchanges ephemeral X25519 keys and nonces, and
/// the session key is `HKDF(shared secret ‖ token, salt: nonces)` — so the relay, which sees every
/// byte, cannot derive it (no token), and a token leaked later does not open past traffic (ephemeral
/// keys). Every frame after that is `{"x": base64(ChaCha20-Poly1305)}` with the direction and a
/// running counter as authenticated data, so a frame cannot be replayed, reordered or reflected.
public final class E2ELink: @unchecked Sendable {
    public enum Role { case initiator, responder }
    public enum LinkError: Error, CustomStringConvertible {
        case malformedHandshake, alreadyEstablished, notEstablished, badFrame
        public var description: String {
            switch self {
            case .malformedHandshake: return "Malformed encryption handshake"
            case .alreadyEstablished: return "Encryption already established"
            case .notEstablished: return "Encryption not established"
            case .badFrame: return "Encrypted frame failed to authenticate"
            }
        }
    }

    public static let version = 1

    public let role: Role
    private let token: String
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let nonce: Data
    private var key: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private let lock = NSLock()

    public init(token: String, role: Role) {
        self.token = token
        self.role = role
        var generator = SystemRandomNumberGenerator()   // the system CSPRNG on every platform
        nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    public var isEstablished: Bool { lock.withLock { key != nil } }

    /// The plaintext frame that opens (initiator) or answers (responder) the handshake.
    public func handshakeMessage() -> String {
        let payload: JSONValue = .object(["e2e": .object([
            "v": .number(Double(E2ELink.version)),
            "pub": .string(privateKey.publicKey.rawRepresentation.base64EncodedString()),
            "nonce": .string(nonce.base64EncodedString()),
        ])])
        return payload.serializedString()
    }

    /// True when `text` is a handshake frame (`{"e2e": …}`) — consumed, and the key is derived.
    public func accept(_ text: String) throws -> Bool {
        guard text.hasPrefix("{"), text.contains("\"e2e\""), let value = try? JSONValue.parse(text), let hs = value["e2e"] else { return false }
        guard let pubText = hs["pub"]?.string, let pub = Data(base64Encoded: pubText),
              let nonceText = hs["nonce"]?.string, let peerNonce = Data(base64Encoded: nonceText),
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub) else { throw LinkError.malformedHandshake }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        // Salt = initiator nonce ‖ responder nonce, whichever side we are.
        let salt = role == .initiator ? nonce + peerNonce : peerNonce + nonce
        let derived = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("ccremote-e2e-v1|".utf8) + Data(token.utf8),
                                                     outputByteCount: 32)
        try lock.withLock {
            guard key == nil else { throw LinkError.alreadyEstablished }
            key = derived
        }
        return true
    }

    /// Whether a frame is a sealed one (`{"x": …}`).
    public static func isSealed(_ text: String) -> Bool { text.hasPrefix("{\"x\":") }

    public func seal(_ plaintext: String) throws -> String {
        let (k, n) = try lock.withLock { () throws -> (SymmetricKey, UInt64) in
            guard let key else { throw LinkError.notEstablished }
            defer { sendCounter += 1 }
            return (key, sendCounter)
        }
        let box = try ChaChaPoly.seal(Data(plaintext.utf8), using: k, authenticating: aad(direction: role, counter: n))
        return "{\"x\":\"" + box.combined.base64EncodedString() + "\"}"
    }

    public func open(_ text: String) throws -> String {
        guard E2ELink.isSealed(text), let value = try? JSONValue.parse(text), let b64 = value["x"]?.string,
              let combined = Data(base64Encoded: b64) else { throw LinkError.badFrame }
        let (k, n) = try lock.withLock { () throws -> (SymmetricKey, UInt64) in
            guard let key else { throw LinkError.notEstablished }
            defer { receiveCounter += 1 }
            return (key, receiveCounter)
        }
        let peer: Role = role == .initiator ? .responder : .initiator
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            let plain = try ChaChaPoly.open(box, using: k, authenticating: aad(direction: peer, counter: n))
            return String(decoding: plain, as: UTF8.self)
        } catch {
            throw LinkError.badFrame
        }
    }

    private func aad(direction: Role, counter: UInt64) -> Data {
        var data = Data(direction == .initiator ? "i".utf8 : "r".utf8)
        withUnsafeBytes(of: counter.bigEndian) { data.append(contentsOf: $0) }
        return data
    }
}
