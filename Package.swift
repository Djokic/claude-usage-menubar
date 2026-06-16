// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageMenubar",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, unit-tested logic (Foundation/Combine only — no AppKit).
        .target(name: "ClaudeUsageCore"),

        // AppKit + SwiftUI shell (menu bar agent executable).
        .executableTarget(
            name: "ClaudeUsageApp",
            dependencies: ["ClaudeUsageCore"]
        ),

        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"]
        ),
    ],
    // Use the Swift 5 language mode: AppKit/Combine are not fully Sendable-annotated,
    // and strict Swift 6 concurrency adds friction with no benefit for a single-process
    // menu bar app whose mutable UI state lives on the main actor.
    swiftLanguageModes: [.v5]
)
