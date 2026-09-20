import ProjectDescription

extension SettingsDictionary {
    /// Build settings every app-style target in the workspace shares. The Apple team is not here on
    /// purpose: it comes from the untracked `Tuist/team.xcconfig` (see `Tuist/Signing.xcconfig`).
    public static let common: SettingsDictionary = [
        "SWIFT_VERSION": "5.0",
        "CODE_SIGN_STYLE": "Automatic",
        "GENERATE_INFOPLIST_FILE": "NO",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        // Every Info.plist reads its version from these two; a release build overrides them from the git
        // tag (scripts/build-mac-app.sh / build-ios-ipa.sh honour MARKETING_VERSION and BUILD_NUMBER).
        "MARKETING_VERSION": "1.0",
        "CURRENT_PROJECT_VERSION": "1",
    ]
}

extension Settings {
    /// `common` at the target level plus the per-machine signing xcconfig, for projects whose targets
    /// need a real (non ad-hoc) signature. `xcconfigDirectory` is the path from the manifest to `Tuist/`.
    public static func signed(extra: SettingsDictionary = [:], xcconfigDirectory: Path = "../Tuist") -> Settings {
        let xcconfig: Path = "\(xcconfigDirectory.pathString)/Signing.xcconfig"
        return .settings(
            base: SettingsDictionary.common.merging(extra) { $1 },
            configurations: [
                .debug(name: .debug, xcconfig: xcconfig),
                .release(name: .release, xcconfig: xcconfig),
            ]
        )
    }
}

extension Project.Options {
    /// No synthesized `Bundle`/`Asset` accessors — the apps read resources the plain way.
    public static let plain: Project.Options = .options(
        disableBundleAccessors: true,
        disableSynthesizedResourceAccessors: true
    )
}
