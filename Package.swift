// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            path: "Sources/ClaudeNotch"
        )
    ]
)
