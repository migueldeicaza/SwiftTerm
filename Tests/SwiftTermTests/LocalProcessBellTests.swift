//
//  LocalProcessBellTests.swift
//
//  LocalProcessTerminalView is its own TerminalViewDelegate, so the bell must
//  reach the host through the processDelegate. Without the forward, a host
//  that embeds the local-process view never hears it.
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
private final class BellHost: LocalProcessTerminalViewDelegate {
    var bells = 0

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}

    func bellRang(source: LocalProcessTerminalView) {
        bells += 1
    }
}

/// A host that only implements the four process hooks gets the defaults.
@MainActor
private final class MinimalHost: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

/// The `terminalDelegate` of another view and the `processDelegate` of a local
/// one, with a silent `bell(source:)` for the other view. It must compile, and
/// that `bell(source:)` must not become the local view's answer.
@MainActor
private final class DualHost: TerminalViewDelegate, LocalProcessTerminalViewDelegate {
    var terminalViewBells = 0

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {}
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(
        source: TerminalView, location: KittyClipboardLocation
    ) -> [String]? { nil }
    func kittyClipboardRead(
        source: TerminalView, location: KittyClipboardLocation, mimeType: String
    ) -> KittyClipboardReadResult? { nil }
    func kittyClipboardWrite(
        source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent
    ) -> KittyClipboardWriteResult { .unsupported }
    func kittyClipboardRequestPermission(
        source: TerminalView, request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult { .deny }

    func bell(source: TerminalView) {
        terminalViewBells += 1
    }
}

@Suite(.serialized) struct LocalProcessBellTests {
    @MainActor
    private func makeView() -> LocalProcessTerminalView {
        LocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 160),
            options: TerminalOptions(cols: 80, rows: 25))
    }

    /// Feeds one BEL and waits for the view's main-queue delivery.
    @MainActor
    private func ring(_ view: LocalProcessTerminalView) async {
        view.feed(text: "\u{7}")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Counts the default beeps while `body` runs.
    @MainActor
    private func countingBeeps(_ body: () async -> Void) async -> Int {
        var beeps = 0
        let original = defaultBellSound
        defaultBellSound = { beeps += 1 }
        defer { defaultBellSound = original }
        await body()
        return beeps
    }

    @MainActor @Test func soundReachesTheHostOnce() async {
        let view = makeView()
        let host = BellHost()
        view.processDelegate = host
        view.bellStyle = .sound

        let beeps = await countingBeeps { await ring(view) }
        #expect(host.bells == 1)
        #expect(beeps == 0)
    }

    @MainActor @Test func withNoProcessDelegateTheViewBeeps() async {
        let view = makeView()
        view.bellStyle = .sound

        let beeps = await countingBeeps { await ring(view) }
        #expect(beeps == 1)
    }

    @MainActor @Test func aHostWithoutTheHookGetsTheDefaultBeep() async {
        let view = makeView()
        let host = MinimalHost()
        view.processDelegate = host
        view.bellStyle = .sound

        let beeps = await countingBeeps { await ring(view) }
        #expect(beeps == 1)
    }

    @MainActor @Test func visualAndNoneSendNoCall() async {
        let view = makeView()
        let host = BellHost()
        view.processDelegate = host

        let beeps = await countingBeeps {
            view.bellStyle = .none
            await ring(view)
            view.bellStyle = .visual
            await ring(view)
        }
        #expect(host.bells == 0)
        #expect(beeps == 0)
    }

    @MainActor @Test func anotherViewsBellIsNotTheLocalViewsAnswer() async {
        let view = makeView()
        let host = DualHost()
        view.processDelegate = host
        view.bellStyle = .sound

        let beeps = await countingBeeps { await ring(view) }
        #expect(host.terminalViewBells == 0)
        #expect(beeps == 1)
    }
}
#endif
