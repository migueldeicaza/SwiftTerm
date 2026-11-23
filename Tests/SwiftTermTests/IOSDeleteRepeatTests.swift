#if os(iOS)
import UIKit
import Testing

@testable import SwiftTerm

/// Holding delete over text the program wrote: the keyboard repeats only while the
/// text input reports text before the cursor.
@Suite(.serialized)
@MainActor
struct IOSDeleteRepeatTests {
    private final class Delegate: TerminalViewDelegate {
        var writes: [[UInt8]] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { writes.append(Array(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }

    private func fixture(screen: String) -> (TerminalView, Delegate) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.feed(text: screen)
        return (view, delegate)
    }

    private func backspaces(_ delegate: Delegate) -> Int {
        delegate.writes.reduce(0) { $0 + $1.filter { $0 == 0x7f }.count }
    }

    @Test func deleteWithNothingTypedSeedsTheScreenTextBeforeTheCursor() {
        let (view, delegate) = fixture(screen: "$ /compact")

        view.deleteBackward()

        #expect(backspaces(delegate) == 1)
        // The backspace is not echoed yet: one character less than the screen shows.
        #expect(view.textInputStorage == "$ /compac")
        #expect(view.textInputStorageIsFromScreen)
        #expect(view.hasText)
    }

    @Test func deletingTheLastTypedCharacterSeedsTheScreenText() {
        let (view, delegate) = fixture(screen: "$ ")
        view.insertText("/c")
        // The program completes what was typed.
        view.feed(text: "/compact")

        view.deleteBackward()
        view.deleteBackward()

        #expect(backspaces(delegate) == 2)
        #expect(view.textInputStorage == "$ /compac")
        #expect(view.textInputStorageIsFromScreen)
    }

    @Test func typedTextReplacesTheSeed() {
        let (view, _) = fixture(screen: "$ ls")
        view.deleteBackward()
        #expect(view.textInputStorageIsFromScreen)

        view.insertText("x")

        #expect(view.textInputStorage == "x")
        #expect(!view.textInputStorageIsFromScreen)
    }

    @Test func markedTextReplacesTheSeed() {
        let (view, _) = fixture(screen: "$ ls")
        view.deleteBackward()

        view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0))

        #expect(view.textInputStorage == "k")
        #expect(!view.textInputStorageIsFromScreen)
    }

    @Test func deleteAtTheStartOfARowSeedsNothing() {
        let (view, delegate) = fixture(screen: "")

        view.deleteBackward()

        #expect(backspaces(delegate) == 1)
        #expect(view.textInputStorage == "")
        #expect(!view.textInputStorageIsFromScreen)
    }
}
#endif
