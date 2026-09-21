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
    private func settle(until satisfied: () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: 2)
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

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        view.expireProgressReport()

        #expect(delegate.reports.count == 2)
        #expect(delegate.reports.last?.state == .remove)
        #expect(progressBar(of: view)?.isHidden == true)
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
