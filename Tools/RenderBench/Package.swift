// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RenderBench",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // name: pins the package identity so this also builds from checkouts
        // whose directory is not named SwiftTerm (e.g. git worktrees).
        .package(name: "SwiftTerm", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "RenderBench",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ])
    ],
    swiftLanguageModes: [.v5]
)
