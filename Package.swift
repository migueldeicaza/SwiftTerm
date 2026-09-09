// swift-tools-version:6.2

import PackageDescription
import Foundation

let environment = ProcessInfo.processInfo.environment
let embeddedCheck = environment["SWIFTTERM_EMBEDDED_CHECK"] == "1"
let wasmSmokeBuild = environment["SWIFTTERM_WASM"] == "1"

// A package manifest is compiled and run on the HOST, so `os(Linux)` is false
// when cross-compiling from macOS to Linux. Allow Apple sources to be excluded
// explicitly for that case.
let excludeAppleSources =
    environment["SWIFTTERM_EXCLUDE_APPLE"] == "1"
#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = excludeAppleSources ? ["Apple", "Mac", "iOS"] : []
#endif

let buildInfoTargets: [Target] = [
    .executableTarget(
        name: "SwiftTermBuildInfoGenerator",
        path: "Sources/SwiftTermBuildInfoGenerator"
    ),
    .plugin(
        name: "SwiftTermBuildInfoPlugin",
        capability: .buildTool(),
        dependencies: ["SwiftTermBuildInfoGenerator"]
    )
]

let graphicsDependencies: [Target.Dependency] = [
    .product(
        name: "PNG",
        package: "swift-png",
        condition: .when(platforms: [.linux, .windows])
    ),
    .product(
        name: "LZ77",
        package: "swift-png",
        condition: .when(platforms: [.linux, .windows])
    ),
]

let portableTraitSettings: [SwiftSetting] = [
    .define("SWIFTTERM_EMBEDDED", .when(traits: ["Embedded"])),
    .enableExperimentalFeature("Embedded", .when(traits: ["Embedded"])),
    .define("SWIFTTERM_EMBEDDED", .when(traits: ["Wasm"])),
    .define("SWIFTTERM_WASM", .when(traits: ["Wasm"])),
]

var swiftTermSettings: [SwiftSetting] = portableTraitSettings

if embeddedCheck {
    swiftTermSettings += [
        .define("SWIFTTERM_EMBEDDED"),
        .unsafeFlags(["-Werror", "EmbeddedRestrictions"]),
    ]
}

let swiftTermTarget: Target = .target(
    name: "SwiftTerm",
    dependencies: graphicsDependencies,
    path: "Sources/SwiftTerm",
    exclude: platformExcludes + [
        "Mac/README.md",
        "Apple/Metal/Shaders.metal",
    ],
    swiftSettings: swiftTermSettings,
    plugins: [
        .plugin(name: "SwiftTermBuildInfoPlugin")
    ]
)

#if os(Windows)
var products: [Product] = [
    .executable(name: "SwiftTermFuzz", targets: ["SwiftTermFuzz"]),
    .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
]

var targets: [Target] = [
    swiftTermTarget,
    .executableTarget(
        name: "SwiftTermFuzz",
        dependencies: ["SwiftTerm"],
        path: "Sources/SwiftTermFuzz"
    ),
    .testTarget(
        name: "SwiftTermTests",
        dependencies: ["SwiftTerm"],
        path: "Tests/SwiftTermTests",
        resources: [
            .copy("Fixtures/xterm-ghostty.infocmp"),
            .copy("Fixtures/GhosttyFuzzCorpus"),
            .copy("KittyGraphics/Fixtures")
        ]
    )
] + buildInfoTargets
#else
var products: [Product] = [
    .executable(name: "SwiftTermFuzz", targets: ["SwiftTermFuzz"]),
    .executable(name: "termcast", targets: ["Termcast"]),
    .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
]

var targets: [Target] = [
    swiftTermTarget,
    .executableTarget(
        name: "SwiftTermFuzz",
        dependencies: ["SwiftTerm"],
        path: "Sources/SwiftTermFuzz"
    ),
    .executableTarget(
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
        path: "Tests/SwiftTermTests",
        resources: [
            .copy("Fixtures/xterm-ghostty.infocmp"),
            .copy("Fixtures/GhosttyFuzzCorpus"),
            .copy("KittyGraphics/Fixtures")
        ]
    )
] + buildInfoTargets
#endif

if embeddedCheck {
    // The host tests and executables use APIs that are deliberately absent
    // from the portable core. Keep check mode scoped to that core and its
    // restriction tests, as the former portable-target manifest did.
    products = [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ]
    targets = [swiftTermTarget] + buildInfoTargets
    targets.append(
        .testTarget(
            name: "SwiftTermEmbeddedTests",
            dependencies: ["SwiftTerm"],
            path: "Tests/SwiftTermEmbeddedTests"
        )
    )
}

if wasmSmokeBuild {
    // Embedded WASM executables need two link fixes that plain SwiftPM does
    // not provide: the Embedded Swift Unicode data tables, and tolerance for
    // the duplicate symbols that appear because the importer re-emits the
    // library code that SwiftPM also links as objects. The library directory
    // lives inside the WASM SDK bundle, so scripts/build-wasm.sh locates it
    // and passes it through this environment variable. The smoke target only
    // exists for this dev build, so consumers never see the unsafe flags.
    let embeddedWasmLinkerSettings: [LinkerSetting]
    if let libDir = environment["SWIFTTERM_WASM_EMBEDDED_LIBDIR"] {
        embeddedWasmLinkerSettings = [
            .unsafeFlags([
                "-L\(libDir)",
                "-lswiftUnicodeDataTables",
                "-Xlinker", "--allow-multiple-definition",
            ], .when(traits: ["Embedded"]))
        ]
    } else {
        embeddedWasmLinkerSettings = []
    }
    products.append(
        .executable(name: "SwiftTermWasmSmoke", targets: ["SwiftTermWasmSmoke"])
    )
    targets.append(
        .executableTarget(
            name: "SwiftTermWasmSmoke",
            dependencies: ["SwiftTerm"],
            path: "Sources/SwiftTermWasmSmoke",
            // The smoke program must compile in the same language mode as the
            // library: with the Embedded trait, a plain-Swift target cannot
            // link against the $e-mangled Embedded module.
            swiftSettings: portableTraitSettings,
            linkerSettings: embeddedWasmLinkerSettings
        )
    )
}

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        // The snapshot Embedded Swift standard library needs macOS 14. Do not
        // raise the package minimum for that: Embedded macOS builds pass an
        // explicit `--triple arm64-apple-macosx14.0` (or later) instead.
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: products,
    traits: [
        .trait(
            name: "Embedded",
            description: "Foundation-free portable core for Embedded Swift"
        ),
        .trait(
            name: "Wasm",
            description: "Foundation-free portable core for WASI"
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.3"),
        .package(url: "https://github.com/tayloraswift/swift-png", from: "4.5.0"),
    ],
//        .package(url: "https://github.com/swiftlang/swift-subprocess", revision: "426790f3f24afa60b418450da0afaa20a8b3bdd4")
    targets: targets,
    swiftLanguageModes: [.v6]
)
