#if os(iOS) || os(visionOS)
import Testing
import UIKit
@testable import SwiftTerm

/// `keepsDeleteRepeatingOverTerminalText` keeps a placeholder before the typed text so the
/// system keyboard sees something to delete and keeps auto-repeating over text the terminal
/// drew itself (a recalled history line), while what reaches the terminal stays the same.
@MainActor
struct IOSDeleteRepeatTests {
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

    private func makeView(keepsRepeating: Bool) -> (TerminalView, CapturingDelegate) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let capture = CapturingDelegate()
        view.terminalDelegate = capture
        view.keepsDeleteRepeatingOverTerminalText = keepsRepeating
        return (view, capture)
    }

    /// What the keyboard sees before the caret.
    private func textBeforeCaret(_ view: TerminalView) -> String {
        guard let caret = view.selectedTextRange?.start,
              let range = view.textRange(from: view.beginningOfDocument, to: caret) else { return "" }
        return view.text(in: range) ?? ""
    }

    @Test func offByDefaultLeavesTheDocumentEmpty() {
        let (view, _) = makeView(keepsRepeating: false)
        #expect(textBeforeCaret(view).isEmpty)
        #expect(!view.hasText)
    }

    @Test func emptyLineStillOffersSomethingToDelete() {
        let (view, capture) = makeView(keepsRepeating: true)
        #expect(!textBeforeCaret(view).isEmpty)
        #expect(view.hasText)

        // Holding delete on a line the shell drew: every repeat sends a backspace, and the
        // keyboard can still see text before the caret afterwards.
        for _ in 0..<5 {
            view.deleteBackward()
            #expect(!textBeforeCaret(view).isEmpty)
        }
        #expect(capture.sent == Array(repeating: 0x7f, count: 5))
    }

    @Test func typedTextIsDeletedThenTheTerminalLine() {
        let (view, capture) = makeView(keepsRepeating: true)
        view.insertText("ab")
        #expect(capture.sent == Array("ab".utf8))
        capture.sent.removeAll()

        for _ in 0..<4 { view.deleteBackward() }
        // Two backspaces for the typed "ab", two more for the shell's own line.
        #expect(capture.sent == Array(repeating: 0x7f, count: 4))
        #expect(!textBeforeCaret(view).isEmpty)
    }

    @Test func placeholderIsNeverSent() {
        let (view, capture) = makeView(keepsRepeating: true)
        view.insertText("ls")
        view.insertText("\n")
        view.insertText("x")
        #expect(!capture.sent.contains(0xe2))  // U+200B is E2 80 8B in UTF-8
        #expect(String(decoding: capture.sent, as: UTF8.self).hasSuffix("x"))
    }

    @Test func deletingASelectionThatIncludesThePlaceholderSendsOneBackspaceForIt() {
        let (view, capture) = makeView(keepsRepeating: true)
        view.insertText("ab")
        capture.sent.removeAll()

        // The keyboard's word-at-a-time delete selects back to the start, then deletes.
        if let end = view.selectedTextRange?.start {
            view.selectedTextRange = view.textRange(from: view.beginningOfDocument, to: end)
        }
        view.deleteBackward()
        #expect(capture.sent == Array(repeating: 0x7f, count: 3))
        #expect(!textBeforeCaret(view).isEmpty)
    }

    @Test func turningItOffClearsThePlaceholder() {
        let (view, _) = makeView(keepsRepeating: true)
        view.keepsDeleteRepeatingOverTerminalText = false
        #expect(textBeforeCaret(view).isEmpty)
        #expect(!view.hasText)
    }
}
#endif
