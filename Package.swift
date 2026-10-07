// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter
//
// The tools-version comment must stay on the first line — SwiftPM reads it from
// there, so the licence header goes below it, not above.

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
        // The menu bar app. SwiftPM builds the executable; scripts/build-app.sh
        // wraps it in the .app bundle that notifications and login items need.
        .executableTarget(
            name: "MouseTimeBar",
            dependencies: ["MouseTimeKit"],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "MouseTimeKitTests",
            dependencies: ["MouseTimeKit"]
        ),
    ]
)
