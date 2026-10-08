// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notchwerk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Notchwerk",
            path: "Sources/Notchwerk"
        )
    ]
)
