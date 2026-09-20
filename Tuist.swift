import ProjectDescription

// Root Tuist config. `tuist generate` (or `make xcode`) writes ClaudeRemote.xcworkspace with both app
// projects — nothing generated is committed, see .gitignore.
let tuist = Tuist(
    project: .tuist(
        generationOptions: .options(
            // The SwiftPM package at the root is pulled in as a local package by each project.
            enforceExplicitDependencies: false
        )
    )
)
