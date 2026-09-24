import ProjectDescription
import ProjectDescriptionHelpers

// iOS app (iPhone / iPad / Mac Catalyst) with its Live Activity widget, plus the watchOS companion app
// and its complication. Run `tuist generate` from the repo root to create the project.
let project = Project(
    name: "ClaudeRemote",
    options: .plain,
    packages: [
        .package(path: ".."),   // ClaudeRemoteCore — wire protocol, transcript reducer, shared models
    ],
    targets: [
        .target(
            name: "ClaudeRemote",
            destinations: [.iPhone, .iPad, .macCatalyst],
            product: .app,
            bundleId: "dev.maxches.ClaudeRemote",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .file(path: "Info.plist"),
            sources: ["Sources/**", "Shared/**"],
            entitlements: .file(path: "ClaudeRemote.entitlements"),
            dependencies: [
                .package(product: "ClaudeRemoteCore"),
                // A Watch app can't ride along in the Mac Catalyst build.
                .target(name: "ClaudeRemoteWatch", condition: .when([.ios])),
                // ActivityKit has no Catalyst counterpart.
                .target(name: "ClaudeRemoteWidget", condition: .when([.ios])),
                .target(name: "ClaudeRemoteShare", condition: .when([.ios])),
            ],
            settings: .signed(extra: [
                "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
                "DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER": "NO",
            ])
        ),
        .target(
            name: "ClaudeRemoteWidget",
            destinations: [.iPhone, .iPad],
            product: .appExtension,
            bundleId: "dev.maxches.ClaudeRemote.widget",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .file(path: "ClaudeRemoteWidget/Info.plist"),
            sources: ["ClaudeRemoteWidget/Sources/**", "Shared/**"],
            entitlements: .file(path: "ClaudeRemoteWidget/ClaudeRemoteWidget.entitlements"),
            dependencies: [
                .package(product: "ClaudeRemoteCore"),
            ],
            settings: .signed()
        ),
        // "Send to Mac" in the share sheet: text and links become a task or a prompt in the app.
        .target(
            name: "ClaudeRemoteShare",
            destinations: [.iPhone, .iPad],
            product: .appExtension,
            bundleId: "dev.maxches.ClaudeRemote.share",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .file(path: "ClaudeRemoteShare/Info.plist"),
            sources: ["ClaudeRemoteShare/Sources/**"],
            settings: .signed()
        ),
        .target(
            name: "ClaudeRemoteWatch",
            destinations: [.appleWatch],
            product: .app,
            bundleId: "dev.maxches.ClaudeRemote.watchkitapp",
            deploymentTargets: .watchOS("10.0"),
            infoPlist: .file(path: "ClaudeRemoteWatch/Info.plist"),
            sources: ["ClaudeRemoteWatch/Sources/**"],
            entitlements: .file(path: "ClaudeRemoteWatch/ClaudeRemoteWatch.entitlements"),
            dependencies: [
                .package(product: "ClaudeRemoteCore"),
                .target(name: "ClaudeRemoteWatchWidget"),
            ],
            settings: .signed()
        ),
        .target(
            name: "ClaudeRemoteWatchWidget",
            destinations: [.appleWatch],
            product: .appExtension,
            bundleId: "dev.maxches.ClaudeRemote.watchkitapp.widget",
            deploymentTargets: .watchOS("10.0"),
            infoPlist: .file(path: "ClaudeRemoteWatchWidget/Info.plist"),
            sources: ["ClaudeRemoteWatchWidget/Sources/**"],
            entitlements: .file(path: "ClaudeRemoteWatchWidget/ClaudeRemoteWatchWidget.entitlements"),
            dependencies: [
                .package(product: "ClaudeRemoteCore"),
            ],
            settings: .signed()
        ),
    ]
)
