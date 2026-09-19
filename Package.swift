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
    targets: [
        // Shared between the Mac daemon and the iOS app: wire protocol, JSON, transcript reducer.
        .target(name: "ClaudeRemoteCore"),
        // Mac-only: drives `claude` CLI processes over stream-json, indexes ~/.claude.
        .target(name: "ClaudeCodeHost", dependencies: ["ClaudeRemoteCore"]),
        // Mac-only: the daemon itself — WebSocket server + Bonjour, relay dial-out, pairing,
        // phone tracking. Hosted by the `ccremote` CLI and by the ClaudeRemote Host menu-bar app.
        .target(name: "ClaudeRemoteDaemon", dependencies: ["ClaudeCodeHost", "ClaudeRemoteCore"]),
        // The CLI front-end: parses flags, runs a Daemon, prints the pairing QR.
        .executableTarget(name: "ccremote", dependencies: ["ClaudeRemoteDaemon", "ClaudeCodeHost", "ClaudeRemoteCore"]),
        .testTarget(name: "ClaudeRemoteCoreTests", dependencies: ["ClaudeRemoteCore"]),
    ]
)
