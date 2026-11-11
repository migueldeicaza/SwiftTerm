//
//  SessionSignalTests.swift
//  SwiftTermTests
//
//  A host that embeds a session wants to know when it is busy, and what the
//  application asked for, without reading the bar off the screen.
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
struct SessionSignalTests {

    /// Implements the two new callbacks on top of the ones the protocol does
    /// not default.
    private class HostDelegate: TerminalViewDelegate {
        var reports: [Terminal.ProgressReport] = []
        var notifications: [(title: String, body: String)] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func progressReport(source: TerminalView, report: Terminal.ProgressReport) {
            reports.append(report)
        }

        func notification(source: TerminalView, title: String, body: String) {
            notifications.append((title, body))
        }
    }

    /// A delegate written before this change: if either callback stops being
    /// defaulted, this type stops compiling.
    private class SilentDelegate: TerminalViewDelegate {
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// A host that closes the session as soon as it hears the removal, as one
    /// that closes idle tabs would, noting how far the teardown had got.
    private class ClosingHost: HostDelegate {
        var stateAtRemoval: TerminalView.UIShutdownState?

        override func progressReport(source: TerminalView, report: Terminal.ProgressReport) {
            super.progressReport(source: source, report: report)
            guard report.state == .remove else { return }
            stateAtRemoval = source.uiShutdownState
            source.updateUiClosed()
        }
    }

    private class ProcessHost: LocalProcessTerminalViewDelegate {
        var reports: [Terminal.ProgressReport] = []
        var notifications: [(title: String, body: String)] = []

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}

        func progressReport(source: TerminalView, report: Terminal.ProgressReport) {
            reports.append(report)
        }

        func notification(source: TerminalView, title: String, body: String) {
            notifications.append((title, body))
        }
    }

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
    }

    private func progressBar(of view: TerminalView) -> TerminalProgressBarView? {
        view.subviews.compactMap { $0 as? TerminalProgressBarView }.first
    }

    /// The view parses on its I/O thread and hops to the main queue before it
    /// touches the bar or the host, so a test waits for the effect rather than
    /// for a fixed slice.
    private func settle(seconds: TimeInterval = 2, until satisfied: () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !satisfied(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Long enough for a callback that should not happen to have happened.
    private func settleBriefly() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    @Test func progressReportsReachTheHost() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }

        #expect(delegate.reports.count == 1)
        #expect(delegate.reports.first == Terminal.ProgressReport(state: .set, progress: 40))

        view.feed(text: "\u{1b}]9;4;0\u{07}")
        await settle { delegate.reports.count > 1 }

        #expect(delegate.reports.count == 2)
        #expect(delegate.reports.last?.state == .remove)
    }

    /// An indeterminate report carries no percentage; the host still has to
    /// hear that the session is working.
    @Test func indeterminateReportsReachTheHost() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;3\u{07}")
        await settle { !delegate.reports.isEmpty }

        #expect(delegate.reports.first?.state == .indeterminate)
        #expect(delegate.reports.first?.progress == nil)
    }

    /// The 15 second silence is the view's own decision. A host that mirrors
    /// the bar has to be told, or it stays busy forever.
    @Test func theSilenceTimerRemovalReachesTheHost() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate
        view.schedulesProgressReportTimer = false

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        view.progressReportTimer?.fire()

        #expect(delegate.reports.count == 2)
        #expect(delegate.reports.last?.state == .remove)
        #expect(progressBar(of: view)?.isHidden == true)
        #expect(view.currentProgressReport == nil)
    }

    /// A removal the host never heard start reads as the end of work it never
    /// started: some shell integrations send one at every prompt, and the
    /// application can send its own after the silence timer already did.
    @Test func aRemovalWithNoLiveReportIsNotForwarded() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate
        view.schedulesProgressReportTimer = false

        view.feed(text: "\u{1b}]9;4;0\u{07}")
        await settleBriefly()
        #expect(delegate.reports.isEmpty)

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        view.progressReportTimer?.fire()
        view.feed(text: "\u{1b}]9;4;0\u{07}")
        await settleBriefly()

        #expect(delegate.reports.map(\.state) == [.set, .remove])
    }

    /// The live report is readable, for a delegate attached while it is up.
    @Test func theCurrentReportIsReadable() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;2;70\u{07}")
        await settle { !delegate.reports.isEmpty }
        #expect(view.currentProgressReport == Terminal.ProgressReport(state: .error, progress: 70))

        view.feed(text: "\u{1b}]9;4;0\u{07}")
        await settle { delegate.reports.count > 1 }
        #expect(view.currentProgressReport == nil)
    }

    /// Turning the silence clear back on while a report is live starts its
    /// wait; with no report live there is nothing to wait for.
    @Test func theTimeoutRearmsOnlyForALiveReport() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate
        view.schedulesProgressReportTimer = false

        view.progressReportTimeout = 5
        #expect(view.progressReportTimer == nil)

        view.progressReportTimeout = nil
        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        #expect(view.progressReportTimer == nil)
        view.progressReportTimeout = 5
        #expect(view.progressReportTimer != nil)
    }

    /// Closing the view ends the session; a host that heard the `set` has to
    /// hear the removal, or it stays busy with nothing left to be busy about.
    @Test func closingTheViewRemovesALiveReport() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        view.updateUiClosed()

        #expect(delegate.reports.count == 2)
        #expect(delegate.reports.last?.state == .remove)
        #expect(progressBar(of: view)?.isHidden == true)
    }

    /// The removal is owed for the report, not for the timer: a host can have
    /// the silence clear off, so a live report may have no timer behind it.
    @Test func closingTheViewRemovesALiveReportWithNoTimerRunning() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate
        view.progressReportTimeout = nil

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        #expect(view.progressReportTimer == nil)
        view.updateUiClosed()

        #expect(delegate.reports.count == 2)
        #expect(delegate.reports.last?.state == .remove)
    }

    /// With no bar up there is nothing to remove, and a removal the host never
    /// asked for would read as the end of work it never started.
    @Test func closingTheViewWithoutAReportSaysNothing() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.updateUiClosed()
        await settleBriefly()

        #expect(delegate.reports.isEmpty)
    }

    /// A report the process writes after the view closed, or one the parser
    /// queued before it, would land after the close's removal and leave the
    /// host busy for a session that is gone; a notification is dropped too.
    @Test func nothingReachesTheHostAfterTheViewCloses() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        view.updateUiClosed()
        view.feed(text: "\u{1b}]9;4;1;60\u{07}")
        view.feed(text: "\u{1b}]777;notify;Build;Done\u{07}")
        await settleBriefly()

        #expect(delegate.reports.map(\.state) == [.set, .remove])
        #expect(delegate.notifications.isEmpty)
        #expect(view.progressReportTimer == nil)
        #expect(view.currentProgressReport == nil)
    }

    /// The close's removal comes once the view has stopped, so a host that
    /// closes the session on it does not run the teardown a second time.
    @Test func theCloseRemovalArrivesAfterTheViewStopped() async {
        let view = makeView()
        let delegate = ClosingHost()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        view.updateUiClosed()

        #expect(delegate.stateAtRemoval == .stopped)
        #expect(delegate.reports.map(\.state) == [.set, .remove])
    }

    /// Teardown is idempotent, and so is the removal it reports.
    @Test func closingTheViewTwiceRemovesOnlyOnce() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        view.updateUiClosed()
        view.updateUiClosed()
        await settleBriefly()

        #expect(delegate.reports.count == 2)
    }

    /// Reporting to the host is an addition: the bar the view already drew has
    /// to behave exactly as it did.
    @Test func theBarStillDrawsWhileTheHostListens() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        #expect(progressBar(of: view)?.isHidden == false)

        view.feed(text: "\u{1b}]9;4;0\u{07}")
        await settle { delegate.reports.count > 1 }
        #expect(progressBar(of: view)?.isHidden == true)
    }

    /// A malformed report is not a state change, so it does not reach the host
    /// either.
    @Test func anUnparsableReportIsNotForwarded() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;9;40\u{07}")
        await settleBriefly()

        #expect(delegate.reports.isEmpty)
    }

    @Test func osc777NotificationsReachTheHost() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]777;notify;Build;Finished in 3s\u{07}")
        await settle { !delegate.notifications.isEmpty }

        #expect(delegate.notifications.count == 1)
        #expect(delegate.notifications.first?.title == "Build")
        #expect(delegate.notifications.first?.body == "Finished in 3s")
    }

    /// A body that contains a semicolon is still one body.
    @Test func aNotificationBodyKeepsItsSemicolons() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]777;notify;Tests;3 passed; 1 failed\u{07}")
        await settle { !delegate.notifications.isEmpty }

        #expect(delegate.notifications.first?.body == "3 passed; 1 failed")
    }

    /// `LocalProcessTerminalView` is its own `TerminalViewDelegate`, so a host
    /// that uses it can only hear these through its process delegate.
    @Test func aLocalProcessViewForwardsToItsProcessDelegate() async {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let delegate = ProcessHost()
        view.processDelegate = delegate

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        #expect(delegate.reports.first?.state == .set)

        view.feed(text: "\u{1b}]777;notify;Build;Done\u{07}")
        await settle { !delegate.notifications.isEmpty }
        #expect(delegate.notifications.first?.title == "Build")
    }

    /// A process that exits mid-report never sends its removal, so its exit
    /// ends the report.
    @Test func aProcessExitingMidReportEndsIt() async {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let delegate = ProcessHost()
        view.processDelegate = delegate
        view.progressReportTimeout = nil

        view.startProcess(executable: "/bin/sh", args: ["-c", "printf '\\033]9;4;1;40\\007'; sleep 0.2"])
        await settle(seconds: 10) { delegate.reports.count > 1 }

        #expect(delegate.reports.map(\.state) == [.set, .remove])
        #expect(view.currentProgressReport == nil)
    }

    /// A delegate written against the previous release conforms unchanged, and
    /// the defaulted callbacks swallow the events.
    @Test func aDelegateWithoutTheNewCallbacksStillConforms() async {
        let view = makeView()
        let delegate = SilentDelegate()
        view.terminalDelegate = delegate

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        view.feed(text: "\u{1b}]777;notify;Build;Done\u{07}")
        await settle { self.progressBar(of: view)?.isHidden == false }

        #expect(progressBar(of: view)?.isHidden == false)
    }
}
#endif
