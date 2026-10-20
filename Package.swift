// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ruban",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure layout engine: the strip model and the geometry, no AppKit.
        .target(name: "RubanCore"),
        // The menu bar app: Accessibility, hotkeys, animation, settings.
        .executableTarget(
            name: "Ruban",
            dependencies: ["RubanCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "RubanCoreTests", dependencies: ["RubanCore"]),
    ]
)
