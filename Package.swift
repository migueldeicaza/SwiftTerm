// swift-tools-version:5.9

import PackageDescription

#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = []
#endif

#if os(Windows)
let products: [Product] = [
    .executable(name: "SwiftTermFuzz", targets: ["SwiftTermFuzz"]),
    .library(
        name: "SwiftTerm",
        targets: ["SwiftTerm"]
    ),
]

let targets: [Target] = [
    .target(
        name: "SwiftTerm",
        dependencies: [],
        path: "Sources/SwiftTerm",
        exclude: platformExcludes + ["Mac/README.md"],
//        swiftSettings: [
//            .unsafeFlags(["-enforce-exclusivity=none"])
//        ]
    ),
    .executableTarget (
        name: "SwiftTermFuzz",
        dependencies: ["SwiftTerm"],
        path: "Sources/SwiftTermFuzz"
    ),
    .testTarget(
        name: "SwiftTermTests",
        dependencies: ["SwiftTerm"],
        path: "Tests/SwiftTermTests"
    )
]
#else
let products: [Product] = [
    .executable(name: "SwiftTermFuzz", targets: ["SwiftTermFuzz"]),
    .executable(name: "termcast", targets: ["Termcast"]),
    .library(
        name: "SwiftTerm",
        targets: ["SwiftTerm"]
    ),
]

let targets: [Target] = [
    .target(
        name: "SwiftTerm",
        //
        // We can not use Swift Subprocess, because there is no way of configuring the child process to
        // be a controlling terminal, as it is posix-spawn based.
//        dependencies: [
//            .product(name: "Subprocess", package: "swift-subprocess", condition: .when(platforms: [.macOS, .linux]))
//        ],
        path: "Sources/SwiftTerm",
        exclude: platformExcludes + ["Mac/README.md"],
//        swiftSettings: [
//            .unsafeFlags(["-enforce-exclusivity=none"])
//        ]
    ),
    .executableTarget (
        name: "SwiftTermFuzz",
        dependencies: ["SwiftTerm"],
        path: "Sources/SwiftTermFuzz"
    ),
    .executableTarget (
        name: "Termcast",
        dependencies: [
            "SwiftTerm",
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ],
        path: "Sources/Termcast"
    ),
    .testTarget(
        name: "SwiftTermTests",
        dependencies: ["SwiftTerm"],
        path: "Tests/SwiftTermTests"
    )
]
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v13),
        .macOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
//        .package(url: "https://github.com/swiftlang/swift-subprocess", revision: "426790f3f24afa60b418450da0afaa20a8b3bdd4")
    ],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
