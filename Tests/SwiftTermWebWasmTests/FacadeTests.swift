import XCTest
import SwiftTerm
@testable import SwiftTermWebWasm

final class FacadeTests: XCTestCase {
    private func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << ($1 * 8) }
    }
    private func feed(_ handle: UInt32, _ text: String) -> Int32 {
        WasmRuntime.shared.mutate(handle) { entry in
            entry.terminal.feed(buffer: Array(text.utf8)[...])
            return 0
        }
    }
    func testHandleGenerationRejectsReuseAndDoubleDestroy() {
        let first = terminalCreate(4, 2, 0)
        XCTAssertNotEqual(first, 0)
        XCTAssertEqual(terminalDestroy(first), 0)
        let second = terminalCreate(4, 2, 0)
        defer { _ = terminalDestroy(second) }
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(terminalDestroy(first), ABI.invalidHandle)
        XCTAssertEqual(terminalReset(first), ABI.invalidHandle)
        XCTAssertEqual(terminalReset(0), ABI.invalidHandle)
        XCTAssertEqual(terminalReset(second), 0)
    }
    func testLimitsAndInvalidFlags() {
        XCTAssertEqual(terminalCreate(1, 1, 0), 0)
        XCTAssertEqual(terminalCreate(2, 0, 0), 0)
        XCTAssertEqual(terminalCreate(1025, 1, 0), 0)
        XCTAssertEqual(terminalCreate(2, 1, 100001), 0)
        let handle = terminalCreate(4, 2, 0)
        defer { _ = terminalDestroy(handle) }
        XCTAssertEqual(terminalSetFocus(handle, 2), ABI.invalidArgument)
        XCTAssertEqual(terminalSetVisibility(handle, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalSetVisibility(handle, 3), ABI.invalidArgument)
        XCTAssertEqual(terminalResize(handle, 4, 2, UInt32.max, 1), ABI.invalidArgument)
        XCTAssertEqual(terminalWrite(handle, 0, UInt32.max), ABI.invalidArgument)
        XCTAssertEqual(terminalWrite(handle, 0, 0), 0)
        XCTAssertEqual(terminalWrite(handle, 1, 1), ABI.outOfBounds)
    }
    func testBusyAndRevisionExhaustion() {
        let handle = terminalCreate(4, 2, 0)
        defer { _ = terminalDestroy(handle) }
        let entry = WasmRuntime.shared.handles.get(handle)!
        entry.busy = true
        XCTAssertEqual(terminalReset(handle), ABI.busy)
        XCTAssertEqual(renderUpdate(handle), ABI.busy)
        entry.busy = false
        entry.revision = UInt64.max
        XCTAssertEqual(terminalReset(handle), ABI.internalError)
        XCTAssertEqual(entry.revision, UInt64.max)
    }
    func testStaleCleanDoesNotEraseNewInput() {
        let handle = terminalCreate(4, 2, 0)
        defer { _ = terminalDestroy(handle) }
        XCTAssertEqual(renderUpdate(handle), 2)
        let entry = WasmRuntime.shared.handles.get(handle)!
        let before = entry.snapshot
        XCTAssertEqual(word(before, 0), 0x53575453)
        XCTAssertEqual(word(before, 8), 1)
        XCTAssertEqual(word(before, 32), 2)
        XCTAssertEqual(word(before, 84), 8)
        XCTAssertEqual(feed(handle, "A"), 0)
        XCTAssertEqual(renderClean(handle, 1, 0), ABI.staleGeneration)
        XCTAssertNotEqual(renderUpdate(handle), 0)
        XCTAssertEqual(word(entry.snapshot, 8), 2)
        XCTAssertEqual(renderClean(handle, 2, 0), 0)
        XCTAssertEqual(renderUpdate(handle), 0)
        XCTAssertEqual(entry.snapshot.count, 104)
        XCTAssertEqual(word(entry.snapshot, 32), 0)
        XCTAssertEqual(word(entry.snapshot, 36), UInt32.max)
        XCTAssertEqual(word(entry.snapshot, 84), 0)
    }
    func testSnapshotGraphemesColorsAndWideCells() {
        let handle = terminalCreate(8, 2, 0)
        defer { _ = terminalDestroy(handle) }
        XCTAssertEqual(feed(handle, "\u{1b}[38;2;1;2;3m\u{1b}[48;2;4;5;6mA\u{1b}[0me\u{301}界"), 0)
        XCTAssertEqual(renderUpdate(handle), 2)
        let bytes = WasmRuntime.shared.handles.get(handle)!.snapshot
        let cells = Int(word(bytes, 80))
        let text = Int(word(bytes, 88))
        XCTAssertEqual(word(bytes, cells + 8), 0x010203ff)
        XCTAssertEqual(word(bytes, cells + 12), 0x040506ff)
        XCTAssertEqual(bytes[cells + 26], 1)
        let combiningStart = text + Int(word(bytes, cells + 32))
        let combiningLength = Int(word(bytes, cells + 36))
        XCTAssertEqual(Array(bytes[combiningStart..<(combiningStart + combiningLength)]), Array("e\u{301}".utf8))
        XCTAssertEqual(bytes[cells + 64 + 26], 2)
        XCTAssertEqual(bytes[cells + 96 + 26], 0)
        XCTAssertEqual(bytes[cells + 96 + 29] & 4, 4)
        XCTAssertEqual(word(bytes, cells + 96 + 4), 0)
        XCTAssertEqual(word(bytes, cells + 20), 0)
        XCTAssertEqual(bytes[63], 0)
        XCTAssertEqual(word(bytes, 96), 0)
        XCTAssertEqual(word(bytes, 100), 0)
    }
    func testQueueCopiesDoNotConsumeAndOverflowPreservesData() {
        var queue = ByteQueue()
        XCTAssertTrue(queue.append([1, 2, 3][...], limit: 4))
        XCTAssertFalse(queue.append([4, 5][...], limit: 4))
        XCTAssertEqual(Array(queue.bytes), [1, 2, 3])
        XCTAssertEqual(Array(queue.bytes), [1, 2, 3])
        XCTAssertFalse(queue.consume(4))
        XCTAssertTrue(queue.consume(2))
        XCTAssertTrue(queue.append([4, 5, 6][...], limit: 4))
        XCTAssertEqual(Array(queue.bytes), [3, 4, 5, 6])
    }
    func testEventHeaderAndConsume() {
        var events = HostEventQueue()
        XCTAssertTrue(events.append(type: 2, payload: [65, 66]))
        let first = events.first
        XCTAssertEqual(first.count, 18)
        XCTAssertEqual(first[0], 2)
        XCTAssertEqual(word(first, 4), 1)
        XCTAssertEqual(word(first, 8), 2)
        XCTAssertEqual(word(first, 12), 0)
        XCTAssertEqual(events.first, first)
        XCTAssertTrue(events.append(type: 1, payload: []))
        events.consume()
        XCTAssertEqual(word(events.first, 4), 2)
        events.consume()
        XCTAssertTrue(events.first.isEmpty)
        XCTAssertEqual(events.byteCount, 0)
    }
    func testGeneratedRepliesAndHostEvents() {
        let handle = terminalCreate(8, 2, 0)
        defer { _ = terminalDestroy(handle) }
        let entry = WasmRuntime.shared.handles.get(handle)!
        while !entry.host.events.first.isEmpty { entry.host.events.consume() }
        XCTAssertEqual(feed(handle, "\u{1b}[6n\u{7}\u{1b}]2;Title\u{7}"), 0)
        XCTAssertEqual(Array(entry.host.output.bytes), Array("\u{1b}[1;1R".utf8))
        XCTAssertEqual(terminalOutputConsume(handle, UInt32.max), ABI.invalidArgument)
        XCTAssertEqual(terminalOutputSize(handle), 6)
        XCTAssertEqual(entry.host.events.first[0], 1)
        XCTAssertEqual(terminalEventConsume(handle), 0)
        XCTAssertEqual(entry.host.events.first[0], 2)
        XCTAssertEqual(Array(entry.host.events.first.dropFirst(16)), Array("Title".utf8))
    }
    func testFocusDamageAndSynchronizedOutputTimeout() {
        let handle = terminalCreate(8, 2, 0)
        defer { _ = terminalDestroy(handle) }
        XCTAssertEqual(renderUpdate(handle), 2)
        XCTAssertEqual(renderClean(handle, 1, 0), 0)
        XCTAssertEqual(terminalSetFocus(handle, 0), 0)
        XCTAssertEqual(renderUpdate(handle), 2)
        let entry = WasmRuntime.shared.handles.get(handle)!
        XCTAssertEqual(word(entry.snapshot, 16) & 4, 0)
        XCTAssertEqual(feed(handle, "\u{1b}[?2026hABC"), 0)
        XCTAssertNotNil(entry.host.synchronizedOutputDeadline)
        let previousRevision = entry.revision
        entry.host.synchronizedOutputDeadline = 0
        XCTAssertGreaterThanOrEqual(renderUpdate(handle), 0)
        XCTAssertEqual(entry.revision, previousRevision + 1)
        XCTAssertEqual(word(entry.snapshot, 16) & 8, 0)
        var types: [UInt8] = []
        while !entry.host.events.first.isEmpty {
            types.append(entry.host.events.first[0])
            entry.host.events.consume()
        }
        XCTAssertTrue(types.contains(11))
        XCTAssertTrue(types.contains(12))
    }
    func testQueueFailureFromFocusAdvancesRevisionAndRequiresReset() {
        let handle = terminalCreate(8, 2, 0)
        defer { _ = terminalDestroy(handle) }
        let entry = WasmRuntime.shared.handles.get(handle)!
        XCTAssertEqual(feed(handle, "\u{1b}[?1004h"), 0)
        _ = entry.host.output.consume(entry.host.output.count)
        XCTAssertTrue(entry.host.output.append([UInt8](repeating: 0, count: ABI.maximumQueue)[...]))
        let previous = entry.revision
        XCTAssertEqual(terminalSetFocus(handle, 0), ABI.outOfMemory)
        XCTAssertEqual(entry.revision, previous + 1)
        XCTAssertEqual(entry.host.output.count, ABI.maximumQueue)
        XCTAssertEqual(terminalSetFocus(handle, 1), ABI.outOfMemory)
        XCTAssertEqual(entry.revision, previous + 1)
        XCTAssertEqual(terminalOutputConsume(handle, UInt32(ABI.maximumQueue)), 0)
        XCTAssertEqual(terminalReset(handle), 0)
        XCTAssertFalse(entry.host.queueFailure)
    }
    func testNotificationPaletteClipboardAndProgressEvents() {
        let handle = terminalCreate(8, 2, 0)
        defer { _ = terminalDestroy(handle) }
        let entry = WasmRuntime.shared.handles.get(handle)!
        while !entry.host.events.first.isEmpty { entry.host.events.consume() }
        XCTAssertEqual(feed(handle, "\u{1b}]777;notify;Hello;Body\u{7}\u{1b}]4;1;rgb:01/02/03\u{7}\u{1b}]52;c;SGk=\u{7}\u{1b}]9;4;1;42\u{7}\u{1b}[5 q\u{1b}[?1000h"), 0)
        var types: [UInt8] = []
        while !entry.host.events.first.isEmpty {
            let bytes = entry.host.events.first
            types.append(bytes[0])
            if bytes[0] == 5 {
                XCTAssertEqual(word(bytes, 16), 5)
                XCTAssertEqual(word(bytes, 20), 4)
                XCTAssertEqual(Array(bytes.dropFirst(24)), Array("HelloBody".utf8))
            }
            if bytes[0] == 9 {
                XCTAssertEqual(word(bytes, 16), 3)
                XCTAssertEqual(word(bytes, 20), 1)
                XCTAssertEqual(word(bytes, 24), 0x010203ff)
            }
            if bytes[0] == 6 { XCTAssertEqual(Array(bytes.dropFirst(16)), Array("Hi".utf8)) }
            if bytes[0] == 10 { XCTAssertEqual(word(bytes, 20), 42) }
            entry.host.events.consume()
        }
        for type: UInt8 in [5, 6, 8, 9, 10, 14] { XCTAssertTrue(types.contains(type), "Missing event \(type)") }
    }
    func testTimeoutQueueFailureStillAdvancesRevision() {
        let handle = terminalCreate(8, 2, 0)
        defer { _ = terminalDestroy(handle) }
        let entry = WasmRuntime.shared.handles.get(handle)!
        XCTAssertEqual(feed(handle, "\u{1b}[?2026hABC"), 0)
        while !entry.host.events.first.isEmpty { entry.host.events.consume() }
        XCTAssertTrue(entry.host.events.append(type: 2, payload: [UInt8](repeating: 0, count: ABI.maximumQueue - 16)))
        let previous = entry.revision
        entry.host.synchronizedOutputDeadline = 0
        XCTAssertEqual(renderUpdate(handle), ABI.outOfMemory)
        XCTAssertEqual(entry.revision, previous + 1)
        XCTAssertEqual(entry.host.events.byteCount, ABI.maximumQueue)
        XCTAssertTrue(entry.host.queueFailure)
    }
    func testPassiveMetadataAndResizeEventRecords() {
        let entry = TerminalEntry(cols: 8, rows: 2, scrollback: 0)
        while !entry.host.events.first.isEmpty { entry.host.events.consume() }
        entry.host.hostCurrentDirectoryUpdated(source: entry.terminal)
        XCTAssertEqual(entry.host.events.first[0], 4)
        XCTAssertEqual(word(entry.host.events.first, 8), 0)
        entry.host.events.consume()
        entry.host.hostCurrentDocumentUpdated(source: entry.terminal)
        XCTAssertEqual(entry.host.events.first[0], 13)
        XCTAssertEqual(word(entry.host.events.first, 8), 0)
        entry.host.events.consume()
        entry.host.sizeChanged(source: entry.terminal)
        XCTAssertEqual(entry.host.events.first[0], 7)
        XCTAssertEqual(word(entry.host.events.first, 16), 8)
        XCTAssertEqual(word(entry.host.events.first, 20), 2)
        entry.host.events.consume()
        entry.terminal.feed(text: "\u{1b}]7;file:///tmp\u{7}\u{1b}]6;file:///tmp/doc\u{7}")
        XCTAssertTrue(entry.host.events.first.isEmpty)
        XCTAssertNil(entry.terminal.hostCurrentDirectory)
        XCTAssertNil(entry.terminal.hostCurrentDocument)
        XCTAssertFalse(entry.host.isProcessTrusted(source: entry.terminal))
    }
    func testMemoryBoundsUseWideArithmetic() {
        XCTAssertTrue(HostMemory.inBounds(0, 0, memoryBytes: 65536))
        XCTAssertTrue(HostMemory.inBounds(65535, 1, memoryBytes: 65536))
        XCTAssertFalse(HostMemory.inBounds(65535, 2, memoryBytes: 65536))
        XCTAssertFalse(HostMemory.inBounds(0, 1, memoryBytes: 65536))
        XCTAssertFalse(HostMemory.inBounds(UInt32.max, UInt32.max, memoryBytes: 1 << 32))
        XCTAssertTrue(HostMemory.inBounds(UInt32.max, 1, memoryBytes: 1 << 32))
        let memory = HostMemory()
        XCTAssertEqual(memory.release(0), 0)
        XCTAssertEqual(memory.release(7), ABI.invalidArgument)
    }
}
