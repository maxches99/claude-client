// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "claude-remote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClaudeRemoteCore", targets: ["ClaudeRemoteCore"]),
        .library(name: "ClaudeCodeHost", targets: ["ClaudeCodeHost"]),
        .executable(name: "ccremote", targets: ["ccremote"]),
    ],
    targets: [
        // Shared between the Mac daemon and the iOS app: wire protocol, JSON, transcript reducer.
        .target(name: "ClaudeRemoteCore"),
        // Mac-only: drives `claude` CLI processes over stream-json, indexes ~/.claude.
        .target(name: "ClaudeCodeHost", dependencies: ["ClaudeRemoteCore"]),
        // The daemon executable: WebSocket server + Bonjour + pairing.
        .executableTarget(name: "ccremote", dependencies: ["ClaudeCodeHost", "ClaudeRemoteCore"]),
        .testTarget(name: "ClaudeRemoteCoreTests", dependencies: ["ClaudeRemoteCore"]),
    ]
)
