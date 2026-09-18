import Foundation
import Network

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

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// TCP + WebSocket parameters shared by client and server.
    public static func parameters() -> NWParameters {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onState?(state)
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    public func send(text: String, completion: (@Sendable (NWError?) -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { error in
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
            if let error {
                _ = error
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .close:
                    self.connection.cancel()
                    return
                case .text, .binary:
                    if let content, let text = String(data: content, encoding: .utf8) {
                        self.onText?(text)
                    }
                default:
                    break
                }
            }
            self.receiveLoop()
        }
    }
}
