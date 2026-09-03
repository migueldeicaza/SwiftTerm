// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SwiftTermBenchmarks",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VTEBenchWorkloads", targets: ["VTEBenchWorkloads"]),
        .executable(name: "SwiftTermProfile", targets: ["SwiftTermProfile"])
    ],
    dependencies: [
        // The explicit name keeps the package identity stable in git worktrees.
        .package(name: "SwiftTerm", path: "../.."),
        .package(
            url: "https://github.com/ordo-one/benchmark",
            .upToNextMajor(from: "1.29.11"))
    ],
    targets: [
        .target(
            name: "VTEBenchWorkloads",
            resources: [
                .copy("Resources")
            ]),
        .executableTarget(
            name: "SwiftTermBenchmarks",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Benchmark", package: "benchmark"),
                "VTEBenchWorkloads"
            ],
            path: "Benchmarks/SwiftTermBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark")
            ]),
        .executableTarget(
            name: "SwiftTermProfile",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "VTEBenchWorkloads"
            ]),
        .testTarget(
            name: "VTEBenchWorkloadsTests",
            dependencies: ["VTEBenchWorkloads"])
    ],
    swiftLanguageModes: [.v6]
)
