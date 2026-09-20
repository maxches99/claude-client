import ProjectDescription
import ProjectDescriptionHelpers

// Mac menu-bar app that hosts the ccremote daemon. Run `tuist generate` from the repo root to create the project;
// scripts/build-mac-app.sh builds a signed .app + zip into dist/.
let project = Project(
    name: "ClaudeRemoteHost",
    options: .plain,
    packages: [
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "ClaudeRemoteHost",
            destinations: [.mac],
            product: .app,
            bundleId: "dev.maxches.ccremote",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .file(path: "Info.plist"),
            sources: ["Sources/**"],
            resources: ["Assets.xcassets"],
            dependencies: [
                .package(product: "ClaudeRemoteDaemon"),
                .package(product: "ClaudeCodeHost"),
                .package(product: "ClaudeRemoteCore"),
            ],
            settings: .settings(base: SettingsDictionary.common.merging([
                "PRODUCT_NAME": "ClaudeRemote Host",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                // No sandbox: the app runs the claude CLI, reads ~/.claude and talks to launchd.
                "ENABLE_APP_SANDBOX": "NO",
                "ENABLE_HARDENED_RUNTIME": "YES",
                // Sign to run locally by default; scripts/build-mac-app.sh passes a real identity when TEAM_ID is set.
                "CODE_SIGN_IDENTITY": "-",
                "COMBINE_HIDPI_IMAGES": "YES",
                "DEAD_CODE_STRIPPING": "YES",
                "SWIFT_STRICT_CONCURRENCY": "minimal",
            ]) { $1 })
        ),
    ]
)
