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
        /// Echo each backspace inside `send`, as a host that answers synchronously would.
        var echoesBackspaces = false
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            writes.append(Array(data))
            if echoesBackspaces {
                for byte in data where byte == 0x7f {
                    source.feed(text: "\u{8} \u{8}")
                }
            }
        }
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

    private func spaces(_ count: Int) -> String { String(repeating: " ", count: count) }

    @Test func deleteWithNothingTypedSeedsAPlaceholder() {
        let (view, delegate) = fixture(screen: "$ /compact")

        view.deleteBackward()

        #expect(backspaces(delegate) == 1)
        // One space per character left of the cursor, less the backspace not echoed yet.
        #expect(view.textInputStorage == spaces(9))
        #expect(view.textInputStorageIsPlaceholder)
        #expect(view.hasText)
    }

    @Test func thePlaceholderHidesTheScreenText() {
        let (view, _) = fixture(screen: "$ export TOKEN=secret")

        view.deleteBackward()

        #expect(view.textInputStorage.allSatisfy { $0 == " " })
        #expect(!view.textInputStorage.contains("secret"))
    }

    @Test func everyBackspaceNotEchoedCounts() {
        let (view, delegate) = fixture(screen: "$ ")
        view.insertText("/c")
        // The program completes what was typed.
        view.feed(text: "/compact")

        view.deleteBackward()
        view.deleteBackward()

        #expect(backspaces(delegate) == 2)
        // "$ /compact" less the two backspaces the program has not answered.
        #expect(view.textInputStorage == spaces(8))
        #expect(view.textInputStorageIsPlaceholder)
    }

    @Test func outputAfterABackspaceCountsAsItsEcho() {
        let (view, _) = fixture(screen: "$ abc")
        view.deleteBackward()
        // The program erases the character: the screen already shows the delete.
        view.feed(text: "\u{8} \u{8}")
        view.resetInputBuffer()

        view.deleteBackward()

        // "$ ab" less the one new backspace.
        #expect(view.textInputStorage == spaces(3))
    }

    @Test func aDiagnosticsResetDoesNotHideAnEcho() {
        let (view, _) = fixture(screen: "$ abc")
        view.deleteBackward()
        view.feed(text: "\u{8} \u{8}")
        view.resetDiagnostics()
        // Five bytes, as many as the screen: the fed-byte count lands back where it was at
        // the backspace, which made the echoed backspace look unechoed.
        view.feed(text: "\u{1b}[00m")
        view.resetInputBuffer()

        view.deleteBackward()

        // "$ ab" less the one new backspace.
        #expect(view.textInputStorage == spaces(3))
    }

    @Test func anEchoInsideSendCountsAsTheEcho() {
        let (view, delegate) = fixture(screen: "$ abc")
        delegate.echoesBackspaces = true

        view.deleteBackward()

        // The host erased the character before `send` returned: "$ ab", nothing unechoed.
        #expect(view.textInputStorage == spaces(4))
    }

    @Test func replaceCountsItsBackspaces() {
        let (view, delegate) = fixture(screen: "$ ")
        view.insertText("ab")
        view.feed(text: "ab")
        let end = view.endOfDocument
        let start = view.position(from: end, offset: -1)!
        view.replace(view.textRange(from: start, to: end)!, withText: "")

        view.deleteBackward()

        #expect(backspaces(delegate) == 2)
        // "$ ab" less the backspace from `replace` and the one from the delete.
        #expect(view.textInputStorage == spaces(2))
    }

    @Test func aRangeDeleteCountsItsBackspaces() {
        let (view, delegate) = fixture(screen: "$ ")
        view.insertText("ab")
        view.feed(text: "ab")
        view.selectedTextRange = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)

        view.deleteBackward()

        #expect(backspaces(delegate) == 2)
        #expect(view.textInputStorage == spaces(2))
    }

    @Test func wideCharactersCountOnce() {
        let (view, _) = fixture(screen: "$ 한글")

        view.deleteBackward()

        // Four characters on six cells, less one backspace; no NUL for the second cells.
        #expect(view.textInputStorage == spaces(3))
    }

    @Test func typedTextReplacesThePlaceholder() {
        let (view, _) = fixture(screen: "$ ls")
        view.deleteBackward()
        #expect(view.textInputStorageIsPlaceholder)

        view.insertText("x")

        #expect(view.textInputStorage == "x")
        #expect(!view.textInputStorageIsPlaceholder)
    }

    @Test func markedTextReplacesThePlaceholder() {
        let (view, _) = fixture(screen: "$ ls")
        view.deleteBackward()

        view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0))

        #expect(view.textInputStorage == "k")
        #expect(!view.textInputStorageIsPlaceholder)
    }

    @Test func replacingInThePlaceholderOnlyInserts() {
        let (view, delegate) = fixture(screen: "$ ls")
        view.deleteBackward()
        let sentBefore = backspaces(delegate)
        let end = view.endOfDocument
        let start = view.position(from: end, offset: -1)!

        view.replace(view.textRange(from: start, to: end)!, withText: "cd")

        // The placeholder may stand for screen text that has changed: nothing more is deleted.
        #expect(backspaces(delegate) == sentBefore)
        #expect(delegate.writes.last == Array("cd".utf8))
        #expect(!view.textInputStorageIsPlaceholder)
    }

    @Test func replacingInThePlaceholderIgnoresALatchedControl() throws {
        let (view, delegate) = fixture(screen: "$ ls")
        view.deleteBackward()
        // Ctrl latched on the accessory bar, which is where the text input reads it.
        let accessory = try #require(view.terminalAccessory)
        accessory.controlModifier = true
        let end = view.endOfDocument
        let start = view.position(from: end, offset: -1)!

        view.replace(view.textRange(from: start, to: end)!, withText: "cd")

        // A replacement goes as it is, as `replace` always sent it; Ctrl stays for the next key.
        #expect(delegate.writes.last == Array("cd".utf8))
        #expect(accessory.controlModifier)
    }

    @Test func theDoubleSpacePeriodSurvivesThePlaceholder() {
        let (view, delegate) = fixture(screen: "$ ")
        view.insertText(" ")
        // The keyboard deletes the space it is about to turn into ". ".
        view.deleteBackward()
        #expect(view.textInputStorageIsPlaceholder)

        view.insertText(". ")

        // The shell had the space deleted and gets two back, not ". ".
        #expect(delegate.writes.last == Array("  ".utf8))
    }

    @Test func aPendingKoreanResyllabificationKeepsTheBufferEmpty() {
        let (view, _) = fixture(screen: "$ ")
        // As after the keyboard deleted 핫 to put its final consonant on the next syllable.
        view.koreanResyllabificationTransaction.begin(deletedText: "핫")
        #expect(view.koreanResyllabificationIsPending)

        view.seedTextInputPlaceholder()

        #expect(view.textInputStorage == "")
        #expect(view.koreanResyllabificationIsPending)
    }

    @Test func deleteAtTheStartOfABufferWithTextAfterItSeedsNothing() {
        let (view, _) = fixture(screen: "$ ")
        view.insertText("ls")
        view.selectedTextRange = view.textRange(from: view.beginningOfDocument, to: view.beginningOfDocument)

        view.deleteBackward()

        #expect(view.textInputStorage == "ls")
        #expect(!view.textInputStorageIsPlaceholder)
    }

    @Test func deleteAtTheStartOfARowSeedsNothing() {
        let (view, delegate) = fixture(screen: "")

        view.deleteBackward()

        #expect(backspaces(delegate) == 1)
        #expect(view.textInputStorage == "")
        #expect(!view.textInputStorageIsPlaceholder)
    }
}
#endif
