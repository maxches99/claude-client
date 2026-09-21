// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "claude-remote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClaudeRemoteCore", targets: ["ClaudeRemoteCore"]),
        .library(name: "ClaudeCodeHost", targets: ["ClaudeCodeHost"]),
        .library(name: "ClaudeRemoteDaemon", targets: ["ClaudeRemoteDaemon"]),
        .executable(name: "ccremote", targets: ["ccremote"]),
    ],
    dependencies: [
        // Linux only: the daemon's WebSocket transport. Apple platforms use Network.framework
        // and never link this (see the platform condition below).
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.75.0"),
        // Linux only: CryptoKit's API for the end-to-end link (Apple platforms use CryptoKit itself).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // Shared between the Mac daemon and the iOS app: wire protocol, JSON, transcript reducer.
        // On Linux it also carries the SwiftNIO WebSocket transport and swift-crypto (CryptoKit's API).
        .target(name: "ClaudeRemoteCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.linux])),
            .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.linux])),
            .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.linux])),
            .product(name: "NIOWebSocket", package: "swift-nio", condition: .when(platforms: [.linux])),
        ]),
        // Mac/Linux: drives `claude` CLI processes over stream-json, indexes ~/.claude.
        .target(name: "ClaudeCodeHost", dependencies: ["ClaudeRemoteCore"]),
        // Mac/Linux: the daemon itself — WebSocket server (+ Bonjour on macOS), relay dial-out,
        // pairing, phone tracking. Hosted by the `ccremote` CLI and by the ClaudeRemote Host menu-bar app.
        .target(name: "ClaudeRemoteDaemon", dependencies: [
            "ClaudeCodeHost", "ClaudeRemoteCore",
            .target(name: "ObjCExceptionGuard", condition: .when(platforms: [.macOS])),
        ]),
        // Mac-only: catches NSExceptions raised inside Apple's private simulator frameworks (Swift can't).
        .target(name: "ObjCExceptionGuard"),
        // The CLI front-end: parses flags, runs a Daemon, prints the pairing QR.
        .executableTarget(name: "ccremote", dependencies: ["ClaudeRemoteDaemon", "ClaudeCodeHost", "ClaudeRemoteCore"]),
        .testTarget(name: "ClaudeRemoteCoreTests", dependencies: ["ClaudeRemoteCore"]),
        .testTarget(name: "ClaudeCodeHostTests", dependencies: ["ClaudeCodeHost", "ClaudeRemoteCore"]),
    ]
)
