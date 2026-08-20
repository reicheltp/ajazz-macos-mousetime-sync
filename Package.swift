// swift-tools-version: 6.0
import PackageDescription

// No dependencies: everything this tool does is IOKit, which ships with the OS.
// The logic lives in MouseTimeKit so a menu bar app can sit on top of it later
// without restructuring anything.
let package = Package(
    name: "mousetime",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MouseTimeKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "mousetime",
            dependencies: ["MouseTimeKit"]
        ),
        .testTarget(
            name: "MouseTimeKitTests",
            dependencies: ["MouseTimeKit"]
        ),
    ]
)
