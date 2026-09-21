#if os(Linux)
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

// The Linux transport. Apple platforms use Network.framework (WebSocketChannel.swift); this file
// gives the daemon and the host library the same `WebSocketChannel` surface on top of SwiftNIO so
// PhoneSession, RelayClient, WebSocketServer and CodexAppServer compile unchanged. Plain ws:// only: a relay on the same box
// (or behind a mesh VPN) needs no TLS, and the daemon's own listener is meant for the LAN.

/// TLS role for a WebSocket channel. Only `.none` is available on Linux; the other cases exist so
/// callers compile and are reported as unsupported when used.
public enum TLSRole {
    case none
    case clientPinned(expected: String?, learned: (@Sendable (String) -> Void)?)
    case clientDefault

    var isPlain: Bool {
        if case .none = self { return true }
        return false
    }
}

/// Mirrors the `NWConnection.State` cases the daemon switches on.
public enum WebSocketChannelState: CustomStringConvertible {
    case setup
    case preparing
    case ready
    case waiting(Error)
    case failed(Error)
    case cancelled

    public var description: String {
        switch self {
        case .setup: return "setup"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .waiting(let e): return "waiting(\(e))"
        case .failed(let e): return "failed(\(e))"
        case .cancelled: return "cancelled"
        }
    }
}

public struct WebSocketTransportError: Error, CustomStringConvertible {
    public let description: String
}

/// One WebSocket connection speaking text frames — accepted by `NIOWebSocketListener` or dialed
/// with `connect(url:)`. Callbacks run on the channel's event loop.
public final class WebSocketChannel: @unchecked Sendable {
    static let maxFrameSize = 64 * 1024 * 1024
    static let group = MultiThreadedEventLoopGroup.singleton

    private enum Role {
        case accepted(Channel)
        case client(URL, TLSRole)
    }

    private let role: Role
    private let lock = NSLock()
    private var channel: Channel?
    private var _onText: (@Sendable (String) -> Void)?
    private var _onState: (@Sendable (WebSocketChannelState) -> Void)?
    private var ended = false

    public var onText: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onText } }
        set { lock.withLock { _onText = newValue } }
    }

    public var onState: (@Sendable (WebSocketChannelState) -> Void)? {
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

    /// Wraps a channel the listener has already upgraded to WebSocket.
    init(accepted channel: Channel) {
        role = .accepted(channel)
        self.channel = channel
    }

    private init(url: URL, tls: TLSRole) {
        role = .client(url, tls)
    }

    /// An outgoing connection; nothing happens until `start()`. `queue` is accepted for API parity
    /// with the Network.framework channel and unused — callbacks arrive on the event loop.
    public static func connect(url: URL, tls: TLSRole, queue: DispatchQueue) -> WebSocketChannel {
        WebSocketChannel(url: url, tls: tls)
    }

    public func start() {
        switch role {
        case .accepted(let channel):
            // Add the frame handler before the upgrader forwards any bytes it buffered with the
            // HTTP request: `accept` runs inside the upgrade callback, on the event loop.
            if channel.eventLoop.inEventLoop {
                _ = channel.pipeline.addHandler(FrameHandler(owner: self))
            } else {
                channel.eventLoop.execute { _ = channel.pipeline.addHandler(FrameHandler(owner: self)) }
            }
        case .client(let url, let tls):
            dial(url: url, tls: tls)
        }
    }

    public func send(text: String, completion: (@Sendable (Error?) -> Void)? = nil) {
        guard let channel = lock.withLock({ channel }) else { completion?(WebSocketTransportError(description: "not connected")); return }
        var payload = text
        if let secure, secure.isEstablished {
            guard let sealed = try? secure.seal(text) else { return }
            payload = sealed
        }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: self.maskKey, data: buffer)
            channel.writeAndFlush(frame).whenComplete { result in
                if case .failure(let error) = result { completion?(error) } else { completion?(nil) }
            }
        }
    }

    public func close() {
        guard let channel = lock.withLock({ channel }) else { return }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: 2)
            buffer.writeInteger(UInt16(1000))
            let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: self.maskKey, data: buffer)
            channel.writeAndFlush(frame).whenComplete { _ in channel.close(promise: nil) }
        }
    }

    /// Client frames must be masked (RFC 6455 §5.1); server frames must not.
    private var maskKey: WebSocketMaskingKey? {
        if case .client = role { return WebSocketMaskingKey([UInt8.random(in: 0...255), .random(in: 0...255), .random(in: 0...255), .random(in: 0...255)]) }
        return nil
    }

    // MARK: client

    private func dial(url: URL, tls: TLSRole) {
        guard tls.isPlain else {
            finish(.failed(WebSocketTransportError(description: "wss:// is not supported by the Linux build; use ws:// (relay on the same host or behind a VPN)")))
            return
        }
        guard let host = url.host else {
            finish(.failed(WebSocketTransportError(description: "relay URL has no host")))
            return
        }
        let port = url.port ?? (url.scheme == "wss" ? 443 : 80)
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }
        onState?(.preparing)

        let upgrader = NIOWebSocketClientUpgrader(maxFrameSize: WebSocketChannel.maxFrameSize) { channel, _ in
            channel.pipeline.addHandler(FrameHandler(owner: self))
        }
        let bootstrap = ClientBootstrap(group: WebSocketChannel.group)
            .connectTimeout(.seconds(10))
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(.tcpOption(.init(rawValue: TCP_KEEPIDLE)), value: 15)
            .channelOption(.tcpOption(.init(rawValue: TCP_KEEPINTVL)), value: 5)
            .channelOption(.tcpOption(.init(rawValue: TCP_KEEPCNT)), value: 3)
            .channelInitializer { channel in
                let requestSender = UpgradeRequestSender(owner: self, host: host, port: port, path: path)
                return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: (upgraders: [upgrader], completionHandler: { context in
                    _ = context.pipeline.removeHandler(requestSender)
                })).flatMap {
                    channel.pipeline.addHandler(requestSender)
                }
            }
        bootstrap.connect(host: host, port: port).whenComplete { [self] result in
            switch result {
            case .success(let channel):
                channel.closeFuture.whenComplete { _ in self.finish(.cancelled) }
            case .failure(let error):
                finish(.failed(error))
            }
        }
    }

    /// Terminal state, reported once.
    fileprivate func finish(_ state: WebSocketChannelState) {
        let first: Bool = lock.withLock {
            if ended { return false }
            ended = true
            return true
        }
        guard first else { return }
        onState?(state)
    }

    fileprivate func deliver(_ text: String) {
        if let secure, secure.isEstablished {
            guard let plain = try? secure.open(text) else {
                // Tampered, replayed or from the wrong key: the link is not ours any more.
                lock.withLock { channel }?.close(promise: nil)
                return
            }
            onText?(plain)
        } else {
            onText?(text)
        }
    }

    fileprivate func upgraded(_ channel: Channel) {
        lock.withLock { self.channel = channel }
        onState?(.ready)
    }

    fileprivate func failed(_ error: Error) {
        finish(.failed(error))
        lock.withLock { channel }?.close(promise: nil)
    }
}

/// Sends the HTTP upgrade request as soon as the TCP connection is up. `NIOHTTPClientUpgradeHandler`
/// adds the `Upgrade`, `Connection` and `Sec-WebSocket-*` headers itself; only `Host` is ours.
private final class UpgradeRequestSender: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let owner: WebSocketChannel
    private let host: String
    private let port: Int
    private let path: String

    init(owner: WebSocketChannel, host: String, port: Int, path: String) {
        self.owner = owner
        self.host = host
        self.port = port
        self.path = path
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: port == 80 ? host : "\(host):\(port)")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Only reached when the server refused the upgrade (a plain HTTP response).
        if case .head(let head) = unwrapInboundIn(data) {
            owner.failed(WebSocketTransportError(description: "WebSocket upgrade refused: HTTP \(head.status.code)"))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner.failed(error)
    }
}

/// Text frames in, pings answered, close honoured. Shared by accepted and dialed channels.
private final class FrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let owner: WebSocketChannel
    private var fragments: ByteBuffer?
    private var fragmentOpcode: WebSocketOpcode?
    private var closing = false

    init(owner: WebSocketChannel) {
        self.owner = owner
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { owner.upgraded(context.channel) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            var payload = frame.unmaskedData
            if frame.fin {
                deliver(&payload)
            } else {
                fragments = payload
                fragmentOpcode = frame.opcode
            }
        case .continuation:
            guard var acc = fragments else { return }
            var payload = frame.unmaskedData
            acc.writeBuffer(&payload)
            if frame.fin {
                fragments = nil
                fragmentOpcode = nil
                deliver(&acc)
            } else {
                fragments = acc
            }
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: nil, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            guard !closing else { return }
            closing = true
            let reply = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: nil, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in context.close(promise: nil) }
        default:
            break
        }
    }

    private func deliver(_ buffer: inout ByteBuffer) {
        if let text = buffer.readString(length: buffer.readableBytes) { owner.deliver(text) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner.finish(.cancelled)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner.failed(error)
    }
}

/// Accepts WebSocket connections on a TCP port and hands each upgraded channel to `accept`.
public final class NIOWebSocketListener: @unchecked Sendable {
    private var serverChannel: Channel?

    public init() {}

    /// Binds and upgrades; `accept` is called on the event loop for every phone.
    public func start(host: String, port: UInt16, accept: @escaping @Sendable (WebSocketChannel, String) -> Void) -> EventLoopFuture<UInt16> {
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: WebSocketChannel.maxFrameSize,
            shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { channel, _ in
                let remote = channel.remoteAddress.map { "\($0)" } ?? "?"
                accept(WebSocketChannel(accepted: channel), remote)
                return channel.eventLoop.makeSucceededFuture(())
            })
        let bootstrap = ServerBootstrap(group: WebSocketChannel.group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_keepalive), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(.tcpOption(.init(rawValue: TCP_KEEPIDLE)), value: 15)
            .childChannelOption(.tcpOption(.init(rawValue: TCP_KEEPINTVL)), value: 5)
            .childChannelOption(.tcpOption(.init(rawValue: TCP_KEEPCNT)), value: 3)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
            }
        return bootstrap.bind(host: host, port: Int(port)).map { [self] channel in
            serverChannel = channel
            return UInt16(channel.localAddress?.port ?? Int(port))
        }
    }

    public func stop() {
        serverChannel?.close(promise: nil)
        serverChannel = nil
    }
}
#endif
