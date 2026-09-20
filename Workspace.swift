import ProjectDescription

let workspace = Workspace(
    name: "ClaudeRemote",
    projects: [
        "ClaudeRemote",       // iOS app + widget, watch app + complication
        "ClaudeRemoteHost",   // Mac menu-bar app hosting the daemon
    ]
)
