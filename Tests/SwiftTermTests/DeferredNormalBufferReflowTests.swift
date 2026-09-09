#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class DeferredNormalBufferReflowTests: XCTestCase {
    private let queue = DispatchQueue(label: "SwiftTerm.DeferredNormalBufferReflowTests")

    private func terminal(cols: Int = 80, rows: Int = 24) -> Terminal {
        HeadlessTerminal(
            queue: queue,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: 10_000)
        ) { _ in }.terminal
    }

    private func seedNormalBuffer(_ terminal: Terminal) {
        for index in 1...200 {
            terminal.feed(text: "normal-buffer-line-\(index)-with-reflow-content\r\n")
        }
    }

    func testAlternateScreenDefersNormalBufferResizeUntilReturn() {
        let terminal = terminal()
        seedNormalBuffer(terminal)
        let originalLineCount = terminal.normalBuffer.lines.count
        terminal.feed(text: "\u{1b}[?1049h")

        terminal.resize(cols: 100, rows: 30)
        terminal.resize(cols: 60, rows: 18)
        terminal.resize(cols: 120, rows: 40)

        XCTAssertEqual(terminal.altBuffer.cols, 120)
        XCTAssertEqual(terminal.altBuffer.rows, 40)
        XCTAssertEqual(terminal.normalBuffer.cols, 80)
        XCTAssertEqual(terminal.normalBuffer.rows, 24)
        XCTAssertEqual(terminal.normalBuffer.lines.count, originalLineCount)

        terminal.feed(text: "\u{1b}[?1049l")

        XCTAssertEqual(terminal.normalBuffer.cols, 120)
        XCTAssertEqual(terminal.normalBuffer.rows, 40)
        XCTAssertTrue(terminal.normalBuffer.lines.getArray().compactMap { $0 }.contains {
            $0.translateToString(trimRight: true).contains("normal-buffer-line-200")
        })
        XCTAssertTrue(terminal.normalBuffer.tabStops[80])
        XCTAssertTrue(terminal.normalBuffer.tabStops[112])
    }

    func testDeferredReflowMatchesAVisibleNormalBufferResize() {
        let direct = terminal()
        let deferred = terminal()
        seedNormalBuffer(direct)
        seedNormalBuffer(deferred)

        direct.resize(cols: 120, rows: 40)

        deferred.feed(text: "\u{1b}[?1049h")
        deferred.resize(cols: 120, rows: 40)
        deferred.feed(text: "\u{1b}[?1049l")

        XCTAssertEqual(
            direct.getBufferAsData(kind: .normal),
            deferred.getBufferAsData(kind: .normal))
        XCTAssertEqual(direct.normalBuffer.yBase, deferred.normalBuffer.yBase)
        XCTAssertEqual(direct.normalBuffer.x, deferred.normalBuffer.x)
        XCTAssertEqual(direct.normalBuffer.y, deferred.normalBuffer.y)
        XCTAssertEqual(direct.normalBuffer.savedX, deferred.normalBuffer.savedX)
        XCTAssertEqual(deferred.normalBuffer.savedY, deferred.normalBuffer.y)
    }
}
#endif
