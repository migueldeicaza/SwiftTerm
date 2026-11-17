//
//  LocalProcessBellTests.swift
//
//  LocalProcessTerminalView is its own TerminalViewDelegate, so the bell must
//  reach the host through the processDelegate. Without the forward, a host
//  that embeds the local-process view never hears it.
//
//  The tests also examine TerminalViewDelegate.bell(source:style:), which is
//  the path that brings each bell to the forward.
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

/// The number of flashes that are in progress on the view.
@MainActor
private func flashCount(_ view: TerminalView) -> Int {
    view.layer?.sublayers?.filter { $0.animation(forKey: "visualBell") != nil }.count ?? 0
}

@MainActor
private final class BellHost: LocalProcessHostStubs {
    var styles: [BellStyle] = []
    /// The flashes in progress at the time of each call.
    var flashesAtCall: [Int] = []

    func bellRang(source: LocalProcessTerminalView, style: BellStyle) {
        styles.append(style)
        flashesAtCall.append(flashCount(source))
    }
}

/// A `terminalDelegate` that records each bell. If `forwardTo` is set, it is
/// a proxy that sends the bell on to the local-process view.
@MainActor
private final class BellSpy: TerminalViewDelegate {
    var styles: [BellStyle] = []
    weak var forwardTo: LocalProcessTerminalView?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardCopy(source: TerminalView, content: Data) {}

    func bell(source: TerminalView, style: BellStyle) {
        styles.append(style)
        forwardTo?.bell(source: source, style: style)
    }
}

/// A view that counts its default beeps and does not play them.
private class CountingView: LocalProcessTerminalView {
    var beeps = 0

    override func playDefaultBell() {
        beeps += 1
    }
}

/// A subclass that gets each bell through the `open` method.
private final class OverridingView: CountingView {
    var styles: [BellStyle] = []

    override func bell(source: TerminalView, style: BellStyle) {
        styles.append(style)
    }
}

/// The `terminalDelegate` of another view and the `processDelegate` of a local
/// one, with a silent `bell(source:)` for the other view. It must compile, and
/// that `bell(source:)` must not become the local view's answer.
@MainActor
private final class DualHost: TerminalViewDelegate, LocalProcessHostStubs {
    var terminalViewBells = 0

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {}
    func selectionFinished(source: TerminalView) {}
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

/// Source-compatibility guard. A subclass declared `bell(source:)` before this
/// change, in an extension and with no `override`. It must still compile.
private final class SubclassWithBell: LocalProcessTerminalView {}

extension SubclassWithBell {
    func bell(source: TerminalView) {}
}

@Suite struct LocalProcessBellTests {
    @MainActor
    private final class Fixture<View: CountingView> {
        let view: View
        var beeps: Int { view.beeps }

        init(_ make: (CGRect, TerminalOptions) -> View) {
            view = make(
                CGRect(x: 0, y: 0, width: 320, height: 160),
                TerminalOptions(cols: 80, rows: 25))
            view.eventQueue.drain()
        }

        /// Feeds the text and delivers the bells that it queued.
        func ring(_ text: String = "\u{7}") {
            view.feed(text: text)
            view.eventQueue.drain()
        }
    }

    @MainActor @Test func soundReachesTheHostOnce() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let host = BellHost()
        fixture.view.processDelegate = host
        fixture.view.bellStyle = .sound

        fixture.ring()
        #expect(host.styles == [.sound])
        #expect(fixture.beeps == 0)
    }

    @MainActor @Test func visualReachesTheHost() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let host = BellHost()
        fixture.view.processDelegate = host
        fixture.view.bellStyle = .visual

        fixture.ring()
        #expect(host.styles == [.visual])
        #expect(fixture.beeps == 0)
    }

    @MainActor @Test func soundAndVisualReachesTheHostOnce() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let host = BellHost()
        fixture.view.processDelegate = host
        fixture.view.bellStyle = .soundAndVisual

        fixture.ring()
        #expect(host.styles == [.soundAndVisual])
        #expect(fixture.beeps == 0)
    }

    @MainActor @Test func noneSendsNoCall() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let host = BellHost()
        fixture.view.processDelegate = host

        fixture.view.bellStyle = .none
        fixture.ring()
        #expect(host.styles.isEmpty)

        // Positive control: the same view and host get the next bell.
        fixture.view.bellStyle = .sound
        fixture.ring()
        #expect(host.styles == [.sound])
        #expect(fixture.beeps == 0)
    }

    @MainActor @Test func withNoProcessDelegateTheViewBeeps() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        fixture.view.bellStyle = .sound
        fixture.ring()
        #expect(fixture.beeps == 1)

        fixture.view.bellStyle = .visual
        fixture.ring()
        #expect(fixture.beeps == 1)
    }

    @MainActor @Test func aHostWithoutTheHookGetsTheDefaultBeep() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let host = MinimalLocalProcessHost()
        fixture.view.processDelegate = host

        // `processDelegate` is weak. Keep the host, or the view uses the path
        // for no delegate, which gives the same counts.
        withExtendedLifetime(host) {
            #expect(fixture.view.processDelegate != nil)

            fixture.view.bellStyle = .sound
            fixture.ring()
            #expect(fixture.beeps == 1)

            fixture.view.bellStyle = .visual
            fixture.ring()
            #expect(fixture.beeps == 1)

            fixture.view.bellStyle = .soundAndVisual
            fixture.ring()
            #expect(fixture.beeps == 2)
            #expect(fixture.view.processDelegate != nil)
        }
    }

    @MainActor @Test func anotherViewsBellIsNotTheLocalViewsAnswer() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let host = DualHost()
        fixture.view.processDelegate = host
        fixture.view.bellStyle = .sound

        fixture.ring()
        #expect(host.terminalViewBells == 0)
        #expect(fixture.beeps == 1)
    }

    @MainActor @Test func aReplacedTerminalDelegateKeepsTheOldPath() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let proxy = DualHost()
        let host = BellHost()
        fixture.view.processDelegate = host
        fixture.view.terminalDelegate = proxy
        fixture.view.bellStyle = .sound

        fixture.ring()
        #expect(proxy.terminalViewBells == 1)
        #expect(host.styles.isEmpty)
        #expect(fixture.beeps == 0)
    }

    @MainActor @Test func aProxyThatForwardsReachesTheHost() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let proxy = BellSpy()
        let host = BellHost()
        proxy.forwardTo = fixture.view
        fixture.view.processDelegate = host
        fixture.view.terminalDelegate = proxy

        fixture.view.bellStyle = .sound
        fixture.ring()
        fixture.view.bellStyle = .visual
        fixture.ring()
        #expect(proxy.styles == [.sound, .visual])
        #expect(host.styles == [.sound, .visual])
        #expect(fixture.beeps == 0)
    }

    @MainActor @Test func aSubclassCanOverrideTheBell() {
        let fixture = Fixture { OverridingView(frame: $0, options: $1) }
        let host = BellHost()
        fixture.view.processDelegate = host

        fixture.view.bellStyle = .sound
        fixture.ring()
        fixture.view.bellStyle = .visual
        fixture.ring()
        #expect(fixture.view.styles == [.sound, .visual])
        #expect(host.styles.isEmpty)
        #expect(fixture.beeps == 0)
    }

    @MainActor @Test func aPlainTerminalViewTellsItsDelegateAboutAVisualBell() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let spy = BellSpy()
        view.terminalDelegate = spy
        view.eventQueue.drain()

        view.bellStyle = .visual
        view.feed(text: "\u{7}")
        view.eventQueue.drain()
        #expect(spy.styles == [.visual])
        #expect(flashCount(view) == 1)
    }

    @MainActor @Test func theFlashComesAfterTheHostCall() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let host = BellHost()
        fixture.view.processDelegate = host

        fixture.view.bellStyle = .sound
        fixture.ring()
        #expect(flashCount(fixture.view) == 0)

        fixture.view.bellStyle = .visual
        fixture.ring()
        #expect(flashCount(fixture.view) == 1)

        fixture.view.bellStyle = .soundAndVisual
        fixture.ring()
        #expect(flashCount(fixture.view) == 2)

        // No flash was in progress when the host got its own bell.
        #expect(host.flashesAtCall == [0, 0, 1])
    }

    @MainActor @Test func noneGivesNoFlash() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        fixture.view.bellStyle = .none
        fixture.ring()
        #expect(flashCount(fixture.view) == 0)
        #expect(fixture.beeps == 0)

        // Positive control: the same view flashes for the next bell.
        fixture.view.bellStyle = .visual
        fixture.ring()
        #expect(flashCount(fixture.view) == 1)
    }

    @MainActor @Test func aBurstGivesOneCall() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let host = BellHost()
        fixture.view.processDelegate = host
        fixture.view.bellStyle = .sound

        fixture.ring("\u{7}\u{7}\u{7}")
        #expect(host.styles == [.sound])
    }

    /// The event queue cannot coalesce these bells, because each `ring()`
    /// delivers its bell. Only the 100 ms limit of `BellPolicy` drops them.
    @MainActor @Test func theRateLimitDropsASecondBell() {
        let fixture = Fixture { CountingView(frame: $0, options: $1) }
        let host = BellHost()
        fixture.view.processDelegate = host
        fixture.view.bellStyle = .sound
        fixture.view.bellPolicy.resetCounters()

        fixture.ring()
        fixture.ring()
        fixture.ring()
        #expect(host.styles == [.sound])
        #expect(fixture.view.bellPolicy.suppressed == 2)

        // Positive control: a new style resets the limit.
        fixture.view.bellStyle = .soundAndVisual
        fixture.ring()
        #expect(host.styles == [.sound, .soundAndVisual])
    }
}
#endif
