//
//  KittyTransmissionTests.swift
//
#if os(macOS)
import XCTest
import Foundation
import Darwin

@testable import SwiftTerm

final class KittyTransmissionTests: XCTestCase {
    @_silgen_name("shm_open")
    private static func swiftShmOpen(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32

    private func makeHeadlessTerminal() -> HeadlessTerminal {
        HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
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
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/xcAAwMCAO6V2yEAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: base64) else {
            XCTFail("failed to decode png data")
            return
        }
        try data.write(to: url)
    }

    private func createSharedMemory(name: String, bytes: [UInt8]) -> (ok: Bool, errorCode: Int32) {
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

    func testKittyTemporaryFileNameRejected() throws {
        let h = makeHeadlessTerminal()
        let t = h.terminal!
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("image.data")
        try Data([1, 2, 3]).write(to: fileURL)

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=t,i=1",
                  payload: Data(fileURL.path.utf8))

        XCTAssertNil(t.kittyGraphicsState.imagesById[1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testKittyTemporaryFileDeleted() throws {
        let h = makeHeadlessTerminal()
        let t = h.terminal!
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("tty-graphics-protocol-test.data")
        try Data([1, 2, 3]).write(to: fileURL)

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=t,i=1",
                  payload: Data(fileURL.path.utf8))

        XCTAssertNotNil(t.kittyGraphicsState.imagesById[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testKittyFileSymlinkBlockedByRealPath() throws {
        let h = makeHeadlessTerminal()
        let t = h.terminal!
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let linkURL = dir.appendingPathComponent("image-link.data")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: URL(fileURLWithPath: "/dev/null"))

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=f,i=1",
                  payload: Data(linkURL.path.utf8))

        XCTAssertNil(t.kittyGraphicsState.imagesById[1])
    }

    func testKittyFileNullByteRejected() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!
        let payload = Data([UInt8]("/tmp/tty-graphics-protocol".utf8) + [0] + [UInt8]("x".utf8))

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=f,i=1",
                  payload: payload)

        XCTAssertNil(t.kittyGraphicsState.imagesById[1])
    }

    func testKittyFileOffsetAndSize() throws {
        let h = makeHeadlessTerminal()
        let t = h.terminal!
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("image.data")
        let bytes: [UInt8] = [10, 20, 30, 40, 50, 60]
        try Data(bytes).write(to: fileURL)

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=f,i=1,O=3,S=3",
                  payload: Data(fileURL.path.utf8))

        guard let image = t.kittyGraphicsState.imagesById[1] else {
            XCTFail("image not loaded")
            return
        }
        switch image.payload {
        case .rgba(let bytes, let width, let height):
            XCTAssertEqual(width, 1)
            XCTAssertEqual(height, 1)
            XCTAssertEqual(bytes, [40, 50, 60, 255])
        case .png:
            XCTFail("unexpected png payload")
        }
    }

    func testKittyPngFileLoad() throws {
        let h = makeHeadlessTerminal()
        let t = h.terminal!
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("tty-graphics-protocol-image.png")
        try writePngData(to: fileURL)

        sendKitty(terminal: t,
                  control: "f=100,t=f,i=1",
                  payload: Data(fileURL.path.utf8))

        guard let image = t.kittyGraphicsState.imagesById[1] else {
            XCTFail("image not loaded")
            return
        }
        switch image.payload {
        case .png:
            XCTAssertTrue(true)
        case .rgba:
            XCTFail("expected png payload")
        }
    }

    func testKittyDimensionLimitRejected() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        let payload = Data("AAAA".utf8)
        sendKitty(terminal: t,
                  control: "f=24,s=10001,v=1,t=d,i=1",
                  payload: payload)

        XCTAssertNil(t.kittyGraphicsState.imagesById[1])
    }

    func testKittySharedMemoryLoad() throws {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        let name = "/swiftterm-kitty-\(UUID().uuidString)"
        let bytes: [UInt8] = [1, 2, 3]
        let createResult = createSharedMemory(name: name, bytes: bytes)
        guard createResult.ok else {
            throw XCTSkip("shm_open unavailable (errno=\(createResult.errorCode))")
        }
        defer { _ = name.withCString { shm_unlink($0) } }

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=s,i=1",
                  payload: Data(name.utf8))

        XCTAssertNotNil(t.kittyGraphicsState.imagesById[1])

        let reopen = name.withCString { KittyTransmissionTests.swiftShmOpen($0, O_RDONLY, 0) }
        XCTAssertLessThan(reopen, 0)
    }

    func testKittySharedMemoryBoundsRejected() throws {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        let name = "/swiftterm-kitty-\(UUID().uuidString)"
        let bytes: [UInt8] = [1, 2, 3]
        let createResult = createSharedMemory(name: name, bytes: bytes)
        guard createResult.ok else {
            throw XCTSkip("shm_open unavailable (errno=\(createResult.errorCode))")
        }
        defer { _ = name.withCString { shm_unlink($0) } }

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=s,i=1,O=10",
                  payload: Data(name.utf8))

        XCTAssertNil(t.kittyGraphicsState.imagesById[1])
    }

    func testKittyDevPathRejected() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!
        let payload = Data("/dev/null".utf8)

        sendKitty(terminal: t,
                  control: "f=24,s=1,v=1,t=f,i=1",
                  payload: payload)

        XCTAssertNil(t.kittyGraphicsState.imagesById[1])
    }
}
#endif
