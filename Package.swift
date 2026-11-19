// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WindowSwitcher",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        )
    ]
)
