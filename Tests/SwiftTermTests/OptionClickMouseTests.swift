//
//  OptionClickMouseTests.swift
//
//  Option-drag selects a block, with or without mouse reporting; an
//  Option-click still reaches a reporting application, and with
//  `.requireModifier([.option])` it moves the cursor at an OSC 133 prompt.
//  Each test drives a real TerminalView with synthesized AppKit events.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

private final class SentDataDelegate: TerminalViewDelegate {
    var sentData: [[UInt8]] = []
    var openedLinks: [String] = []

    var sentText: String { String(decoding: sentData.joined(), as: UTF8.self) }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sentData.append(Array(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openedLinks.append(link)
    }
}

@MainActor
struct OptionClickMouseTests {
    private let esc = "\u{1b}"
    /// The modes Claude Code turns on: press and release, drag, all motion, SGR.
    private var claudeCodeMouseModes: String { "\(esc)[?1000h\(esc)[?1002h\(esc)[?1003h\(esc)[?1006h" }

    @MainActor private final class Harness {
        let view: TerminalView
        let window: NSWindow
        let delegate = SentDataDelegate()
        private var eventNumber = 0

        init() {
            view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
            window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
            window.contentView = view
            view.terminalDelegate = delegate
        }

        /// The middle of a cell, in the view's coordinates.
        func point(col: Int, row: Int) -> CGPoint {
            CGPoint(x: (CGFloat(col) + 0.5) * view.cellDimension.width,
                    y: view.frame.height - (CGFloat(row) + 0.5) * view.cellDimension.height)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint,
                              _ modifiers: NSEvent.ModifierFlags, clickCount: Int = 1) -> NSEvent {
            eventNumber += 1
            return NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
        }

        func click(col: Int, row: Int, _ modifiers: NSEvent.ModifierFlags = []) {
            let at = point(col: col, row: row)
            view.mouseDown(with: event(.leftMouseDown, at: at, modifiers))
            view.mouseUp(with: event(.leftMouseUp, at: at, modifiers))
        }

        func drag(from: (col: Int, row: Int), to: (col: Int, row: Int),
                             _ modifiers: NSEvent.ModifierFlags = []) {
            let start = point(col: from.col, row: from.row)
            let end = point(col: to.col, row: to.row)
            view.mouseDown(with: event(.leftMouseDown, at: start, modifiers))
            let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            view.mouseDragged(with: event(.leftMouseDragged, at: middle, modifiers))
            view.mouseDragged(with: event(.leftMouseDragged, at: end, modifiers))
            view.mouseUp(with: event(.leftMouseUp, at: end, modifiers))
        }

        var selectionIsBlock: Bool { view.withTerminal { _ in view.selection.isBlock } }
        var selectionActive: Bool { view.withTerminal { _ in view.selection.active } }

        /// Lets the view's main-queue callbacks run, then the send ones.
        func settle() async {
            for _ in 0..<3 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
    }

    private let table = "0123456789\r\nabcdefghij\r\nABCDEFGHIJ"

    // MARK: Option-drag, mouse reporting off

    @Test func optionDragSelectsABlock() async {
        let h = Harness()
        h.view.feed(text: table)

        h.drag(from: (2, 0), to: (5, 2), .option)
        await h.settle()

        #expect(h.selectionIsBlock)
        #expect(h.view.getSelection() == "234\ncde\nCDE")
        #expect(h.delegate.sentData.isEmpty)
    }

    @Test func plainDragStillSelectsAStream() async {
        let h = Harness()
        h.view.feed(text: table)

        h.drag(from: (2, 0), to: (5, 2))

        #expect(!h.selectionIsBlock)
        #expect(h.view.getSelection() == "23456789\nabcdefghij\nABCDE")
    }

    @Test func aNewClickEndsTheBlock() async {
        let h = Harness()
        h.view.feed(text: table)
        h.drag(from: (2, 0), to: (5, 2), .option)
        #expect(h.selectionIsBlock)

        h.click(col: 8, row: 1)

        #expect(!h.selectionActive)
        #expect(!h.selectionIsBlock)
    }

    @Test func shiftClickExtendsTheBlock() async {
        let h = Harness()
        h.view.feed(text: table)
        h.drag(from: (2, 0), to: (5, 1), .option)

        h.click(col: 7, row: 2, .shift)

        #expect(h.selectionIsBlock)
        #expect(h.view.getSelection() == "23456\ncdefg\nCDEFG")
    }

    // MARK: Mouse reporting on

    @Test func optionClickWithReportingSendsThePressAndRelease() async {
        let h = Harness()
        h.view.feed(text: claudeCodeMouseModes)
        let at = h.point(col: 3, row: 1)

        h.view.mouseDown(with: h.event(.leftMouseDown, at: at, .option))
        await h.settle()
        // Held until the button comes up or the pointer moves.
        #expect(h.delegate.sentData.isEmpty)

        // A wobble inside the cell is still a click.
        let wobble = CGPoint(x: at.x + 1, y: at.y)
        h.view.mouseDragged(with: h.event(.leftMouseDragged, at: wobble, .option))
        await h.settle()
        #expect(h.delegate.sentData.isEmpty)

        h.view.mouseUp(with: h.event(.leftMouseUp, at: wobble, .option))
        await h.settle()

        // Button 0 with the meta bit (8), at column 4, row 2, press then release.
        #expect(h.delegate.sentText == "\(esc)[<8;4;2M\(esc)[<8;4;2m")
        #expect(!h.selectionActive)
    }

    @Test func plainClickWithReportingIsUnchanged() async {
        let h = Harness()
        h.view.feed(text: claudeCodeMouseModes)
        let at = h.point(col: 3, row: 1)

        h.view.mouseDown(with: h.event(.leftMouseDown, at: at, []))
        await h.settle()
        #expect(h.delegate.sentText == "\(esc)[<0;4;2M")

        h.view.mouseUp(with: h.event(.leftMouseUp, at: at, []))
        await h.settle()
        #expect(h.delegate.sentText == "\(esc)[<0;4;2M\(esc)[<0;4;2m")
    }

    @Test func heldOptionClickIsDiscardedWhenReportingStops() async {
        let h = Harness()
        h.view.feed(text: claudeCodeMouseModes)
        let at = h.point(col: 3, row: 1)

        h.view.mouseDown(with: h.event(.leftMouseDown, at: at, .option))
        h.view.feed(text: "\(esc)[?1000l\(esc)[?1002l\(esc)[?1003l")
        #expect(h.view.withTerminal { $0.mouseMode } == .off)
        h.view.mouseUp(with: h.event(.leftMouseUp, at: at, .option))
        await h.settle()

        #expect(h.delegate.sentData.isEmpty)
        #expect(!h.selectionActive)
    }

    @Test func heldOptionClickIsDiscardedWhenTheHostDisablesReporting() async {
        let h = Harness()
        h.view.feed(text: claudeCodeMouseModes)
        let at = h.point(col: 3, row: 1)

        h.view.mouseDown(with: h.event(.leftMouseDown, at: at, .option))
        h.view.allowMouseReporting = false
        h.view.mouseUp(with: h.event(.leftMouseUp, at: at, .option))
        await h.settle()

        #expect(h.delegate.sentData.isEmpty)
        #expect(!h.selectionActive)
    }

    @Test func shiftAtReleaseDiscardsAHeldOptionClick() async {
        let h = Harness()
        h.view.feed(text: claudeCodeMouseModes)
        let at = h.point(col: 3, row: 1)

        h.view.mouseDown(with: h.event(.leftMouseDown, at: at, .option))
        h.view.mouseUp(with: h.event(.leftMouseUp, at: at, [.option, .shift]))
        await h.settle()

        #expect(h.delegate.sentData.isEmpty)
        #expect(!h.selectionActive)
    }

    @Test func shiftAtReleaseReportsWhenTheApplicationCapturesShift() async {
        let h = Harness()
        h.view.feed(text: claudeCodeMouseModes + "\(esc)[>1s")
        let at = h.point(col: 3, row: 1)

        h.view.mouseDown(with: h.event(.leftMouseDown, at: at, .option))
        h.view.mouseUp(with: h.event(.leftMouseUp, at: at, [.option, .shift]))
        await h.settle()

        #expect(h.delegate.sentText == "\(esc)[<8;4;2M\(esc)[<12;4;2m")
        #expect(!h.selectionActive)
    }

    @Test func releasingOptionBeforeTheButtonStillReportsTheClick() async {
        let h = Harness()
        h.view.feed(text: claudeCodeMouseModes)
        let at = h.point(col: 3, row: 1)

        h.view.mouseDown(with: h.event(.leftMouseDown, at: at, .option))
        h.view.mouseUp(with: h.event(.leftMouseUp, at: at, []))
        await h.settle()

        #expect(h.delegate.sentText == "\(esc)[<8;4;2M\(esc)[<0;4;2m")
        #expect(!h.selectionActive)
    }

    @Test func optionDragWithReportingSelectsABlockAndSendsNothing() async {
        let h = Harness()
        h.view.feed(text: table + claudeCodeMouseModes)

        h.drag(from: (2, 0), to: (5, 2), .option)
        await h.settle()

        #expect(h.delegate.sentData.isEmpty)
        #expect(h.selectionIsBlock)
        #expect(h.view.getSelection() == "234\ncde\nCDE")
    }

    @Test func optionReleaseInAnotherCellWithReportingSelectsABlock() async {
        let h = Harness()
        h.view.feed(text: table + claudeCodeMouseModes)

        // No drag events in between: the release alone says it moved.
        h.view.mouseDown(with: h.event(.leftMouseDown, at: h.point(col: 1, row: 0), .option))
        h.view.mouseUp(with: h.event(.leftMouseUp, at: h.point(col: 4, row: 1), .option))
        await h.settle()

        #expect(h.delegate.sentData.isEmpty)
        #expect(h.view.getSelection() == "123\nbcd")
    }

    @Test func plainDragWithReportingStillReports() async {
        let h = Harness()
        h.view.feed(text: table + claudeCodeMouseModes)

        h.drag(from: (2, 0), to: (5, 2))
        await h.settle()

        #expect(h.delegate.sentText.hasPrefix("\(esc)[<0;3;1M"))
        #expect(h.delegate.sentText.hasSuffix("\(esc)[<0;6;3m"))
        #expect(!h.selectionActive)
    }

    @Test func optionDoubleClickWithReportingIsNotHeld() async {
        let h = Harness()
        h.view.feed(text: claudeCodeMouseModes)
        let at = h.point(col: 3, row: 1)

        h.view.mouseDown(with: h.event(.leftMouseDown, at: at, .option, clickCount: 2))
        await h.settle()

        #expect(h.delegate.sentText == "\(esc)[<8;4;2M")
    }

    // MARK: Option-click at an OSC 133 prompt

    /// A zsh-style prompt that asks for cursor-key clicks, then typed input.
    private func armPrompt(_ h: Harness, input: String = "echo hi") {
        h.view.semanticPromptClickBehavior = .requireModifier([.option])
        h.view.feed(text: "\(esc)]133;A;cl=m\u{07}$ \(esc)]133;B\u{07}\(input)")
    }

    @Test func semanticPromptClickBehaviorIsTheTerminals() {
        let h = Harness()
        #expect(h.view.semanticPromptClickBehavior == .enabled)

        h.view.semanticPromptClickBehavior = .requireModifier([.option])

        #expect(h.view.withTerminal { $0.semanticPromptClickBehavior } == .requireModifier([.option]))
        #expect(h.view.semanticPromptClickBehavior == .requireModifier([.option]))
    }

    @Test func optionClickAtThePromptMovesTheCursor() async {
        let h = Harness()
        armPrompt(h)

        // "$ echo hi": the cursor is after "hi", at column 9; click the "h" of "echo".
        h.click(col: 4, row: 0, .option)
        await h.settle()

        #expect(h.delegate.sentText == String(repeating: "\(esc)[D", count: 5))
        #expect(!h.selectionActive)
    }

    @Test func plainClickAtThePromptSendsNothing() async {
        let h = Harness()
        armPrompt(h)

        h.click(col: 4, row: 0)
        await h.settle()

        #expect(h.delegate.sentData.isEmpty)
    }

    @Test func optionClickAtThePromptClearsASelectionAndStillMoves() async {
        let h = Harness()
        armPrompt(h)
        h.view.withTerminal { _ in h.view.selection.select(row: 0) }

        h.click(col: 4, row: 0, .option)
        await h.settle()

        #expect(!h.selectionActive)
        #expect(h.delegate.sentText == String(repeating: "\(esc)[D", count: 5))
    }

    @Test func optionClickAtThePromptBeatsALink() async {
        let h = Harness()
        h.view.linkHighlightMode = .always
        armPrompt(h, input: "open \(esc)]8;;https://example.com\(esc)\\example\(esc)]8;;\(esc)\\")

        // "$ open example": the cursor is at column 14; click the "x" at column 8.
        h.click(col: 8, row: 0, .option)
        await h.settle()
        #expect(h.delegate.openedLinks.isEmpty)
        #expect(h.delegate.sentText == String(repeating: "\(esc)[D", count: 6))

        // A plain click there still opens the link.
        h.click(col: 8, row: 0)
        #expect(h.delegate.openedLinks == ["https://example.com"])
    }

    @Test func optionDragAtThePromptSelectsInsteadOfMoving() async {
        let h = Harness()
        armPrompt(h)

        h.drag(from: (2, 0), to: (6, 0), .option)
        await h.settle()

        #expect(h.delegate.sentData.isEmpty)
        #expect(h.view.getSelection() == "echo")
    }
}
#endif
