#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite("Terminal link dispatch")
struct TerminalLinkOpeningTests {
    private final class Delegate: TerminalViewDelegate {
        var links: [String] = []
        var parameters: [[String: String]] = []
        var approvedLinks: [URL?] = []
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            links.append(link)
            parameters.append(params)
            approvedLinks.append(source.approvedLinkForDelegate)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test func allowedLinkReachesTheDelegateOnceWithItsParameters() {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.activateLink("https://example.com", params: ["id": "test"], isExplicit: true)
        #expect(delegate.links == ["https://example.com"])
        #expect(delegate.parameters == [["id": "test"]])
        #expect(delegate.approvedLinks == [URL(string: "https://example.com")])
        #expect(view.approvedLinkForDelegate == nil)
    }

    @Test(arguments: [true, false])
    func deniedLinkNeverReachesTheDelegate(isExplicit: Bool) async {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        var alerts = 0
        view.activateLink("file:///System/Applications/Calculator.app", params: [:],
                          isExplicit: isExplicit) { alert, _, completion in
            alerts += 1
            #expect(alert.buttons.map(\.title) == ["OK"])
            completion(.alertFirstButtonReturn)
        }
        await waitUntil { alerts == 1 }
        #expect(delegate.links.isEmpty)
        #expect(view.approvedLinkForDelegate == nil)
    }

    @Test(arguments: [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn])
    func customSchemesNeedExplicitConfirmation(_ response: NSApplication.ModalResponse) async {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        var alerts = 0
        view.activateLink("ssh://example.com", params: [:], isExplicit: true) { _, _, completion in
            alerts += 1
            #expect(delegate.links.isEmpty)
            completion(response)
        }
        #expect(delegate.links.isEmpty)
        await waitUntil { alerts == 1 }
        #expect(delegate.links == (response == .alertSecondButtonReturn ? ["ssh://example.com"] : []))
    }

    @Test func disablingOsc8WhileConfirmationIsOpenPreventsDispatch() async {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        var alerts = 0
        view.activateLink("ssh://example.com", params: [:], isExplicit: true) { _, _, completion in
            alerts += 1
            view.enableOsc8Hyperlinks = false
            completion(.alertSecondButtonReturn)
        }
        await waitUntil { alerts == 1 }
        #expect(delegate.links.isEmpty)
    }

    /// Takes every link offered before the check, recording what it was given.
    private final class TakingDelegate: TerminalViewDelegate {
        var unchecked: [(link: String, params: [String: String], isExplicit: Bool)] = []
        var links: [String] = []
        func openUncheckedLink(source: TerminalView, link: String, params: [String: String], isExplicit: Bool) -> Bool {
            unchecked.append((link, params, isExplicit))
            return true
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            links.append(link)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// A relative path with a line, which the check would block, and a link it would
    /// block as unsafe both reach a delegate that takes them, unchanged and without an alert.
    @Test(arguments: [
        ("Sources/App/main.swift:12", false),
        ("file:///System/Applications/Calculator.app", true),
    ])
    func aDelegateCanTakeTheLinkBeforeTheCheck(link: String, isExplicit: Bool) async {
        let view = TerminalView(frame: .zero)
        let delegate = TakingDelegate()
        view.terminalDelegate = delegate
        var alerts = 0
        view.activateLink(link, params: ["id": "x"], isExplicit: isExplicit) { _, _, completion in
            alerts += 1
            completion(.alertFirstButtonReturn)
        }
        // An alert is queued on the main queue; give it the chance to appear.
        await Task.yield()
        await Task.yield()
        #expect(delegate.unchecked.map(\.link) == [link])
        #expect(delegate.unchecked.map(\.params) == [["id": "x"]])
        #expect(delegate.unchecked.map(\.isExplicit) == [isExplicit])
        #expect(delegate.links.isEmpty)
        #expect(alerts == 0)
    }

    @Test func anOsc8LinkIsNotOfferedWhileOsc8IsDisabled() {
        let view = TerminalView(frame: .zero)
        let delegate = TakingDelegate()
        view.terminalDelegate = delegate
        view.enableOsc8Hyperlinks = false
        view.activateLink("https://example.com", params: [:], isExplicit: true)
        #expect(delegate.unchecked.isEmpty)
        #expect(delegate.links.isEmpty)
    }

    /// A delegate that leaves the link gets the checked one, as before.
    @Test func aDelegateThatDeclinesGetsTheCheckedLink() {
        final class DecliningDelegate: TerminalViewDelegate {
            var offered = 0
            var links: [String] = []
            func openUncheckedLink(source: TerminalView, link: String, params: [String: String], isExplicit: Bool) -> Bool {
                offered += 1
                return false
            }
            func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
                links.append(link)
            }
            func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
            func setTerminalTitle(source: TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
            func send(source: TerminalView, data: ArraySlice<UInt8>) {}
            func scrolled(source: TerminalView, position: Double) {}
            func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        }
        let view = TerminalView(frame: .zero)
        let delegate = DecliningDelegate()
        view.terminalDelegate = delegate
        view.activateLink("https://example.com", params: [:], isExplicit: false)
        #expect(delegate.offered == 1)
        #expect(delegate.links == ["https://example.com"])
    }

    /// A `LocalProcessTerminalView` subclass takes links by overriding the method.
    @Test func aLocalProcessTerminalViewSubclassCanTakeTheLink() {
        final class Subclass: LocalProcessTerminalView {
            var unchecked: [String] = []
            override func openUncheckedLink(source: TerminalView, link: String, params: [String: String], isExplicit: Bool) -> Bool {
                unchecked.append(link)
                return true
            }
        }
        let view = Subclass(frame: .zero)
        view.activateLink("Sources/App/main.swift:12", params: [:], isExplicit: false) { _, _, _ in
            Issue.record("The link was checked")
        }
        #expect(view.unchecked == ["Sources/App/main.swift:12"])
    }
}
#endif
