// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeGirl",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeGirl",
            path: "Sources/ClaudeGirl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Network"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
