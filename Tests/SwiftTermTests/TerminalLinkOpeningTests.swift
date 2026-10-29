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
}
#endif
