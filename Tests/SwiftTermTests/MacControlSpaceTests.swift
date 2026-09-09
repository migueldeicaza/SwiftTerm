#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Testing
@testable import SwiftTerm

@MainActor
final class MacControlSpaceTests {
    private final class CapturingDelegate: TerminalViewDelegate {
        var sent: [UInt8] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func controlSpaceEvent(charactersIgnoringModifiers: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\0",
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: UInt16(kVK_Space)
        )!
    }

    @Test func controlSpaceSendsNulForAllAppKitCharacterRepresentations() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate

        for characters in [" ", "\0", ""] {
            view.keyDown(with: controlSpaceEvent(charactersIgnoringModifiers: characters))
        }

        #expect(delegate.sent == [0, 0, 0])
    }

    @Test func controlSpaceUsesSpaceCodepointWithKittyKeyboardProtocol() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = CapturingDelegate()
        view.terminalDelegate = delegate
        view.feed(text: "\u{1b}[>1u")

        for characters in [" ", "\0", ""] {
            delegate.sent.removeAll()
            view.keyDown(with: controlSpaceEvent(charactersIgnoringModifiers: characters))
            #expect(delegate.sent == Array("\u{1b}[32;5u".utf8))
        }
    }
}
#endif
