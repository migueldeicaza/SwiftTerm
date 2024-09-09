// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftTerm",
            targets: ["SwiftTerm"]
        ),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SwiftTermFuzz",
            dependencies: ["SwiftTerm"]
        ),
        .executableTarget(
            name: "CaptureOutput",
            dependencies: ["SwiftTerm"]
        ),
        .target(
            name: "SwiftTerm",
            dependencies: [],
            path: "Sources/SwiftTerm"
        ),
        .testTarget(
            name: "SwiftTermTests",
            dependencies: ["SwiftTerm"],
            path: "Tests/SwiftTermTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
