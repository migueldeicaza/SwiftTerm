//
//  KittyTransmissionTests.swift
//
import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@testable import SwiftTerm

final class KittyTransmissionTests {
    #if !os(Windows)
    #if canImport(Darwin)
    // Darwin's public shm_open is variadic; call the fixed-arity syscall shim.
    @_silgen_name("__shm_open")
    #else
    @_silgen_name("shm_open")
    #endif
    private static func swiftShmOpen(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32
    #endif

    private func makeTerminal(trustedTemporaryDirectory: URL? = nil) -> Terminal {
        let graphics = KittyGraphicsConfiguration(
            localMediaPolicy: .all,
            trustedTemporaryDirectory: trustedTemporaryDirectory)
        return TerminalTestHarness.makeTerminal(
            cols: 10, rows: 5, kittyGraphics: graphics).terminal
    }

    private func sendKitty(terminal: Terminal, control: String, payload: Data) {
        let base64 = payload.base64EncodedString()
        let sequence = "\u{1b}_G\(control);\(base64)\u{1b}\\"
        terminal.feed(text: sequence)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftterm-kitty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePngData(to url: URL) throws {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX/AAAZ4gk3AAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="
        guard let data = Data(base64Encoded: base64) else {
            Issue.record("failed to decode png data")
            return
        }
        try data.write(to: url)
    }

    #if !os(Windows)
    private static func createSharedMemory(name: String, bytes: [UInt8]) -> (ok: Bool, errorCode: Int32) {
        let fd = name.withCString { KittyTransmissionTests.swiftShmOpen($0, O_CREAT | O_EXCL | O_RDWR, 0o600) }
        guard fd >= 0 else {
            return (false, errno)
        }
        defer { close(fd) }

        guard ftruncate(fd, off_t(bytes.count)) == 0 else {
            _ = name.withCString { shm_unlink($0) }
            return (false, errno)
        }

        guard let map = mmap(nil, bytes.count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              map != MAP_FAILED else {
            _ = name.withCString { shm_unlink($0) }
            return (false, errno)
        }
        defer { munmap(map, bytes.count) }

        bytes.withUnsafeBytes { buf in
            if let base = buf.baseAddress {
                memcpy(map, base, bytes.count)
            }
        }
        return (true, 0)
    }

    private static func sharedMemoryAvailable() -> Bool {
        let name = "/st\(UUID().uuidString.prefix(12))"
        let bytes: [UInt8] = [0]
        let result = createSharedMemory(name: name, bytes: bytes)
        if result.ok {
            _ = name.withCString { shm_unlink($0) }
        }
        return result.ok
    }
    #endif

    #if !os(Windows)
    @Test func testKittyTemporaryFileNameRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeTerminal(trustedTemporaryDirectory: dir)

        let fileURL = dir.appendingPathComponent("image.data")
        try Data([1, 2, 3]).write(to: fileURL)

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=t,i=1",
                  payload: Data(fileURL.path.utf8))

        #expect(t.kittyGraphicsState.imagesById[1] == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func testKittyTemporaryFileDeleted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeTerminal(trustedTemporaryDirectory: dir)

        let fileURL = dir.appendingPathComponent("tty-graphics-protocol-test.data")
        try Data([1, 2, 3]).write(to: fileURL)

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=t,i=1",
                  payload: Data(fileURL.path.utf8))

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func testKittyFileSymlinkBlockedByRealPath() throws {
        let t = makeTerminal()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let linkURL = dir.appendingPathComponent("image-link.data")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: URL(fileURLWithPath: "/dev/null"))

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=f,i=1",
                  payload: Data(linkURL.path.utf8))

        #expect(t.kittyGraphicsState.imagesById[1] == nil)
    }

    @Test func testKittyFileNullByteRejected() {
        let t = makeTerminal()
        let payload = Data([UInt8]("/tmp/tty-graphics-protocol".utf8) + [0] + [UInt8]("x".utf8))

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=f,i=1",
                  payload: payload)

        #expect(t.kittyGraphicsState.imagesById[1] == nil)
    }

    @Test func testKittyFileOffsetAndSize() throws {
        let t = makeTerminal()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("image.data")
        let bytes: [UInt8] = [10, 20, 30, 40, 50, 60]
        try Data(bytes).write(to: fileURL)

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=f,i=1,O=3,S=3",
                  payload: Data(fileURL.path.utf8))

        guard let image = t.kittyGraphicsState.imagesById[1] else {
            Issue.record("image not loaded")
            return
        }
        switch image.payload {
        case .rgba(let bytes, let width, let height):
            #expect(width == 1)
            #expect(height == 1)
            #expect(bytes == [40, 50, 60, 255])
        }
    }

    @Test func testKittyPngFileLoad() throws {
        let t = makeTerminal()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("tty-graphics-protocol-image.png")
        try writePngData(to: fileURL)

        sendKitty(terminal: t,
                  control: "f=100,t=f,i=1",
                  payload: Data(fileURL.path.utf8))

        guard let image = t.kittyGraphicsState.imagesById[1] else {
            Issue.record("image not loaded")
            return
        }
        guard case .rgba(let bytes, let width, let height) = image.payload else {
            Issue.record("expected canonical RGBA payload")
            return
        }
        #expect(width == 1)
        #expect(height == 1)
        #expect(bytes.count == 4)
    }
    #endif

    @Test func testKittyDimensionLimitRejected() {
        let t = makeTerminal()

        let payload = Data("AAAA".utf8)
        sendKitty(terminal: t,
                  control: "f=24,s=10001,v=1,t=d,i=1",
                  payload: payload)

        #expect(t.kittyGraphicsState.imagesById[1] == nil)
    }

    #if !os(Windows)
    @Test(.enabled(if: KittyTransmissionTests.sharedMemoryAvailable()))
    func testKittySharedMemoryLoad() throws {
        let configuration = KittyGraphicsConfiguration(localMediaPolicy: .all)
        let (t, delegate) = TerminalTestHarness.makeTerminal(
            cols: 10, rows: 5, kittyGraphics: configuration)

        let name = "/st\(UUID().uuidString.prefix(12))"
        let bytes: [UInt8] = [1, 2, 3]
        let createResult = Self.createSharedMemory(name: name, bytes: bytes)
        guard createResult.ok else {
            Issue.record("shm_open unavailable (errno=\(createResult.errorCode))")
            return
        }
        defer { _ = name.withCString { shm_unlink($0) } }

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=s,i=1",
                  payload: Data(name.utf8))

        #expect(
            t.kittyGraphicsState.imagesById[1] != nil,
            "response: \(delegate.sentData.last.map { String(decoding: $0, as: UTF8.self) } ?? "none")")

        let reopen = name.withCString { KittyTransmissionTests.swiftShmOpen($0, O_RDONLY, 0) }
        #expect(reopen < 0)
    }

    @Test(.enabled(if: KittyTransmissionTests.sharedMemoryAvailable()))
    func testKittySharedMemoryBoundsRejected() throws {
        let configuration = KittyGraphicsConfiguration(localMediaPolicy: .all)
        let (t, _) = TerminalTestHarness.makeTerminal(
            cols: 10, rows: 5, kittyGraphics: configuration)

        let name = "/st\(UUID().uuidString.prefix(12))"
        let bytes: [UInt8] = [1, 2, 3]
        let createResult = Self.createSharedMemory(name: name, bytes: bytes)
        guard createResult.ok else {
            Issue.record("shm_open unavailable (errno=\(createResult.errorCode))")
            return
        }
        defer { _ = name.withCString { shm_unlink($0) } }

        // macOS rounds a shared memory object up to a whole page (16 KiB
        // on Apple silicon), so a small offset would still be inside it.
        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=s,i=1,O=1048576",
                  payload: Data(name.utf8))

        #expect(t.kittyGraphicsState.imagesById[1] == nil)
    }
    #endif

    #if !os(Windows) && !os(WASI) && !os(Android)
    @Test func testKittySharedMemoryNameValidation() {
        #expect(Terminal.isPlausibleSharedMemoryName("/im3f2a-0"))
        #expect(Terminal.isPlausibleSharedMemoryName("/kitty img 1"))
        #expect(!Terminal.isPlausibleSharedMemoryName(""))
        #expect(!Terminal.isPlausibleSharedMemoryName("/"))
        #expect(!Terminal.isPlausibleSharedMemoryName("noslash"))
        #expect(!Terminal.isPlausibleSharedMemoryName("/a/b"))
        #if canImport(Darwin)
        #expect(Terminal.isPlausibleSharedMemoryName("/" + String(repeating: "a", count: 30)))
        #expect(!Terminal.isPlausibleSharedMemoryName("/" + String(repeating: "a", count: 31)))
        #else
        #expect(Terminal.isPlausibleSharedMemoryName("/" + String(repeating: "a", count: 255)))
        #expect(!Terminal.isPlausibleSharedMemoryName("/" + String(repeating: "a", count: 256)))
        #endif
    }

    private static func reopenSharedMemory(_ name: String) -> (fd: Int32, error: Int32) {
        name.withCString { path in
            let fd = KittyTransmissionTests.swiftShmOpen(path, O_RDONLY, 0)
            return (fd, fd < 0 ? errno : 0)
        }
    }

    private static func sharedMemoryIsGone(_ name: String) -> Bool {
        let result = reopenSharedMemory(name)
        if result.fd >= 0 {
            close(result.fd)
            return false
        }
        return result.error == ENOENT
    }

    private static func sharedMemoryStillExists(_ name: String) -> Bool {
        let result = reopenSharedMemory(name)
        guard result.fd >= 0 else {
            return false
        }
        close(result.fd)
        return true
    }

    /// Raw RGB with s= and v= but no S= or O=, sent with U=1 for Unicode
    /// placeholder display: the shape Claude Code uses for plugin frames.
    @Test(.enabled(if: KittyTransmissionTests.sharedMemoryAvailable()))
    func testKittyUnicodePlaceholderFrameFromSharedMemory() throws {
        let configuration = KittyGraphicsConfiguration(localMediaPolicy: [.sharedMemory])
        let (t, delegate) = TerminalTestHarness.makeTerminal(
            cols: 10, rows: 5, kittyGraphics: configuration)

        let name = "/im\(UUID().uuidString.prefix(8))-0"
        let bytes = [UInt8](repeating: 0x7f, count: 4 * 2 * 3)
        let createResult = Self.createSharedMemory(name: name, bytes: bytes)
        guard createResult.ok else {
            Issue.record("shm_open unavailable (errno=\(createResult.errorCode))")
            return
        }
        defer { _ = name.withCString { shm_unlink($0) } }

        sendKitty(terminal: t,
                  control: "a=T,U=1,q=1,f=24,s=4,v=2,t=s,i=5,c=2,r=1",
                  payload: Data(name.utf8))

        #expect(
            t.kittyGraphicsState.imagesById[5] != nil,
            "response: \(delegate.sentData.last.map { String(decoding: $0, as: UTF8.self) } ?? "none")")
        #expect(Self.sharedMemoryIsGone(name))
    }

    @Test(.enabled(if: KittyTransmissionTests.sharedMemoryAvailable()))
    func testKittySharedMemoryNameWithoutLeadingSlashIsRefused() throws {
        let configuration = KittyGraphicsConfiguration(localMediaPolicy: .all)
        let (t, _) = TerminalTestHarness.makeTerminal(
            cols: 10, rows: 5, kittyGraphics: configuration)

        // The OS accepts this name, so the object exists; a valid open
        // would read it and unlink it, so finding it still there shows the
        // name was refused.
        let name = "st\(UUID().uuidString.prefix(12))"
        let createResult = Self.createSharedMemory(name: name, bytes: [1, 2, 3])
        guard createResult.ok else {
            Issue.record("shm_open unavailable (errno=\(createResult.errorCode))")
            return
        }
        defer { _ = name.withCString { shm_unlink($0) } }

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=s,i=1",
                  payload: Data(name.utf8))

        #expect(t.kittyGraphicsState.imagesById[1] == nil)
        #expect(Self.sharedMemoryStillExists(name))
    }

    @Test(.enabled(if: KittyTransmissionTests.sharedMemoryAvailable()))
    func testKittySharedMemoryOffsetCountsTheImageFromTheOffset() throws {
        let configuration = KittyGraphicsConfiguration(localMediaPolicy: .all)
        let (t, _) = TerminalTestHarness.makeTerminal(
            cols: 10, rows: 5, kittyGraphics: configuration)

        let name = "/st\(UUID().uuidString.prefix(12))"
        let createResult = Self.createSharedMemory(name: name, bytes: [9, 9, 1, 2, 3])
        guard createResult.ok else {
            Issue.record("shm_open unavailable (errno=\(createResult.errorCode))")
            return
        }
        defer { _ = name.withCString { shm_unlink($0) } }

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=s,i=1,O=2",
                  payload: Data(name.utf8))

        guard let image = t.kittyGraphicsState.imagesById[1] else {
            Issue.record("image not loaded")
            return
        }
        switch image.payload {
        case .rgba(let bytes, _, _):
            #expect(bytes == [1, 2, 3, 255])
        }
    }

    @Test(.enabled(if: KittyTransmissionTests.sharedMemoryAvailable()))
    func testKittySharedMemorySizeIsClampedToTheObject() throws {
        let configuration = KittyGraphicsConfiguration(localMediaPolicy: .all)
        let (t, _) = TerminalTestHarness.makeTerminal(
            cols: 10, rows: 5, kittyGraphics: configuration)

        let name = "/st\(UUID().uuidString.prefix(12))"
        let createResult = Self.createSharedMemory(name: name, bytes: [9, 1, 2, 3])
        guard createResult.ok else {
            Issue.record("shm_open unavailable (errno=\(createResult.errorCode))")
            return
        }
        defer { _ = name.withCString { shm_unlink($0) } }

        // S= runs past the end of the object; kitty reads what is there.
        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=s,i=1,O=1,S=1048576",
                  payload: Data(name.utf8))

        guard let image = t.kittyGraphicsState.imagesById[1] else {
            Issue.record("image not loaded")
            return
        }
        switch image.payload {
        case .rgba(let bytes, _, _):
            #expect(bytes == [1, 2, 3, 255])
        }
    }
    #endif

    #if !os(Windows)
    @Test func testKittyDevPathRejected() {
        let t = makeTerminal()
        let payload = Data("/dev/null".utf8)

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=f,i=1",
                  payload: payload)

        #expect(t.kittyGraphicsState.imagesById[1] == nil)
    }
    #endif
}
