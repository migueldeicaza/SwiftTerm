import XCTest
@testable import SwiftTermWebWasm

final class SelectionFacadeTests: XCTestCase {
    private func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }

    func testStateAndTextSnapshotsRemainStableUntilSize() {
        let handle = terminalCreate(10, 2, 3)
        defer { _ = terminalDestroy(handle) }
        let entry = WasmRuntime.shared.handles.get(handle)!
        entry.feedPreservingSelection(Array("0123456789".utf8)[...])
        XCTAssertEqual(terminalSelection(handle, 0, 9, 0, 0), 0)
        XCTAssertEqual(terminalSelectionStateSize(handle), 44)
        let snapshot = entry.selectionSnapshot
        XCTAssertEqual(word(snapshot, 0), 1)
        XCTAssertEqual(word(snapshot, 20), 1)
        XCTAssertEqual(word(snapshot, 24), 1)
        XCTAssertEqual(word(snapshot, 28), 0)
        XCTAssertEqual(word(snapshot, 32), 0)
        XCTAssertEqual(word(snapshot, 36), 9)
        XCTAssertEqual(word(snapshot, 40), 10)
        XCTAssertEqual(terminalSelectionTextSize(handle), 1)
        XCTAssertEqual(entry.selectionTextSnapshot, Array("9".utf8))
        XCTAssertEqual(terminalSelection(handle, 2, 0, 0, 0), 0)
        XCTAssertEqual(entry.selectionSnapshot, snapshot)
        XCTAssertEqual(entry.selectionTextSnapshot, Array("9".utf8))
        XCTAssertEqual(terminalSelectionStateCopy(handle, 0, 0), ABI.bufferTooSmall)
        XCTAssertEqual(terminalSelectionTextCopy(handle, 0, 0), ABI.bufferTooSmall)
        XCTAssertEqual(terminalSelectionStateSize(handle), 32)
        XCTAssertGreaterThan(word(entry.selectionSnapshot, 4), word(snapshot, 4))
        XCTAssertEqual(word(entry.selectionSnapshot, 20), 0)
        XCTAssertEqual(terminalSelectionTextSize(handle), 0)
        XCTAssertEqual(terminalSelectionTextCopy(handle, 0, 0), 0)
    }

    func testResizeResetAndInvalidOperations() {
        let handle = terminalCreate(8, 2, 3)
        defer { _ = terminalDestroy(handle) }
        let entry = WasmRuntime.shared.handles.get(handle)!
        entry.feedPreservingSelection(Array("first\r\nsecond\r\nthird".utf8)[...])
        XCTAssertEqual(terminalScroll(handle, Int32.min, 0), 0)
        XCTAssertEqual(terminalSelection(handle, 0, 1, 0, 1), 0)
        XCTAssertEqual(terminalSelectionTextSize(handle), 5)
        XCTAssertEqual(terminalResize(handle, 9, 2, 0, 0), 0)
        XCTAssertEqual(terminalSelectionTextSize(handle), 0)
        XCTAssertEqual(terminalSelection(handle, 3, 0, 0, 0), 0)
        XCTAssertEqual(terminalReset(handle), 0)
        XCTAssertEqual(terminalSelectionTextSize(handle), 0)
        XCTAssertEqual(terminalScroll(handle, 0, 2), ABI.invalidArgument)
        XCTAssertEqual(terminalSelection(handle, 4, 0, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalSelection(handle, 0, 0, 0, 4), ABI.invalidArgument)
        XCTAssertEqual(terminalSelection(handle, 0, UInt32.max, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalSelection(handle, 0, 0, 2, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalSelectionStateCopy(handle, UInt32.max, 1), ABI.outOfBounds)
        XCTAssertEqual(terminalSelectionTextCopy(handle, UInt32.max, 1), ABI.outOfBounds)
        XCTAssertEqual(terminalScroll(0, 0, 0), ABI.invalidHandle)
        XCTAssertEqual(terminalSelection(0, 0, 0, 0, 0), ABI.invalidHandle)
        XCTAssertEqual(terminalSelectionStateSize(0), ABI.invalidHandle)
        XCTAssertEqual(terminalSelectionTextSize(0), ABI.invalidHandle)
    }
}
