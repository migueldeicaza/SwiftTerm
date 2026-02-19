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

    /// Test OSC 52 (clipboard) query
    /// From Ghostty: "clipboard_contents"
    @Test func testOscClipboardQuery() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Query clipboard (sends '?' as data)
        t.feed(text: "\u{1b}]52;c;?\u{07}")

        // Terminal should respond with clipboard contents or empty
        // Response verification depends on implementation
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

    /// Test OSC 133 (semantic prompts) - prompt start
    /// From Ghostty: "prompt_start", "prompt_end"
    @Test func testOscSemanticPromptStart() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let t = h.terminal!

        // Prompt start (A = fresh line + prompt start)
        t.feed(text: "\u{1b}]133;A\u{07}")
        // Prompt end / command start (B)
        t.feed(text: "$ ")
        t.feed(text: "\u{1b}]133;B\u{07}")

        // Command executed
        t.feed(text: "ls -la\n")

        // Command finished (C = output start)
        t.feed(text: "\u{1b}]133;C\u{07}")
        t.feed(text: "file1\nfile2\n")

        // Command complete with exit code (D)
        t.feed(text: "\u{1b}]133;D;0\u{07}")

        // Should process without crashing
    }
}
#endif
