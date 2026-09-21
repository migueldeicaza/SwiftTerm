//
//  ShowsProgressBarTests.swift
//  SwiftTermTests
//
//  A host that draws progress in its own chrome turns the built-in bar off,
//  and no report it keeps receiving may draw one behind its back.
//
#if os(macOS)
import AppKit
import Dispatch
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
struct ShowsProgressBarTests {

    /// Records what the host is told, which is what a custom bar would draw
    /// from.
    private class HostDelegate: TerminalViewDelegate {
        var reports: [Terminal.ProgressReport] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func progressReport(source: TerminalView, report: Terminal.ProgressReport) {
            reports.append(report)
        }
    }

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
    }

    private func progressBar(of view: TerminalView) -> TerminalProgressBarView? {
        view.subviews.compactMap { $0 as? TerminalProgressBarView }.first
    }

    /// The view parses on its I/O thread and hops to the main queue before it
    /// touches the bar, so a test waits for the effect rather than for a fixed
    /// slice. The deadline is only a backstop.
    private func settle(until satisfied: () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !satisfied(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Long enough for a bar that should not have appeared to have appeared.
    private func waitOut(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    @Test func theBarIsDrawnByDefault() async {
        let view = makeView()
        #expect(view.showsProgressBar)

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { self.progressBar(of: view)?.isHidden == false }

        #expect(progressBar(of: view)?.isHidden == false)
    }

    @Test func turningItOffKeepsEveryReportOffScreen() async {
        let view = makeView()
        view.showsProgressBar = false

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await waitOut(0.3)
        #expect(progressBar(of: view)?.isHidden != false)

        view.feed(text: "\u{1b}]9;4;3\u{07}")
        await waitOut(0.3)
        #expect(progressBar(of: view)?.isHidden != false)
    }

    /// The host still hears what it turned off, which is the whole point of
    /// turning it off. The delegate is what a custom bar draws from; the raw
    /// OSC observer never sees the removals the view makes on its own.
    @Test func theDelegateStillHearsTheReports() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate
        view.showsProgressBar = false

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }

        #expect(delegate.reports == [Terminal.ProgressReport(state: .set, progress: 40)])
        #expect(progressBar(of: view)?.isHidden != false)
    }

    /// The 15 second silence is the view's own decision, and a bar the host
    /// draws has to hear it too.
    @Test func expirationReachesTheHostWithTheBarOff() async {
        let view = makeView()
        let delegate = HostDelegate()
        view.terminalDelegate = delegate
        view.showsProgressBar = false

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !delegate.reports.isEmpty }
        view.expireProgressReport()

        #expect(delegate.reports.count == 2)
        #expect(delegate.reports.last?.state == .remove)
        #expect(progressBar(of: view)?.isHidden != false)
    }

    /// A host that drops its delegate while a program is still working leaves
    /// the view holding a report nobody is listening to. It still has to clean
    /// up after itself, and the delegate that comes next starts empty.
    @Test func droppingTheDelegateLeavesNothingBehind() async {
        let view = makeView()
        let first = HostDelegate()
        view.terminalDelegate = first
        view.showsProgressBar = false

        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { !first.reports.isEmpty }

        view.terminalDelegate = nil
        view.expireProgressReport()

        let second = HostDelegate()
        view.terminalDelegate = second
        view.updateUiClosed()
        await waitOut(0.3)

        #expect(first.reports.count == 1)
        #expect(second.reports.isEmpty)
        #expect(progressBar(of: view)?.isHidden != false)
    }

    /// Turning it off mid-task takes the bar that is already on screen down.
    @Test func turningItOffTakesALiveBarDown() async {
        let view = makeView()
        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { self.progressBar(of: view)?.isHidden == false }

        view.showsProgressBar = false

        #expect(progressBar(of: view)?.isHidden == true)
    }

    /// And turning it back on returns the report the program is still running,
    /// rather than waiting for the next one.
    @Test func turningItBackOnRestoresALiveReport() async {
        let view = makeView()
        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { self.progressBar(of: view)?.isHidden == false }

        view.showsProgressBar = false
        #expect(progressBar(of: view)?.isHidden == true)

        view.showsProgressBar = true
        #expect(progressBar(of: view)?.isHidden == false)
    }

    /// A program that ended its work while the bar was off leaves nothing to
    /// come back to.
    @Test func turningItBackOnAfterTheProgramFinishedShowsNothing() async {
        let view = makeView()
        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { self.progressBar(of: view)?.isHidden == false }

        view.showsProgressBar = false
        view.feed(text: "\u{1b}]9;4;0\u{07}")
        await waitOut(0.3)

        view.showsProgressBar = true

        #expect(progressBar(of: view)?.isHidden == true)
    }
}
#endif
