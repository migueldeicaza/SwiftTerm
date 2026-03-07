#if os(macOS)
import XCTest

@testable import SwiftTerm

final class MacTerminalSelectionTests: XCTestCase {
    func testShouldClearSelectionOnLinefeedWhenMouseReportingAppIsActive() {
        XCTAssertTrue(
            TerminalView.shouldClearSelectionOnLinefeed(
                allowMouseReporting: true,
                mouseMode: .vt200,
                prioritizeSelectionInteraction: false
            )
        )
    }

    func testShouldNotClearSelectionOnLinefeedWhenMouseModeIsOff() {
        XCTAssertFalse(
            TerminalView.shouldClearSelectionOnLinefeed(
                allowMouseReporting: true,
                mouseMode: .off,
                prioritizeSelectionInteraction: false
            )
        )
    }

    func testShouldNotClearSelectionWhenPrioritizingSelectionInteraction() {
        XCTAssertFalse(
            TerminalView.shouldClearSelectionOnLinefeed(
                allowMouseReporting: true,
                mouseMode: .vt200,
                prioritizeSelectionInteraction: true
            )
        )
    }

    func testShouldPrioritizeSelectionInteractionHelper() {
        XCTAssertTrue(
            TerminalView.shouldPrioritizeSelectionInteraction(
                allowMouseReporting: true,
                mouseMode: .vt200,
                prioritizeSelectionInteraction: true
            )
        )
        XCTAssertFalse(
            TerminalView.shouldPrioritizeSelectionInteraction(
                allowMouseReporting: true,
                mouseMode: .off,
                prioritizeSelectionInteraction: true
            )
        )
        XCTAssertFalse(
            TerminalView.shouldPrioritizeSelectionInteraction(
                allowMouseReporting: false,
                mouseMode: .vt200,
                prioritizeSelectionInteraction: true
            )
        )
    }

    func testLinefeedPreservesSelectionForRegularCliOutput() {
        let view = TerminalView(frame: .zero)
        view.selection.startSelection(row: 0, col: 0)

        XCTAssertTrue(view.selection.active)
        XCTAssertEqual(view.terminal.mouseMode, .off)

        view.linefeed(source: view.terminal)

        XCTAssertTrue(view.selection.active)
    }

    func testLinefeedPreservesSelectionWhenPrioritizingSelectionInteraction() {
        let view = TerminalView(frame: .zero)
        view.prioritizeSelectionInteraction = true
        view.selection.startSelection(row: 0, col: 0)
        view.terminal.feed(text: "\u{1B}[?1000h")

        XCTAssertTrue(view.selection.active)
        XCTAssertNotEqual(view.terminal.mouseMode, .off)

        view.linefeed(source: view.terminal)

        XCTAssertTrue(view.selection.active)
    }
}
#endif
