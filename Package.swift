// swift-tools-version:5.1
// IMPORTANT: Remember to modify SwiftTerm/Package.swift when modify this file

// This file is located in root of git repository to satisfy Swift Package Manager assumptions.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .executable(name: "SwiftTermFuzz", targets: ["SwiftTermFuzz"]),
        .library(
            name: "SwiftTerm",
            targets: ["SwiftTerm"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftTerm",
            dependencies: [],
            path: "SwiftTerm/Sources/SwiftTerm"
        ),
        .target (
            name: "SwiftTermFuzz",
            dependencies: ["SwiftTerm"],
            path: "SwiftTerm/Sources/SwiftTermFuzz"
        ),
        .testTarget(
            name: "SwiftTermTests",
            dependencies: ["SwiftTerm"],
            path: "SwiftTerm/Tests/SwiftTermTests"
        )
    ]
)
