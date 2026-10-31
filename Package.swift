// swift-tools-version:6.2

import PackageDescription
import Foundation

let environment = ProcessInfo.processInfo.environment
let embeddedCheck = environment["SWIFTTERM_EMBEDDED_CHECK"] == "1"
let documentationBuild = environment["SWIFTTERM_DOCC"] == "1"

let excludeAppleSources = environment["SWIFTTERM_EXCLUDE_APPLE"] == "1"
#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = excludeAppleSources ? ["Apple", "Mac", "iOS"] : []
#endif

var swiftTermSettings: [SwiftSetting] = []

if embeddedCheck {
    swiftTermSettings += [
        .define("SWIFTTERM_EMBEDDED"),
        .unsafeFlags(["-Werror", "EmbeddedRestrictions"]),
    ]
}

let swiftTermTarget: Target = .target(
    name: "SwiftTerm",
    dependencies: [],
    path: "Sources/SwiftTerm",
    exclude: platformExcludes + [
        "Mac/README.md",
        "Apple/Metal/Shaders.metal",
    ],
    resources: [
        .copy("../../swifterm-terminfo") // Restored: Links the core terminfo data files directly
    ],
    swiftSettings: swiftTermSettings,
    plugins: []
)

var products: [Product] = [
    .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
]

var targets: [Target] = [
    swiftTermTarget
]

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
