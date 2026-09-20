import Foundation
import Network
import Security
import CryptoKit

/// TLS role for a WebSocket channel.
public enum TLSRole {
    /// Plain `ws://` — no transport security (LAN / behind a VPN or a TLS-terminating relay).
    case none
    /// `wss://` server presenting `identity` (a self-signed `SecIdentity`, see TLSIdentity).
    case server(identity: sec_identity_t)
    /// `wss://` client that pins the server's cert by SHA-256 fingerprint.
    /// `expected == nil` means trust-on-first-use: accept whatever is presented and report it
    /// through `learned` so the caller can persist and pin it next time.
    case clientPinned(expected: String?, learned: (@Sendable (String) -> Void)?)
    /// `wss://` client with standard system trust (CA + hostname) — for a relay with a real cert.
    case clientDefault
}

/// Thin wrapper over an `NWConnection` that speaks WebSocket text frames.
/// Used by the daemon for accepted connections and by the app for outgoing ones.
public final class WebSocketChannel: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _onText: (@Sendable (String) -> Void)?
    private var _onState: (@Sendable (NWConnection.State) -> Void)?

    public var onText: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onText } }
        set { lock.withLock { _onText = newValue } }
    }

    public var onState: (@Sendable (NWConnection.State) -> Void)? {
        get { lock.withLock { _onState } }
        set { lock.withLock { _onState = newValue } }
    }

    private var _secure: E2ELink?
    /// End-to-end encryption once its handshake is done: outgoing text is sealed, incoming frames
    /// are opened before `onText` sees them (a frame that fails to authenticate closes the link).
    /// Handshake frames themselves travel in the clear, before this is set.
    public var secure: E2ELink? {
        get { lock.withLock { _secure } }
        set { lock.withLock { _secure = newValue } }
    }

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    private static let verifyQueue = DispatchQueue(label: "ccremote.tls.verify")

    /// TCP(+TLS) + WebSocket parameters shared by client and server.
    public static func parameters(tls: TLSRole = .none) -> NWParameters {
        let params: NWParameters
        switch tls {
        case .none:
            params = NWParameters.tcp
        case .server(let identity):
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
            params = NWParameters(tls: options)
        case .clientPinned(let expected, let learned):
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let cert = WebSocketChannel.leafCertificate(secTrust) else { complete(false); return }
                let fingerprint = WebSocketChannel.fingerprint(of: cert)
                learned?(fingerprint)
                if let expected {
                    complete(fingerprint.caseInsensitiveCompare(expected) == .orderedSame)
                } else {
                    complete(true)   // trust-on-first-use
                }
            }, verifyQueue)
            params = NWParameters(tls: options)
        case .clientDefault:
            params = NWParameters(tls: NWProtocolTLS.Options())   // default CA + hostname validation
        }
        // TCP keepalive so a dead or half-open connection (idle proxy drop, NAT timeout, sleep)
        // is detected by the OS and surfaced as `.failed`, letting the owner reconnect. Also caps
        // connect time so a racing route to an unreachable address fails fast.
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 15       // start probing after 15s idle
            tcp.keepaliveInterval = 5    // probe every 5s
            tcp.keepaliveCount = 3       // dead after ~3 missed probes (~30s)
            tcp.connectionTimeout = 10   // give up connecting after 10s
            tcp.noDelay = true
        }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    private static func leafCertificate(_ trust: SecTrust) -> SecCertificate? {
        if #available(macOS 12.0, iOS 15.0, *) {
            return (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            return SecTrustGetCertificateAtIndex(trust, 0)
        }
    }

    public static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onState?(state)
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    public func send(text: String, completion: (@Sendable (NWError?) -> Void)? = nil) {
        var payload = text
        if let secure, secure.isEstablished {
            guard let sealed = try? secure.seal(text) else { return }
            payload = sealed
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(payload.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    public func close() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                // A read error means the peer/proxy dropped us (e.g. an idle timeout). Cancel so the
                // state handler fires `.cancelled` and the owner can reconnect — don't just stop reading.
                self.connection.cancel()
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .close:
                    self.connection.cancel()
                    return
                case .text, .binary:
                    if let content, let text = String(data: content, encoding: .utf8) {
                        if let secure = self.secure, secure.isEstablished {
                            guard let plain = try? secure.open(text) else {
                                // Tampered, replayed or from the wrong key: the link is not ours any more.
                                self.connection.cancel()
                                return
                            }
                            self.onText?(plain)
                        } else {
                            self.onText?(text)
                        }
                    }
                default:
                    break
                }
            }
            self.receiveLoop()
        }
    }
}
