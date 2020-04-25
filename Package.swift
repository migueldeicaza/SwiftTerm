// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

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
