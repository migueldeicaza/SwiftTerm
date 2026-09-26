//
//  ProgressReportTimeoutTests.swift
//  SwiftTermTests
//
//  The silence that clears an abandoned OSC 9;4 bar is a safety net, and a
//  host whose program reports only at the start and the end of its work has to
//  be able to lengthen it or turn it off.
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
struct ProgressReportTimeoutTests {

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
    }

    private func progressBar(of view: TerminalView) -> TerminalProgressBarView? {
        view.subviews.compactMap { $0 as? TerminalProgressBarView }.first
    }

    /// The view parses on its I/O thread and hops to the main queue before it
    /// touches the bar, so a test waits for the effect rather than for a fixed
    /// slice. The deadline is only a backstop: a suite running in parallel can
    /// hold the main actor for seconds at a time, and a short one turns that
    /// into a false failure.
    private func settle(until satisfied: () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !satisfied(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Long enough for a clear that should not happen to have happened.
    private func waitOut(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Starts a bar and returns once it is on screen, so the silence that each
    /// test measures starts from a known point.
    private func startABar(on view: TerminalView) async {
        view.feed(text: "\u{1b}]9;4;1;40\u{07}")
        await settle { self.progressBar(of: view)?.isHidden == false }
        #expect(progressBar(of: view)?.isHidden == false)
    }

    @Test func theDefaultIsTheFifteenSecondSilence() {
        #expect(TerminalView.defaultProgressReportTimeout == 15)
        #expect(makeView().progressReportTimeout == 15)
    }

    /// The default is long enough that a gap between reports does not take the
    /// bar down; only a program that stopped reporting entirely loses it.
    @Test func theDefaultOutlastsAShortSilence() async {
        let view = makeView()
        await startABar(on: view)

        await waitOut(0.4)

        #expect(progressBar(of: view)?.isHidden == false)
    }

    @Test func aTimeoutClearsTheBarAfterItsOwnSilence() async {
        let view = makeView()
        view.progressReportTimeout = 0.1
        await startABar(on: view)

        await settle { self.progressBar(of: view)?.isHidden == true }

        #expect(progressBar(of: view)?.isHidden == true)
    }

    /// Turned off, the bar belongs to the program alone: nothing the view does
    /// takes it down, however long the program stays quiet.
    @Test func aNilTimeoutNeverClearsTheBar() async {
        let view = makeView()
        view.progressReportTimeout = nil
        await startABar(on: view)

        await waitOut(0.4)
        #expect(progressBar(of: view)?.isHidden == false)

        // The same silence with a wait in place does clear it, so the bar above
        // survived because the wait was off, not because it was slow.
        view.progressReportTimeout = 0.05
        await settle { self.progressBar(of: view)?.isHidden == true }
        #expect(progressBar(of: view)?.isHidden == true)
    }

    /// A host that turns the wait off mid-task means the bar that is already on
    /// screen too, not only the next one.
    @Test func clearingTheTimeoutCancelsAWaitInFlight() async {
        let view = makeView()
        view.progressReportTimeout = 0.2
        await startABar(on: view)

        view.progressReportTimeout = nil
        await waitOut(0.5)

        #expect(progressBar(of: view)?.isHidden == false)
    }

    /// Setting a shorter wait applies to the bar on screen rather than waiting
    /// for the next report to adopt it.
    @Test func shorteningTheTimeoutRearmsAWaitInFlight() async {
        let view = makeView()
        await startABar(on: view)

        view.progressReportTimeout = 0.05
        await settle { self.progressBar(of: view)?.isHidden == true }

        #expect(progressBar(of: view)?.isHidden == true)
    }

    /// Changing the dial with no bar on screen arms nothing; the next report
    /// starts the wait, the way it always did.
    @Test func aTimeoutSetWhileIdleStartsWithTheNextReport() async {
        let view = makeView()
        view.progressReportTimeout = 0.1
        await waitOut(0.3)
        #expect(progressBar(of: view)?.isHidden != false)

        await startABar(on: view)
        await settle { self.progressBar(of: view)?.isHidden == true }

        #expect(progressBar(of: view)?.isHidden == true)
    }

    /// Every report restarts the wait, so a program that keeps reporting keeps
    /// its bar however long the work runs.
    @Test func eachReportRestartsTheWait() async {
        let view = makeView()
        view.progressReportTimeout = 0.5
        await startABar(on: view)

        await waitOut(0.3)
        view.feed(text: "\u{1b}]9;4;1;60\u{07}")
        await waitOut(0.3)

        // 0.6s after the first report, 0.3s after the second.
        #expect(progressBar(of: view)?.isHidden == false)

        await settle { self.progressBar(of: view)?.isHidden == true }
        #expect(progressBar(of: view)?.isHidden == true)
    }

    /// The program's own removal still takes the bar down, whatever the dial
    /// says.
    @Test func theProgramCanStillRemoveItsBar() async {
        let view = makeView()
        view.progressReportTimeout = nil
        await startABar(on: view)

        view.feed(text: "\u{1b}]9;4;0\u{07}")
        await settle { self.progressBar(of: view)?.isHidden == true }

        #expect(progressBar(of: view)?.isHidden == true)
    }
}
#endif
