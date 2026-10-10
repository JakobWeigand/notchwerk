// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notchwerk",
    platforms: [.macOS(.v13)],
    targets: [
        // Gemeinsam für App und Widgets: Farben, Logo und die Datei, über die die App die Widgets versorgt.
        .target(
            name: "NotchwerkShared",
            path: "Sources/NotchwerkShared"
        ),
        .executableTarget(
            name: "Notchwerk",
            dependencies: ["NotchwerkShared"],
            path: "Sources/Notchwerk"
        ),
        // Die Widgets: läuft als eigene Erweiterung (.appex) in einer Sandbox, siehe scripts/build-app.sh.
        // Xcode startet Erweiterungen über _NSExtensionMain statt über main. Ohne diesen Einstieg
        // beendet sich der Prozess sofort und macOS bietet die Widgets nicht an. @main am
        // WidgetBundle bleibt trotzdem nötig, sonst fehlt das Bundle im fertigen Programm.
        .executableTarget(
            name: "NotchwerkWidgets",
            dependencies: ["NotchwerkShared"],
            path: "Sources/NotchwerkWidgets",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
    ]
)
