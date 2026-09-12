// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "WebTerminal",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "web-terminal", targets: ["WebTerminalServer"])],
    dependencies: [
        .package(name: "SwiftTerm", path: "../.."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", exact: "2.7.0"),
        // 1.6.1 fixes the server-only WSCore build (an undeclared NIOSSL import).
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", exact: "1.6.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
    ],
    targets: [
        .executableTarget(
            name: "WebTerminalServer",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "WSCore", package: "swift-websocket"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "WebTerminalServerTests",
            dependencies: [
                "WebTerminalServer",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
