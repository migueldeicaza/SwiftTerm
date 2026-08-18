import XCTest

@testable import SwiftTerm

#if os(macOS)
import AppKit
#endif

final class LocalProcessSchedulingTests: XCTestCase {
  func testPendingBytesAreDeliveredInBoundedOrderedSlices() {
    var queue = PendingByteQueue()
    let first = (0..<(128 * 1024)).map { UInt8(truncatingIfNeeded: $0) }
    let second = Array(repeating: UInt8(0xA5), count: 7_000)
    queue.append(first)
    queue.append(second)

    var delivered: [UInt8] = []
    var largestSlice = 0
    while let slice = queue.popFirst(maxBytes: 16 * 1024, flushThreshold: 32) {
      largestSlice = max(largestSlice, slice.count)
      delivered.append(contentsOf: slice)
    }

    XCTAssertLessThanOrEqual(largestSlice, 16 * 1024)
    XCTAssertEqual(delivered, first + second)
    XCTAssertEqual(queue.byteCount, 0)
    XCTAssertTrue(queue.isEmpty)
  }

  func testPendingBytesFlushConsumedChunkStorageWithoutLosingOrder() {
    var queue = PendingByteQueue()
    for byte in UInt8(0)..<UInt8(40) {
      queue.append([byte])
    }

    var delivered: [UInt8] = []
    while let slice = queue.popFirst(maxBytes: 1, flushThreshold: 8) {
      delivered.append(contentsOf: slice)
    }

    XCTAssertEqual(delivered, Array(UInt8(0)..<UInt8(40)))
    XCTAssertEqual(queue.byteCount, 0)
    }

#if os(macOS)
    @MainActor
    func testInteractiveMainThreadFeedDefersAndCoalescesDisplay() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        view.recordUserInput()

        view.feed(text: "first")
        XCTAssertTrue(view.pendingDisplay)

        view.feed(text: "second")
        XCTAssertTrue(view.pendingDisplay)
    }

    @MainActor
    func testSuspendedPresentationKeepsParsingWithoutSchedulingDisplay() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        view.setPresentationActive(false)

        view.feed(text: "state continues")

        XCTAssertTrue(view.terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: "state continues".count, row: 0)
        ).contains("state continues"))
        XCTAssertFalse(view.pendingDisplay)
        XCTAssertNotNil(view.terminal.getUpdateRange())
    }

    @MainActor
    func testResumingPresentationSchedulesOneFullDisplay() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        view.setPresentationActive(false)
        view.feed(text: "latest state")

        view.setPresentationActive(true)
        let pendingAfterFirstResume = view.pendingDisplay
        view.setPresentationActive(true)

        XCTAssertTrue(pendingAfterFirstResume)
        XCTAssertTrue(view.pendingDisplay)
        XCTAssertEqual(view.terminal.getUpdateRange()?.startY, 0)
        XCTAssertGreaterThanOrEqual(view.terminal.getUpdateRange()?.endY ?? -1,
                                    view.terminal.rows - 1)
    }

    @MainActor
    func testResumePreservesSynchronizedOutputDisplayGate() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        view.setPresentationActive(false)
        view.feed(text: "\u{1b}[?2026hhidden state")

        view.setPresentationActive(true)

        XCTAssertTrue(view.terminal.synchronizedOutputActive)
        XCTAssertFalse(view.pendingDisplay)
        XCTAssertNotNil(view.terminal.getUpdateRange())

        view.feed(text: "\u{1b}[?2026l")

        XCTAssertFalse(view.terminal.synchronizedOutputActive)
        XCTAssertTrue(view.pendingDisplay)
    }

    @MainActor
    func testStaleDisplayCallbackCannotConsumeResumedDamage() async {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        view.recordUserInput()
        view.feed(text: "before suspend")
        XCTAssertTrue(view.pendingDisplay)

        view.setPresentationActive(false)
        view.feed(text: " while hidden")
        view.setPresentationActive(true)
        let resumedGeneration = view.displayScheduleGeneration

        await Task.yield()

        XCTAssertEqual(view.displayScheduleGeneration, resumedGeneration)
        XCTAssertTrue(view.pendingDisplay)
        XCTAssertNotNil(view.terminal.getUpdateRange())
    }
#endif
}
