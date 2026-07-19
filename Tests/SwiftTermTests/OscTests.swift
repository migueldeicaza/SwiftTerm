//
//  OscTests.swift
//  
//
//  Created by Miguel de Icaza on 4/13/20.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class SwiftTermOsc {
    private final class TitleDelegate: TerminalDelegate {
        private(set) var titles: [String] = []

        func setTerminalTitle(source: Terminal, title: String) {
            titles.append(title)
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private final class ProgressDelegate: TerminalDelegate {
        private(set) var reports: [Terminal.ProgressReport] = []

        func progressReport(source: Terminal, report: Terminal.ProgressReport) {
            reports.append(report)
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test func testOscTitleBelTerminator() {
        let delegate = TitleDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]0;abc\u{07}")

        #expect(delegate.titles.last == "abc")
    }

    @Test func testOscTitleStTerminator() {
        let delegate = TitleDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]2;def\u{1b}\\")

        #expect(delegate.titles.last == "def")
    }
    
    @Test func testOscTerminalTitle() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        
        let t = h.terminal!
        
        t.feed (text: "\u{39b}\u{30a}\nv\u{307}\nr\u{308}\na\u{20d1}\nb\u{20d1}")
        
        #expect(t.hostCurrentDirectory == nil)
        t.feed (text: "\u{1b}]7;file:///localhost/usr/bin\u{7}")
        #expect(t.hostCurrentDirectory == "file:///localhost/usr/bin")
    }

    @Test func testOscProgressReportSetAndClamp() {
        let delegate = ProgressDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]9;4;1;50\u{07}")
        #expect(delegate.reports.last?.state == .set)
        #expect(delegate.reports.last?.progress == 50)

        terminal.feed(text: "\u{1b}]9;4;1;999\u{07}")
        #expect(delegate.reports.last?.state == .set)
        #expect(delegate.reports.last?.progress == 100)
    }

    @Test func testOscProgressReportMissingProgressDefaults() {
        let delegate = ProgressDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]9;4;1\u{07}")
        #expect(delegate.reports.last?.state == .set)
        #expect(delegate.reports.last?.progress == 0)

        terminal.feed(text: "\u{1b}]9;4;3\u{07}")
        #expect(delegate.reports.last?.state == .indeterminate)
        #expect(delegate.reports.last?.progress == nil)
    }

    // MARK: - OSC Tests Ported from Ghostty

    /// Test OSC 1 (icon title) with BEL terminator
    /// From Ghostty: comprehensive OSC testing
    @Test func testOscIconTitleBel() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        t.feed(text: "\u{1b}]1;icon-name\u{07}")
        // Icon title is set - implementation may or may not expose this
    }

    /// Test OSC 0 (combined title) sets both window and icon title
    /// From Ghostty: "osc: change window title"
    @Test func testOscCombinedTitle() {
        let delegate = TitleDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]0;combined-title\u{07}")
        #expect(delegate.titles.last == "combined-title")
    }

    /// Disabeld Test OSC with C1 ST terminator (0x9C)
    /// From Ghostty: different terminator handling
    ///
    /// Disabled this due to the long-term tension on how to process this value,
    /// Xterm has historically had a special flag set to determine how to parse this
    /// the challenge is that 0x9c can be a part of UTF-8 sequence, so our parser
    /// would abort the processing of a valid string in places where strings are
    /// allowed.
    ///
    /// Besides, VTE ignores it

//    @Test func testOscC1Terminator() {
//        let delegate = TitleDelegate()
//        let terminal = Terminal(
//            delegate: delegate,
//            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
//        )
//
//        // Use raw bytes to avoid UTF-8 encoding of 0x9C (which becomes 0xC2 0x9C)
//        var bytes: [UInt8] = [0x1b, 0x5d, 0x30, 0x3b]  // ESC ] 0 ;
//        bytes.append(contentsOf: "c1-title".utf8)
//        bytes.append(0x9c)  // C1 ST terminator
//        terminal.feed(byteArray: bytes)
//
//        #expect(delegate.titles.last == "c1-title")
//    }

    /// Test OSC 7 (current working directory) with various URL formats
    /// From Ghostty: "report_pwd"
    @Test func testOscPwdVariousFormats() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Standard file URL
        t.feed(text: "\u{1b}]7;file:///home/user/dir\u{07}")
        #expect(t.hostCurrentDirectory == "file:///home/user/dir")

        // URL with hostname
        t.feed(text: "\u{1b}]7;file://hostname/path/to/dir\u{07}")
        #expect(t.hostCurrentDirectory == "file://hostname/path/to/dir")

        // URL with percent encoding
        t.feed(text: "\u{1b}]7;file:///path%20with%20spaces\u{07}")
        #expect(t.hostCurrentDirectory == "file:///path%20with%20spaces")
    }

    /// Test OSC 8 (hyperlinks) - start and end
    /// From Ghostty: "hyperlink_start", "hyperlink_end"
    @Test func testOscHyperlinks() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Start hyperlink
        t.feed(text: "\u{1b}]8;;https://example.com\u{07}")
        t.feed(text: "link text")
        // End hyperlink
        t.feed(text: "\u{1b}]8;;\u{07}")
        t.feed(text: " normal")

        // The terminal should have processed the hyperlink
        // Verification depends on how SwiftTerm exposes hyperlink data
    }

    /// Test OSC 8 hyperlinks with ID parameter
    /// From Ghostty: hyperlink with id
    @Test func testOscHyperlinkWithId() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Hyperlink with explicit ID
        t.feed(text: "\u{1b}]8;id=mylink;https://example.com\u{07}")
        t.feed(text: "click me")
        t.feed(text: "\u{1b}]8;;\u{07}")

        // Should not crash, ID helps group multi-line hyperlinks
    }

    private final class ClipboardDelegate: TerminalDelegate {
        var copiedContent: Data?
        var clipboardData: Data?
        var sentData: [UInt8] = []

        func clipboardCopy(source: Terminal, content: Data) {
            copiedContent = content
        }

        func clipboardRead(source: Terminal) -> Data? {
            return clipboardData
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sentData.append(contentsOf: data)
        }
    }

    private final class SemanticDelegate: TerminalDelegate {
        private(set) var sentData: [UInt8] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sentData.append(contentsOf: data)
        }
    }

    /// Test OSC 52 clipboard write with selection type "c"
    @Test func testOscClipboardWrite() {
        let delegate = ClipboardDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        // "hello" in base64 is "aGVsbG8="
        terminal.feed(text: "\u{1b}]52;c;aGVsbG8=\u{07}")
        #expect(delegate.copiedContent == "hello".data(using: .utf8))
    }

    /// Test OSC 52 clipboard write with primary selection type "p"
    @Test func testOscClipboardWritePrimarySelection() {
        let delegate = ClipboardDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;p;aGVsbG8=\u{07}")
        #expect(delegate.copiedContent == "hello".data(using: .utf8))
    }

    /// Test OSC 52 clipboard write with empty selection (defaults to "c")
    @Test func testOscClipboardWriteDefaultSelection() {
        let delegate = ClipboardDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;;aGVsbG8=\u{07}")
        #expect(delegate.copiedContent == "hello".data(using: .utf8))
    }

    /// Test OSC 52 clipboard write with invalid base64 is ignored
    @Test func testOscClipboardWriteInvalidBase64() {
        let delegate = ClipboardDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;c;not!valid!base64!!!\u{07}")
        #expect(delegate.copiedContent == nil)
    }

    /// Test OSC 52 clipboard read query – delegate allows
    @Test func testOscClipboardReadAllowed() {
        let delegate = ClipboardDelegate()
        delegate.clipboardData = "from clipboard".data(using: .utf8)
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;c;?\u{07}")

        let response = String(bytes: delegate.sentData, encoding: .utf8) ?? ""
        let base64 = Data("from clipboard".utf8).base64EncodedString()
        #expect(response.contains("52;c;\(base64)"))
    }

    /// Test OSC 52 clipboard read query – delegate denies (returns nil)
    @Test func testOscClipboardReadDenied() {
        let delegate = ClipboardDelegate()
        delegate.clipboardData = nil
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]52;c;?\u{07}")

        // No response should be sent when denied
        #expect(delegate.sentData.isEmpty)
    }

    /// Test OSC 52 clipboard read – default delegate denies
    @Test func testOscClipboardReadDefaultDenied() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Query clipboard — default clipboardRead returns nil, so no response
        t.feed(text: "\u{1b}]52;c;?\u{07}")
    }

    /// Test OSC progress states
    /// From Ghostty: ConEmu progress report
    @Test func testOscProgressAllStates() {
        let delegate = ProgressDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        // Remove progress (state 0)
        terminal.feed(text: "\u{1b}]9;4;0\u{07}")
        #expect(delegate.reports.last?.state == .remove)

        // Set progress (state 1)
        terminal.feed(text: "\u{1b}]9;4;1;75\u{07}")
        #expect(delegate.reports.last?.state == .set)
        #expect(delegate.reports.last?.progress == 75)

        // Error state (state 2)
        terminal.feed(text: "\u{1b}]9;4;2\u{07}")
        #expect(delegate.reports.last?.state == .error)

        // Indeterminate (state 3)
        terminal.feed(text: "\u{1b}]9;4;3\u{07}")
        #expect(delegate.reports.last?.state == .indeterminate)

        // Pause (state 4)
        terminal.feed(text: "\u{1b}]9;4;4\u{07}")
        #expect(delegate.reports.last?.state == .pause)
    }

    /// Test empty OSC sequences are handled gracefully
    /// From Ghostty: edge case handling
    @Test func testOscEmpty() {
        let delegate = TitleDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        // Empty OSC - should not crash
        terminal.feed(text: "\u{1b}]\u{07}")

        // OSC with just number - should not crash
        terminal.feed(text: "\u{1b}]0\u{07}")
    }

    /// Test OSC sequences with very long strings
    /// From Ghostty: buffer overflow protection
    @Test func testOscLongString() {
        let delegate = TitleDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        // Very long title - should be handled without crash
        let longTitle = String(repeating: "a", count: 5000)
        terminal.feed(text: "\u{1b}]0;\(longTitle)\u{07}")

        // Either truncated or full, but no crash
        #expect(delegate.titles.last != nil)
    }

    @Test func testOscSemanticPromptLifecycleMarksCellsAndRows() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 8))

        terminal.feed(text: "\u{1b}]133;A\u{07}> ")
        #expect(terminal.semanticPromptKind(at: 0) == .initial)
        #expect(terminal.semanticContent(at: Position(col: 0, row: 0)) == .prompt(.initial))

        terminal.feed(text: "\u{1b}]133;B\u{07}echo")
        #expect(terminal.semanticContent(at: Position(col: 2, row: 0)) == .input)

        terminal.feed(text: "\u{1b}]133;C\u{07}output")
        #expect(terminal.semanticContent(at: Position(col: 6, row: 0)) == .output)

        terminal.feed(text: "\u{1b}]133;Ainvalid\u{07}")
        #expect(terminal.semanticContent(at: Position(col: 6, row: 0)) == .output)
    }

    @Test func testOscSemanticPromptClickEventsAndPolicy() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;click_events=1\u{07}>\u{1b}]133;B\u{07}hi")
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(String(bytes: delegate.sentData, encoding: .utf8) == "\u{1b}[<0;2;1M")

        terminal.semanticPromptClickBehavior = .disabled
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))

        terminal.semanticPromptClickBehavior = .requireModifier(.option)
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0), modifiers: .option))
    }

    /// Enabling support is inert until the application actually emits OSC 133.
    /// A terminal without semantic-prompt markup must keep its normal click path.
    @Test func testOscSemanticPromptClicksAreInertWithoutOsc133() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "plain terminal output")

        #expect(terminal.semanticPromptClickBehavior == .enabled)
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 2, row: 0)))
        #expect(delegate.sentData.isEmpty)
    }

    @Test func testOscSemanticPromptSpecialCursorKey() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;cl=line;special_key=1\u{07}>\u{1b}]133;B\u{07}hi")
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(String(bytes: delegate.sentData, encoding: .utf8) == "\u{1b}[2u\u{1b}[2u")
    }

    @Test func testOscSemanticPromptVariantsAndSoftWrap() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 3, rows: 5, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A\u{07}abcd")
        #expect(terminal.semanticPromptKind(at: 1) == .continuation)
        #expect(terminal.semanticContent(at: Position(col: 0, row: 1)) == .prompt(.initial))

        terminal.feed(text: "\u{1b}]133;B\u{07}x\u{1b}]133;I\u{07}\n")
        let outputRow = terminal.buffer.yBase + terminal.getCursorLocation().y
        let outputColumn = terminal.getCursorLocation().x
        terminal.feed(text: "o")
        #expect(terminal.semanticContent(at: Position(col: outputColumn, row: outputRow)) == .output)

        terminal.feed(text: "\u{1b}]133;P;k=s\u{07}")
        let secondaryRow = terminal.buffer.yBase + terminal.getCursorLocation().y
        #expect(terminal.semanticPromptKind(at: secondaryRow) == .secondary)
        terminal.feed(text: "\u{1b}]133;N\u{07}")
        let nextPromptRow = terminal.buffer.yBase + terminal.getCursorLocation().y
        #expect(terminal.semanticPromptKind(at: nextPromptRow) == .initial)
    }

    @Test func testOscSemanticPromptResizeRedrawPolicy() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        // Erasing the prompt for redraw is opt-in: a shell that never says it
        // repaints keeps its prompt and typed input across a resize.
        terminal.feed(text: "\u{1b}]133;A;redraw=1\u{07}>\u{1b}]133;B\u{07}input")
        terminal.resize(cols: 21, rows: 4)
        #expect(terminal.semanticContent(at: Position(col: 1, row: 0)) == .some(.none))

        terminal.feed(text: "\u{1b}]133;A;redraw=0\u{07}>\u{1b}]133;B\u{07}input")
        let row = terminal.getCursorLocation().y + terminal.buffer.yBase
        terminal.resize(cols: 22, rows: 4)
        #expect(terminal.semanticContent(at: Position(col: 1, row: row)) == .input)

        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}input")
        let bareRow = terminal.getCursorLocation().y + terminal.buffer.yBase
        terminal.resize(cols: 23, rows: 4)
        #expect(terminal.semanticContent(at: Position(col: 1, row: bareRow)) == .input)
    }

    /// The wrapped-row markers must land on the row the cells were written to,
    /// not on the same-numbered row inside the scrollback.
    @Test func testOscSemanticPromptSoftWrapMarksRowWithScrollback() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 4, rows: 3, scrollback: 20))

        // Push content into the scrollback so yBase > 0.
        terminal.feed(text: "one\r\ntwo\r\nsix\r\nten\r\n")
        #expect(terminal.buffer.yBase > 0)

        terminal.feed(text: "\u{1b}]133;A\u{07}abcdef")
        let promptRow = terminal.buffer.semanticPromptStartRow!
        #expect(terminal.semanticPromptKind(at: promptRow) == .initial)
        #expect(terminal.semanticPromptKind(at: promptRow + 1) == .continuation)
        // The rows below yBase are untouched scrollback.
        for row in 0..<promptRow {
            #expect(terminal.semanticPromptKind(at: row) == nil)
        }
    }

    /// The prompt erase runs against pre-resize geometry, so reflow can never
    /// redirect it onto unrelated scrollback rows.
    @Test func testOscSemanticPromptRedrawDoesNotEraseScrollback() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 3, scrollback: 40))

        for _ in 0..<10 {
            terminal.feed(text: "0123456789abcdef\r\n")
        }
        terminal.feed(text: "\u{1b}]133;A;redraw=1\u{07}>\u{1b}]133;B\u{07}cmd")
        terminal.resize(cols: 5, rows: 3)

        // Some row of the earlier output must survive the resize.
        let surviving = (0..<terminal.buffer.lines.count).contains { row in
            terminal.buffer.lines[row].translateToString(trimRight: true).contains("0123")
        }
        #expect(surviving)
    }
}
#endif
