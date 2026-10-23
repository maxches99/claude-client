import ProjectDescription
import ProjectDescriptionHelpers

// Native macOS client: the same AppModel / connection / feature views as the iOS app, in a Mac window
// (sidebar of hosts and sessions, chat in the detail column, Settings scene, menu commands).
// It talks to any ccremote host — another Mac or the Linux hub. Run `tuist generate` from the repo root.
let project = Project(
    name: "ClaudeRemoteMac",
    options: .plain,
    packages: [
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "ClaudeRemoteMac",
            destinations: [.mac],
            product: .app,
            bundleId: "dev.maxches.ClaudeRemote.mac",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .file(path: "Info.plist"),
            sources: [
                "Sources/**",
                // The self-updater the Host app uses, pointed at the client's own zip.
                "../ClaudeRemoteHost/Sources/AppUpdater.swift",
                // Shared with the iOS app; iOS-only pieces are behind `#if os(iOS)` or left out here.
                .glob("../ClaudeRemote/Sources/**", excluding: [
                    "../ClaudeRemote/Sources/App/ClaudeRemoteApp.swift",
                    "../ClaudeRemote/Sources/App/WatchBridge.swift",
                    "../ClaudeRemote/Sources/Views/RootView.swift",
                ]),
            ],
            resources: ["Assets.xcassets"],
            entitlements: .file(path: "ClaudeRemoteMac.entitlements"),
            dependencies: [
                .package(product: "ClaudeRemoteCore"),
            ],
            settings: .settings(base: SettingsDictionary.common.merging([
                "PRODUCT_NAME": "ClaudeRemote",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "CODE_SIGN_IDENTITY": "-",
                "COMBINE_HIDPI_IMAGES": "YES",
                "DEAD_CODE_STRIPPING": "YES",
            ]) { $1 })
        ),
    ]
)
