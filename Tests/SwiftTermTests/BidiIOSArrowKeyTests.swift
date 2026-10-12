//
//  BidiIOSArrowKeyTests.swift
//
//  The UIKit key paths that send horizontal arrow keys use the BiDi swap
//  of the terminal.
//
#if os(iOS)
import Foundation
import UIKit
import Testing

@testable import SwiftTerm

@MainActor
final class BidiIOSArrowKeyTests {
    final class CapturingDelegate: TerminalViewDelegate {
        var sent: [UInt8] = []
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }

    let delegate = CapturingDelegate()

    func makeView(feed text: String) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 480, height: 200))
        view.feed(text: text)
        view.terminalDelegate = delegate
        return view
    }

    /// The view sends terminal responses on the main queue.
    func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func sendKeyLeftAndRightSwap() {
        let view = makeView(feed: "אב")
        view.sendKeyLeft()
        view.sendKeyRight()
        #expect(delegate.sent == EscapeSequences.moveRightNormal + EscapeSequences.moveLeftNormal)
        delegate.sent.removeAll()
        view.withTerminal { $0.bidiArrowKeySwap = false }
        view.sendKeyLeft()
        #expect(delegate.sent == EscapeSequences.moveLeftNormal)
    }

    @Test func panGestureKeysSwap() {
        let view = makeView(feed: "אב")
        view.sendKey(deltaCol: 1, deltaRow: 0)
        view.sendKey(deltaCol: -1, deltaRow: 0)
        #expect(delegate.sent == EscapeSequences.moveRightNormal + EscapeSequences.moveLeftNormal)
    }

    @Test func accessoryRepeatKeepsTheKeyOfThePress() {
        let view = makeView(feed: "אב\r\nabc\u{1b}[1;1H")
        let accessory = TerminalAccessory(frame: CGRect(x: 0, y: 0, width: 320, height: 40),
                                          inputViewStyle: .keyboard, container: view)
        accessory.left(UIButton())
        #expect(delegate.sent == EscapeSequences.moveRightNormal)
        // The cursor moves into a left-to-right paragraph while the button is down.
        view.feed(text: "\u{1b}[2;1H")
        delegate.sent.removeAll()
        accessory.repeatCommand?()
        #expect(delegate.sent == EscapeSequences.moveRightNormal)
        accessory.cancelTimer()
        // The next press chooses again.
        delegate.sent.removeAll()
        accessory.left(UIButton())
        accessory.cancelTimer()
        #expect(delegate.sent == EscapeSequences.moveLeftNormal)
    }

    @Test func floatingCursorSwapsAndMovesTheInputOffsetWithTheSentKey() {
        let view = makeView(feed: "אב")
        view.beginFloatingCursor(at: CGPoint(x: 100, y: 10))
        // The finger moves to the left.
        view.updateFloatingCursor(at: CGPoint(x: 90, y: 10))
        view.endFloatingCursor()
        #expect(delegate.sent == EscapeSequences.moveRightNormal)
        delegate.sent.removeAll()
        view.withTerminal { $0.bidiArrowKeySwap = false }
        view.beginFloatingCursor(at: CGPoint(x: 100, y: 10))
        view.updateFloatingCursor(at: CGPoint(x: 90, y: 10))
        view.endFloatingCursor()
        #expect(delegate.sent == EscapeSequences.moveLeftNormal)
    }

    @Test func viewHostPolicyControlsTheSwapAndTheReport() async {
        let view = makeView(feed: "אב")
        view.feed(text: "\u{1b}[?1243$p")
        await drainMainQueue()
        #expect(delegate.sent == Array("\u{1b}[?1243;1$y".utf8))

        view.bidiHostPolicy = .legacyLeftToRight
        #expect(view.withTerminal { $0.bidiHostPolicy } == .legacyLeftToRight)
        delegate.sent.removeAll()
        view.feed(text: "\u{1b}[?1243$p")
        await drainMainQueue()
        #expect(delegate.sent == Array("\u{1b}[?1243;4$y".utf8))
        delegate.sent.removeAll()
        view.sendKeyLeft()
        #expect(delegate.sent == EscapeSequences.moveLeftNormal)
    }
}
#endif
