//
//  KittyQueryTransmissionTests.swift
//
//  A support query (`a=q`) has to honour the transmission medium in `t=`.
//
//  It used to always decode the payload as direct (`t=d`) pixel data. Clients probe
//  file support with `a=q,t=f,f=32,s=1,v=1` whose payload is a *file path*, so
//  checking that path's length against the `1 x 1 x 4` bytes implied by
//  `f=32,s=1,v=1` rejected it as `EINVAL: bad payload`. Clients read the error as
//  "this terminal cannot do file transfers" and fall back to sending every frame
//  inline through the pty, which is orders of magnitude more data - all of it
//  parsed and decompressed on the thread feeding the terminal.
//
//  Queries load images without storing them. The terminal must still delete
//  temporary files (`t=t`) and unlink shared memory (`t=s`) after reading.
//
#if os(macOS)
import Testing
import Foundation
import Darwin

@testable import SwiftTerm

final class KittyQueryTransmissionTests {
    @_silgen_name("shm_open")
    private static func swiftShmOpen(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32

    private final class CaptureDelegate: TerminalDelegate {
        var sent: [UInt8] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }

        var text: String { String(decoding: sent, as: UTF8.self) }
    }

    private func makeTerminal() -> (Terminal, CaptureDelegate) {
        let delegate = CaptureDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 5))
        return (terminal, delegate)
    }

    private func sendKitty(_ terminal: Terminal, control: String, payload: Data) {
        terminal.feed(text: "\u{1b}_G\(control);\(payload.base64EncodedString())\u{1b}\\")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftterm-kitty-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One RGBA pixel, which is what `f=32,s=1,v=1` describes.
    private let onePixelRGBA = Data([0xff, 0x00, 0x00, 0xff])

    // MARK: - the regression

    /// A file-medium query answers OK. This is the probe real clients send, and
    /// answering it with an error is what pushed them onto the inline path.
    @Test func testFileTransmissionQueryIsAnswered() throws {
        let (terminal, delegate) = makeTerminal()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("probe.rgba")
        try onePixelRGBA.write(to: file)

        sendKitty(terminal, control: "i=300,a=q,t=f,f=32,s=1,v=1", payload: Data(file.path.utf8))

        #expect(delegate.text.contains("OK"))
        #expect(!delegate.text.contains("EINVAL"))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// A query stores nothing - it only reports whether the medium works.
    @Test func testFileTransmissionQueryDoesNotStoreImage() throws {
        let (terminal, _) = makeTerminal()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("probe.rgba")
        try onePixelRGBA.write(to: file)

        sendKitty(terminal, control: "i=300,a=q,t=f,f=32,s=1,v=1", payload: Data(file.path.utf8))

        #expect(terminal.kittyGraphicsState.imagesById[300] == nil)
    }

    /// A query must delete its temporary source without storing the image.
    @Test func testTemporaryFileQueryDeletesTheFile() throws {
        let (terminal, delegate) = makeTerminal()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // `t=t` additionally requires the path to be a temp path containing
        // "tty-graphics-protocol"
        let file = dir.appendingPathComponent("tty-graphics-protocol-probe")
        try onePixelRGBA.write(to: file)

        sendKitty(terminal, control: "i=301,a=q,t=t,f=32,s=1,v=1", payload: Data(file.path.utf8))

        #expect(delegate.text.contains("OK"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(terminal.kittyGraphicsState.imagesById[301] == nil)
    }

    /// The ownership transfer still happens for a real transmission, so the
    /// fix does not turn `t=t` into a leak.
    @Test func testTemporaryFileTransmitStillDeletesTheFile() throws {
        let (terminal, _) = makeTerminal()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("tty-graphics-protocol-transmit")
        try onePixelRGBA.write(to: file)

        sendKitty(terminal, control: "i=302,a=t,t=t,f=32,s=1,v=1", payload: Data(file.path.utf8))

        #expect(terminal.kittyGraphicsState.imagesById[302] != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Both queries and transmissions must unlink the shared memory source.
    @Test(arguments: ["q", "t"])
    func testSharedMemoryLoadUnlinksSource(action: String) throws {
        let (terminal, delegate) = makeTerminal()
        // Keep the name below the macOS shared memory name limit.
        let name = "/stq-" + UUID().uuidString.prefix(16)
        let fd = name.withCString { Self.swiftShmOpen($0, O_CREAT | O_EXCL | O_RDWR, 0o600) }
        try #require(fd >= 0)
        defer {
            close(fd)
            _ = name.withCString { shm_unlink($0) }
        }
        try #require(ftruncate(fd, off_t(onePixelRGBA.count)) == 0)
        let map = mmap(nil, onePixelRGBA.count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        try #require(map != MAP_FAILED)
        let pointer = try #require(map)
        defer { munmap(pointer, onePixelRGBA.count) }
        onePixelRGBA.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: onePixelRGBA.count)

        sendKitty(terminal, control: "i=307,a=\(action),t=s,f=32,s=1,v=1", payload: Data(name.utf8))

        #expect(delegate.text == "\u{1b}_Gi=307;OK\u{1b}\\")
        #expect((terminal.kittyGraphicsState.imagesById[307] == nil) == (action == "q"))
        let reopened = name.withCString { Self.swiftShmOpen($0, O_RDONLY, 0) }
        let reopenError = errno
        defer { if reopened >= 0 { close(reopened) } }
        #expect(reopened < 0)
        #expect(reopenError == ENOENT)
    }

    // MARK: - the medium is still validated

    /// Honouring `t=` must not mean accepting anything: a path that does not
    /// exist is still an error.
    @Test func testFileTransmissionQueryRejectsMissingFile() throws {
        let (terminal, delegate) = makeTerminal()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("not-there.rgba")

        sendKitty(terminal, control: "i=303,a=q,t=f,f=32,s=1,v=1", payload: Data(missing.path.utf8))

        #expect(delegate.text.contains("EINVAL"))
        #expect(!delegate.text.contains(";OK"))
    }

    /// A direct query keeps validating the payload as pixel data, which is what
    /// it did before.
    @Test func testDirectTransmissionQueryStillValidatesPayload() {
        let (terminal, delegate) = makeTerminal()

        // 4 bytes for one RGBA pixel: correct
        sendKitty(terminal, control: "i=304,a=q,t=d,f=32,s=1,v=1", payload: onePixelRGBA)
        #expect(delegate.text.contains("OK"))

        let (terminal2, delegate2) = makeTerminal()
        // 3 bytes where 4 are required: still rejected
        sendKitty(terminal2, control: "i=305,a=q,t=d,f=32,s=1,v=1", payload: Data([1, 2, 3]))
        #expect(delegate2.text.contains("EINVAL"))
    }

    /// An unknown medium is reported as unsupported rather than silently accepted.
    @Test func testUnknownTransmissionQueryIsRejected() {
        let (terminal, delegate) = makeTerminal()

        sendKitty(terminal, control: "i=306,a=q,t=z,f=32,s=1,v=1", payload: onePixelRGBA)

        #expect(delegate.text.contains("ENOTSUP"))
    }
}
#endif
