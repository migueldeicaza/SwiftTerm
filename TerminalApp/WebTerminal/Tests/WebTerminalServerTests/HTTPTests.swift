import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import WebTerminalServer

@Test func servesPublicFilesAndWasmAssetsInMemory() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("web-terminal-http-\(UUID().uuidString)")
    let publicDirectory = directory.appendingPathComponent("Public")
    let assetDirectory = directory.appendingPathComponent("dist")
    try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let html = "<!doctype html><title>Terminal</title>"
    let javascript = "export const terminal = true;"
    let wasm: [UInt8] = [0, 97, 115, 109, 1, 0, 0, 0]
    try Data(html.utf8).write(to: publicDirectory.appendingPathComponent("index.html"))
    try Data(javascript.utf8).write(to: publicDirectory.appendingPathComponent("app.js"))
    try Data(wasm).write(to: assetDirectory.appendingPathComponent("swiftterm.wasm"))

    let router = makeHTTPRouter(
        publicDirectory: publicDirectory.path,
        assetDirectory: assetDirectory.path
    )
    let app = Application(responder: router.buildResponder())
    try await app.test(.router) { client in
        try await client.execute(uri: "/", method: .get) { response in
            #expect(response.status == .ok)
            #expect(Array(response.body.readableBytesView) == Array(html.utf8))
            #expect(response.headers[.contentType]?.hasPrefix("text/html") == true)
        }
        try await client.execute(uri: "/app.js", method: .get) { response in
            #expect(response.status == .ok)
            #expect(Array(response.body.readableBytesView) == Array(javascript.utf8))
            #expect(response.headers[.contentType]?.contains("javascript") == true)
        }
        try await client.execute(uri: "/assets/swiftterm.wasm", method: .get) { response in
            #expect(response.status == .ok)
            #expect(Array(response.body.readableBytesView) == wasm)
            #expect(response.headers[.contentType] == "application/wasm")
        }
        try await client.execute(uri: "/swiftterm.wasm", method: .get) { response in
            #expect(response.status == .notFound)
        }
        try await client.execute(uri: "/assets/missing.wasm", method: .get) { response in
            #expect(response.status == .notFound)
        }
    }
}
