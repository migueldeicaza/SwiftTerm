import Testing
@testable import SwiftTerm

struct TerminalTapPolicyTests {
    /// Double tap selects a word even when the application is capturing the mouse: the regression
    /// that prevented any selection inside a TUI (vim, htop, a full-screen app).
    @Test func doubleTapSelectsWordRegardlessOfMouseReporting() {
        #expect(TerminalTapPolicy.action(tapCount: 2, hasActiveSelection: false, mouseReportingActive: true) == .selectWord)
        #expect(TerminalTapPolicy.action(tapCount: 2, hasActiveSelection: false, mouseReportingActive: false) == .selectWord)
    }

    /// Triple tap selects a line even under mouse reporting (same rationale as double tap).
    @Test func tripleTapSelectsLineRegardlessOfMouseReporting() {
        #expect(TerminalTapPolicy.action(tapCount: 3, hasActiveSelection: false, mouseReportingActive: true) == .selectLine)
        #expect(TerminalTapPolicy.action(tapCount: 3, hasActiveSelection: false, mouseReportingActive: false) == .selectLine)
    }

    /// With mouse reporting active, a tap can still clear local selection.
    @Test func singleTapDismissesSelectionUnderMouseReporting() {
        #expect(TerminalTapPolicy.action(tapCount: 1, hasActiveSelection: true, mouseReportingActive: true) == .dismissSelection)
    }

    @Test func singleTapAfterSelectionCanRouteLocally() {
        #expect(TerminalTapPolicy.action(tapCount: 1, hasActiveSelection: true, mouseReportingActive: false) == .localSingleTap)
    }

    @Test func tapThatClearsSelectionDoesNotOpenContextMenu() {
        #expect(!TerminalTapPolicy.showsContextMenu(nearCursor: true, clearedSelection: true))
        #expect(TerminalTapPolicy.showsContextMenu(nearCursor: true, clearedSelection: false))
        #expect(!TerminalTapPolicy.showsContextMenu(nearCursor: false, clearedSelection: false))
    }

    /// With nothing selected and reporting on, a single tap forwards the click so the application
    /// stays usable.
    @Test func singleTapForwardsClickWhenReportingAndNoSelection() {
        #expect(TerminalTapPolicy.action(tapCount: 1, hasActiveSelection: false, mouseReportingActive: true) == .forwardClick)
    }

    /// With nothing selected and no reporting, a single tap is handled locally.
    @Test func singleTapIsLocalWhenNoReportingAndNoSelection() {
        #expect(TerminalTapPolicy.action(tapCount: 1, hasActiveSelection: false, mouseReportingActive: false) == .localSingleTap)
    }
}
