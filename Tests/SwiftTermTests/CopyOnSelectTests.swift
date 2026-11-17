//
//  CopyOnSelectTests.swift
//
//  `copyOnSelect` copies the selection at the end of a user gesture, and
//  `selectionFinished` reports the same event. Each test drives a real
//  TerminalView with synthesized AppKit events and a private pasteboard, so
//  the general pasteboard of the machine does not change.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

private final class SelectionDelegate: TerminalViewDelegate {
    var finished: [String?] = []
    var sent = ""

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += String(decoding: data, as: UTF8.self) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    var clearsSelection = false
    func selectionFinished(source: TerminalView) {
        finished.append(source.getSelection())
        if clearsSelection { source.selectNone() }
    }
}

private final class ProcessDelegate: LocalProcessHostStubs {
    var finished: [String?] = []

    func selectionFinished(source: TerminalView) {
        finished.append(source.getSelection())
    }
}

@MainActor
struct CopyOnSelectTests {
    @MainActor private final class Harness {
        let view: TerminalView
        let window: NSWindow
        let delegate = SelectionDelegate()
        let pasteboard = NSPasteboard.withUniqueName()
        let primaryPasteboard = NSPasteboard.withUniqueName()
        private var eventNumber = 0

        init(copyOnSelect: CopyOnSelectMode = .clipboard, view: TerminalView? = nil) {
            self.view = view ?? TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
            let view = self.view
            window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
            window.contentView = view
            if !(view is LocalProcessTerminalView) {
                view.terminalDelegate = delegate
            }
            view.selectionPasteboard = pasteboard
            view.primarySelectionPasteboard = primaryPasteboard
            view.copyOnSelect = copyOnSelect
            view.feed(text: "hello world\r\nsecond line\r\nthird\r\n\r\na    b")
        }

        isolated deinit {
            pasteboard.releaseGlobally()
            primaryPasteboard.releaseGlobally()
        }

        var copied: String? { pasteboard.string(forType: .string) }
        var primaryCopied: String? { primaryPasteboard.string(forType: .string) }

        func point(col: Int, row: Int) -> CGPoint {
            CGPoint(x: (CGFloat(col) + 0.5) * view.cellDimension.width,
                    y: view.frame.height - (CGFloat(row) + 0.5) * view.cellDimension.height)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint,
                   _ modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent {
            eventNumber += 1
            return NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
        }

        func drag(from: (col: Int, row: Int), to: (col: Int, row: Int),
                  _ modifiers: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: event(.leftMouseDown, at: point(col: from.col, row: from.row), modifiers))
            view.mouseDragged(with: event(.leftMouseDragged, at: point(col: to.col, row: to.row), modifiers))
            view.mouseUp(with: event(.leftMouseUp, at: point(col: to.col, row: to.row), modifiers))
        }

        func click(col: Int, row: Int, _ modifiers: NSEvent.ModifierFlags = [], count: Int = 1) {
            let at = point(col: col, row: row)
            for n in 1...count {
                view.mouseDown(with: event(.leftMouseDown, at: at, modifiers, clickCount: n))
                view.mouseUp(with: event(.leftMouseUp, at: at, modifiers, clickCount: n))
            }
        }

        func press(col: Int, row: Int) {
            view.mouseDown(with: event(.leftMouseDown, at: point(col: col, row: row)))
        }

        func dragTo(col: Int, row: Int) {
            view.mouseDragged(with: event(.leftMouseDragged, at: point(col: col, row: row)))
        }

        func release(col: Int, row: Int) {
            view.mouseUp(with: event(.leftMouseUp, at: point(col: col, row: row)))
        }
    }

    @Test func dragCopiesOnlyAtMouseUp() {
        let h = Harness()

        h.press(col: 0, row: 0)
        h.dragTo(col: 3, row: 0)
        h.dragTo(col: 5, row: 0)
        #expect(h.copied == nil)
        #expect(h.delegate.finished.isEmpty)

        h.release(col: 5, row: 0)
        #expect(h.copied == "hello")
        #expect(h.delegate.finished == ["hello"])
    }

    @Test func doubleClickCopiesTheWord() {
        let h = Harness()
        h.click(col: 7, row: 0, count: 2)
        #expect(h.copied == "world")
        #expect(h.delegate.finished == ["world"])
    }

    /// The second click completes a word selection before the third click
    /// arrives, thus a triple-click reports the word and then the row.
    @Test func tripleClickCopiesTheWordThenTheRow() {
        let h = Harness()
        h.click(col: 2, row: 1, count: 3)
        #expect(h.copied == "second line")
        #expect(h.delegate.finished == ["second", "second line"])
    }

    @Test func optionDragCopiesTheBlock() {
        let h = Harness()
        h.drag(from: (0, 0), to: (3, 1), .option)
        #expect(h.copied == "hel\nsec")
        #expect(h.delegate.finished == ["hel\nsec"])
    }

    @Test func optionDragWithMouseReportingCopiesTheBlock() {
        let h = Harness()
        h.view.feed(text: "\u{1b}[?1000h")
        h.drag(from: (0, 0), to: (3, 1), .option)
        #expect(h.copied == "hel\nsec")
    }

    @Test func whiteSpaceSelectionKeepsThePasteboard() {
        let h = Harness()
        h.click(col: 1, row: 0, count: 2)
        #expect(h.copied == "hello")

        h.drag(from: (1, 4), to: (4, 4))
        #expect(h.delegate.finished == ["hello", "   "])
        #expect(h.copied == "hello")
    }

    @Test func delegateThatClearsTheSelectionStopsTheCopy() {
        let h = Harness()
        h.delegate.clearsSelection = true
        h.click(col: 7, row: 0, count: 2)
        #expect(h.delegate.finished == ["world"])
        #expect(h.copied == nil)
    }

    @Test func copyCommandUsesTheSamePasteboard() {
        let h = Harness(copyOnSelect: .off)
        h.click(col: 7, row: 0, count: 2)
        #expect(h.copied == nil)
        h.view.copy(h.view)
        #expect(h.copied == "world")
    }

    @Test func localProcessViewForwardsToTheProcessDelegate() {
        let processDelegate = ProcessDelegate()
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.processDelegate = processDelegate
        let h = Harness(view: view)

        h.click(col: 7, row: 0, count: 2)
        #expect(processDelegate.finished == ["world"])
        #expect(h.copied == "world")
    }

    /// Output that moves the selected rows in place must not look like a
    /// change that the user made. A user change must.
    @Test func inPlaceScrollKeepsTheSelectionRevision() {
        let h = Harness()
        h.click(col: 7, row: 0, count: 2)
        let revision = h.view.withTerminal { _ in h.view.selection.revision }

        h.view.feed(text: "\u{1b}[1;5r\u{1b}[T")
        #expect(h.view.withTerminal { _ in h.view.selection.start.row } == 1)
        #expect(h.view.getSelection() == "world")
        #expect(h.view.withTerminal { _ in h.view.selection.revision } == revision)

        h.click(col: 1, row: 1, count: 2)
        #expect(h.view.getSelection() == "hello")
        #expect(h.view.withTerminal { _ in h.view.selection.revision } != revision)
    }

    @Test func shiftClickCopiesTheExtendedSelection() {
        let h = Harness()
        h.click(col: 1, row: 0, count: 2)
        #expect(h.copied == "hello")

        h.click(col: 10, row: 0, .shift)
        #expect(h.copied == "hello world")
    }

    @Test func plainClickDoesNotCopy() {
        let h = Harness()
        h.click(col: 1, row: 0, count: 2)
        h.pasteboard.clearContents()

        h.click(col: 3, row: 1)
        #expect(h.copied == nil)
        #expect(h.delegate.finished == ["hello"])
    }

    @Test func selectAllCommandCopies() {
        let h = Harness()
        h.view.selectAll(nil)
        #expect(h.copied?.hasPrefix("hello world\nsecond line\nthird") == true)
        #expect(h.delegate.finished.count == 1)
    }

    @Test func hostAndSearchSelectionsDoNotCopy() {
        let h = Harness()
        h.view.selectAll()
        #expect(h.view.findNext("second"))
        #expect(h.view.getSelection() == "second")
        #expect(h.copied == nil)
        #expect(h.delegate.finished.isEmpty)
    }

    @Test func clipboardModeKeepsThePrimarySelection() {
        let h = Harness(copyOnSelect: .clipboard)
        h.click(col: 7, row: 0, count: 2)
        #expect(h.copied == "world")
        #expect(h.primaryCopied == nil)
    }

    @Test func primarySelectionModeKeepsTheClipboard() {
        let h = Harness(copyOnSelect: .primarySelection)
        h.click(col: 7, row: 0, count: 2)
        #expect(h.copied == nil)
        #expect(h.primaryCopied == "world")
    }

    @Test func bothModeWritesTheTwoPasteboards() {
        let h = Harness(copyOnSelect: .both)
        h.click(col: 7, row: 0, count: 2)
        #expect(h.copied == "world")
        #expect(h.primaryCopied == "world")
    }

    @Test func pastePrimarySelectionSendsTheSelectedText() async {
        let h = Harness(copyOnSelect: .primarySelection)
        h.click(col: 7, row: 0, count: 2)
        h.view.pastePrimarySelection()
        // The view sends from the main queue.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(h.delegate.sent == "world")
    }

    @Test func propertyOffReportsButDoesNotCopy() {
        let h = Harness(copyOnSelect: .off)
        h.click(col: 7, row: 0, count: 2)
        #expect(h.copied == nil)
        #expect(h.delegate.finished == ["world"])
    }

    @Test func mouseReportingKeepsTheSelectionEvents() {
        let h = Harness()
        h.view.feed(text: "\u{1b}[?1000h")
        h.click(col: 7, row: 0, count: 2)
        #expect(h.copied == nil)
        #expect(h.delegate.finished.isEmpty)
    }
}
#endif
