import Foundation
import Testing
@testable import WebTerminalServer
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func filePacket(_ path: String, controls: String = "a=T,t=f,f=32,q=2") -> [UInt8] {
    Array("\u{1b}_G\(controls);\(Data(path.utf8).base64EncodedString())\u{1b}\\".utf8)
}

private func collectTransfer(_ transfer: KittyFileTransfer, mailbox: OutputMailbox,
                             parts: [[UInt8]]) async -> [UInt8] {
    Thread.detachNewThread {
        for part in parts { transfer.receive(part[...]) }
        mailbox.finish(exitCode: 0)
    }
    var result: [UInt8] = []
    while let event = await mailbox.next() {
        if case .bytes(let bytes) = event { result += bytes }
    }
    return result
}

@Test(.timeLimit(.minutes(1))) func kittyFileChunksPreserveControlsAndReadRange() async throws {
    let mailbox = OutputMailbox(capacity: 2048)
    let transfer = try KittyFileTransfer(output: mailbox)
    defer { transfer.close() }
    let path = transfer.temporaryDirectory.appendingPathComponent("tty-graphics-protocol-surface-test.rgba")
    let bytes = (0..<90000).map { UInt8(truncatingIfNeeded: $0) }
    try Data(bytes).write(to: path)
    let packet = filePacket(path.path, controls: "a=T,t=f,f=32,s=150,v=100,i=42,p=1,c=10,r=5,C=1,z=-1073741826,q=2,O=7,S=80000")
    let wire = await collectTransfer(transfer, mailbox: mailbox, parts: packet.map { [$0] })
    let packets = String(decoding: wire, as: UTF8.self).components(separatedBy: "\u{1b}\\").filter { !$0.isEmpty }
    #expect(packets.count > 1)
    #expect(packets.first?.hasPrefix("\u{1b}_Ga=T,f=32,s=150,v=100,i=42,p=1,c=10,r=5,C=1,z=-1073741826,q=2,t=d,m=1;") == true)
    var encoded = ""
    for (index, packet) in packets.enumerated() {
        let pieces = packet.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        #expect(pieces.count == 2)
        guard pieces.count == 2 else { continue }
        #expect(pieces[1].utf8.count <= 4096)
        #expect(pieces[0].hasSuffix(index == packets.count - 1 ? "m=0" : "m=1"))
        if index > 0 { #expect(pieces[0].hasPrefix("\u{1b}_Gq=2,m=")) }
        encoded += pieces[1]
    }
    #expect(Data(base64Encoded: encoded) == Data(bytes[7..<80007]))
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test(.timeLimit(.minutes(1))) func kittyUnsafeFilesAndOtherSequencesPassThrough() async throws {
    let mailbox = OutputMailbox()
    let transfer = try KittyFileTransfer(output: mailbox)
    defer { transfer.close() }
    let root = transfer.temporaryDirectory
    let safe = root.appendingPathComponent("tty-graphics-protocol-safe")
    try Data([1, 2, 3]).write(to: safe)
    let link = root.appendingPathComponent("tty-graphics-protocol-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: safe)
    let fifo = root.appendingPathComponent("tty-graphics-protocol-fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let input = Array("plain\u{1b}[31m\u{1b}_other\u{1b}\\".utf8)
        + Array("\u{1b}]title;".utf8) + filePacket(safe.path) + [7]
        + filePacket(link.path) + filePacket(fifo.path)
        + filePacket(root.path + "/../tty-graphics-protocol-outside")
        + filePacket("/etc/passwd")
        + Array("\u{1b}_Ga=d,d=A\u{1b}\\end".utf8)
    let result = await collectTransfer(transfer, mailbox: mailbox, parts: input.map { [$0] })
    #expect(result == input)
}

@Test(.timeLimit(.minutes(1))) func kittyTemporaryFileIsRemovedAfterTransfer() async throws {
    let mailbox = OutputMailbox()
    let transfer = try KittyFileTransfer(output: mailbox)
    let root = transfer.temporaryDirectory
    defer { transfer.close() }
    let path = root.appendingPathComponent("tty-graphics-protocol-temporary")
    try Data([0, 1, 2]).write(to: path)
    let result = await collectTransfer(transfer, mailbox: mailbox,
        parts: [filePacket(path.path, controls: "a=T,t=t,f=24,s=1,v=1")])
    #expect(String(decoding: result, as: UTF8.self) == "\u{1b}_Ga=T,f=24,s=1,v=1,t=d,m=0;AAEC\u{1b}\\")
    #expect(!FileManager.default.fileExists(atPath: path.path))
    transfer.close()
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test(.timeLimit(.minutes(1))) func kittyCloseReleasesBlockedOutput() async throws {
    let mailbox = OutputMailbox(capacity: 1)
    let transfer = try KittyFileTransfer(output: mailbox)
    let path = transfer.temporaryDirectory.appendingPathComponent("tty-graphics-protocol-blocked")
    try Data(repeating: 7, count: 100000).write(to: path)
    let packet = filePacket(path.path)
    let completed = Task {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                transfer.receive(packet[...])
                continuation.resume()
            }
        }
    }
    // Receiving one byte proves that the producer reached the bounded mailbox.
    #expect(await mailbox.next() == .bytes([27]))
    mailbox.close()
    transfer.close()
    await completed.value
    #expect(await mailbox.next() == nil)
    #expect(!FileManager.default.fileExists(atPath: transfer.temporaryDirectory.path))
}

@Test(.timeLimit(.minutes(1))) func kittyRegularOverlayIsReadableButNotDeletableAsTemporary() async throws {
    let mailbox = OutputMailbox()
    let transfer = try KittyFileTransfer(output: mailbox)
    defer { transfer.close() }
    let path = transfer.temporaryDirectory.appendingPathComponent("surface-overlay-123-456.rgba")
    try Data([0, 1, 2]).write(to: path)
    let temporary = filePacket(path.path, controls: "a=T,t=t,f=24,s=1,v=1")
    let result = await collectTransfer(transfer, mailbox: mailbox,
        parts: [filePacket(path.path, controls: "a=T,t=f,f=24,s=1,v=1"), temporary])
    let converted = Array("\u{1b}_Ga=T,f=24,s=1,v=1,t=d,m=0;AAEC\u{1b}\\".utf8)
    #expect(result == converted + temporary)
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test(.timeLimit(.minutes(1))) func kittyFileQueryRetainsReplyIdentity() async throws {
    let mailbox = OutputMailbox()
    let transfer = try KittyFileTransfer(output: mailbox)
    defer { transfer.close() }
    let path = transfer.temporaryDirectory.appendingPathComponent("query-probe")
    try Data([0, 1, 2]).write(to: path)
    let result = await collectTransfer(transfer, mailbox: mailbox,
        parts: [filePacket(path.path, controls: "a=q,t=f,f=24,s=1,v=1,i=987,q=1")])
    #expect(String(decoding: result, as: UTF8.self) == "\u{1b}_Ga=q,f=24,s=1,v=1,i=987,q=1,t=d,m=0;AAEC\u{1b}\\")
}
