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
    private func explicitLink(_ terminal: Terminal, row: Int, col: Int) -> String? {
        terminal.link(
            at: .buffer(Position(col: col, row: row)),
            mode: .explicitOnly
        )
    }

    private func payload(_ terminal: Terminal, row: Int, col: Int) -> String? {
        terminal.getCharData(col: col, row: row)?.getPayload() as? String
    }

    private func promptKinds(_ terminal: Terminal, at row: Int) -> [SemanticPromptKind] {
        terminal.semanticPromptMarks(at: row).map(\.kind)
    }

    private final class TitleDelegate: TerminalDelegate {
        private(set) var titles: [String] = []
        private(set) var iconTitles: [String] = []

        func setTerminalTitle(source: Terminal, title: String) {
            titles.append(title)
        }

        func setTerminalIconTitle(source: Terminal, title: String) {
            iconTitles.append(title)
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

    private final class ResponseDelegate: TerminalDelegate {
        private(set) var responses: [[UInt8]] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            responses.append(Array(data))
        }
    }

    @Test func testOscITerm2CapabilitiesReport() {
        let delegate = ResponseDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(featureReport: "T3CwUw17")
        )

        terminal.feed(text: "\u{1b}]1337;Capabilities\u{1b}\\")

        #expect(delegate.responses == [Array("\u{1b}]1337;Capabilities=T3CwUw17\u{1b}\\".utf8)])
    }

    @Test func testOscITerm2CapabilitiesReportIsOptInAndValidated() {
        let disabledDelegate = ResponseDelegate()
        let disabled = Terminal(delegate: disabledDelegate)
        disabled.feed(text: "\u{1b}]1337;Capabilities\u{07}")
        #expect(disabledDelegate.responses.isEmpty)

        let invalidDelegate = ResponseDelegate()
        let invalid = Terminal(
            delegate: invalidDelegate,
            options: TerminalOptions(featureReport: "T3;unsafe")
        )
        invalid.feed(text: "\u{1b}]1337;Capabilities\u{07}")
        #expect(invalidDelegate.responses.isEmpty)
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

    @Test func testIndividualTitleStacksRestoreMatchingTitles() {
        let delegate = TitleDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.feed(text: "\u{1b}]1;old-icon\u{1b}\\\u{1b}[22;1t")
        terminal.feed(text: "\u{1b}]2;old-window\u{1b}\\\u{1b}[22;2t")
        terminal.feed(text: "\u{1b}]1;new-icon\u{1b}\\\u{1b}]2;new-window\u{1b}\\")
        terminal.feed(text: "\u{1b}[23;1t\u{1b}[23;2t")

        #expect(delegate.iconTitles.last == "old-icon")
        #expect(delegate.titles.last == "old-window")
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

    @Test func testOscHyperlinkMarksOnlyPrintedCellsAcrossCursorJump() {
        let terminal = Terminal(
            delegate: TitleDelegate(),
            options: TerminalOptions(cols: 8, rows: 4, scrollback: 0)
        )
        let escape = "\u{1b}"
        let stringTerminator = "\(escape)\\"

        terminal.feed(text: "\(escape)[H")
        terminal.feed(text: "\(escape)]8;;https://example.com\(stringTerminator)")
        terminal.feed(text: "AB")

        #expect(explicitLink(terminal, row: 0, col: 0) == "https://example.com")
        #expect(explicitLink(terminal, row: 0, col: 1) == "https://example.com")

        terminal.feed(text: "\(escape)[3;1H")
        terminal.feed(text: "\(escape)]8;;\(stringTerminator)")

        for col in 2..<terminal.cols {
            #expect(explicitLink(terminal, row: 0, col: col) == nil)
        }
        for col in 0..<terminal.cols {
            #expect(explicitLink(terminal, row: 1, col: col) == nil)
        }
        #expect(explicitLink(terminal, row: 2, col: 0) == nil)

        terminal.feed(text: "C")
        #expect(explicitLink(terminal, row: 2, col: 0) == nil)
    }

    @Test func testOscHyperlinkMarksWideCharacterContinuationCell() {
        let terminal = Terminal(
            delegate: TitleDelegate(),
            options: TerminalOptions(cols: 4, rows: 2, scrollback: 0)
        )
        let escape = "\u{1b}"
        let stringTerminator = "\(escape)\\"

        terminal.feed(text: "\(escape)]8;;https://example.com\(stringTerminator)")
        terminal.feed(text: "界")
        terminal.feed(text: "\(escape)]8;;\(stringTerminator)")

        #expect(payload(terminal, row: 0, col: 0) == ";https://example.com")
        #expect(payload(terminal, row: 0, col: 1) == ";https://example.com")
        #expect(payload(terminal, row: 0, col: 2) == nil)
    }

    @Test func testOscPendingHyperlinkSurvivesPayloadCollection() {
        let terminal = Terminal(
            delegate: TitleDelegate(),
            options: TerminalOptions(cols: 4, rows: 2, scrollback: 0)
        )
        let escape = "\u{1b}"
        let stringTerminator = "\(escape)\\"

        terminal.feed(text: "\(escape)]8;;https://example.com\(stringTerminator)")
        terminal.garbageCollectPayload()
        terminal.feed(text: "A")
        terminal.feed(text: "\(escape)]8;;\(stringTerminator)")

        #expect(explicitLink(terminal, row: 0, col: 0) == "https://example.com")
    }

    @Test func testOscHyperlinkUsesLastPendingPayload() {
        let terminal = Terminal(
            delegate: TitleDelegate(),
            options: TerminalOptions(cols: 4, rows: 2, scrollback: 0)
        )
        let escape = "\u{1b}"
        let stringTerminator = "\(escape)\\"

        terminal.feed(text: "\(escape)]8;;https://first.example\(stringTerminator)")
        terminal.feed(text: "\(escape)]8;;https://second.example\(stringTerminator)")
        terminal.feed(text: "A")
        terminal.feed(text: "\(escape)]8;;\(stringTerminator)")

        #expect(explicitLink(terminal, row: 0, col: 0) == "https://second.example")
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
        private(set) var sendCount = 0

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sendCount += 1
            sentData.append(contentsOf: data)
        }

        func reset() {
            sentData.removeAll(keepingCapacity: true)
            sendCount = 0
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
        #expect(promptKinds(terminal, at: 0).contains(.initial))
        #expect(terminal.semanticContent(at: Position(col: 0, row: 0)) == .prompt(.initial))

        terminal.feed(text: "\u{1b}]133;B\u{07}echo")
        #expect(terminal.semanticContent(at: Position(col: 2, row: 0)) == .input)

        terminal.feed(text: "\u{1b}]133;C\u{07}output")
        #expect(terminal.semanticContent(at: Position(col: 6, row: 0)) == .output)

        let contentBeforeMalformedAction = terminal.buffer.semanticContent
        let promptStartBeforeMalformedAction = terminal.buffer.semanticPromptStartRow
        terminal.feed(text: "\u{1b}]133;Ainvalid\u{07}")
        #expect(terminal.buffer.semanticContent == contentBeforeMalformedAction)
        #expect(terminal.buffer.semanticPromptStartRow == promptStartBeforeMalformedAction)
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
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0),
                                                    modifiers: [.option, .shift]))

        terminal.semanticPromptClickBehavior = .enabled
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0), modifiers: .command))
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0), modifiers: .control))
    }

    @Test func testOscAbsoluteClickEventsIgnoreScrollPosition() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 20))
        for index in 0..<8 {
            terminal.feed(text: "line-\(index)\r\n")
        }
        terminal.feed(text: "\u{1b}[1;1H\u{1b}]133;A;click_events=1\u{07}>" +
                            "\u{1b}]133;B\u{07}x")
        let promptRow = terminal.buffer.semanticPromptStartRow!

        terminal.buffer.yDisp = terminal.buffer.yBase
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: promptRow)))
        let liveViewportResponse = delegate.sentData
        delegate.reset()

        terminal.buffer.yDisp = max(terminal.buffer.yBase - 2, 0)
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: promptRow)))

        #expect(delegate.sentData == liveViewportResponse)
        #expect(String(bytes: delegate.sentData, encoding: .utf8) ==
                "\u{1b}[<0;2;\(promptRow - terminal.buffer.yBase + 1)M")
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
        #expect(String(bytes: delegate.sentData, encoding: .utf8) == "\u{1b}[1;1u\u{1b}[1;1u")
    }

    @Test func testOscSemanticPromptClickAtCursorIsNotConsumed() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}hi")

        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 3, row: 0)))
        #expect(delegate.sentData.isEmpty)
    }

    @Test func testOscSemanticPromptClickRequiresCursorOnInputAtColumnZero() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}x\r\n")

        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(delegate.sentData.isEmpty)
    }

    @Test func testOscSemanticPromptClickRejectsBlankRowBelowInput() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;cl=m\u{07}>\u{1b}]133;B\u{07}abcd\u{1b}[2D")

        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 0, row: 1)))
        #expect(delegate.sentData.isEmpty)
    }

    @Test func testOscSemanticPromptClickPastInputEndMovesToEnd() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abcd\u{1b}[2D")

        #expect(terminal.handleSemanticPromptClick(at: Position(col: 10, row: 0)))
        #expect(String(bytes: delegate.sentData, encoding: .utf8) == "\u{1b}[C\u{1b}[C")
    }

    @Test func testOscSemanticPromptCursorMovementUsesOneSend() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}" + String(repeating: "x", count: 60))

        #expect(terminal.handleSemanticPromptClick(at: Position(col: 2, row: 0)))
        #expect(delegate.sendCount == 1)
        #expect(delegate.sentData.count == 59 * EscapeSequences.moveLeftNormal.count)
    }

    @Test func testOscSemanticPromptVerticalMovementExcludesTargetCell() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;cl=v\u{07}>\u{1b}]133;B\u{07}ab\r\n\u{1b}]133;B\u{07}cd")
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 2, row: 0)))

        #expect(String(bytes: delegate.sentData, encoding: .utf8) ==
                "\u{1b}[D\u{1b}[D\u{1b}[A\u{1b}[C")
    }

    @Test func testOscSemanticPromptWrappedInputDoesNotSendVerticalKeys() {
        for mode in ["v", "w"] {
            let delegate = SemanticDelegate()
            let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 4, rows: 4, scrollback: 0))

            terminal.feed(text: "\u{1b}]133;A;cl=\(mode)\u{07}>\u{1b}]133;B\u{07}abcdef")
            #expect(terminal.buffer.lines[1].isWrapped)
            #expect(terminal.handleSemanticPromptClick(at: Position(col: 2, row: 0)))

            let response = String(bytes: delegate.sentData, encoding: .utf8) ?? ""
            #expect(!response.contains("\u{1b}[A"))
            #expect(!response.contains("\u{1b}[B"))
            #expect(response == String(repeating: "\u{1b}[D", count: 5))
        }
    }

    @Test func testOscSemanticPromptWideCellTargetUsesLeadingCell() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}界x")
        #expect(terminal.semanticContent(at: Position(col: 2, row: 0)) == .input)
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 2, row: 0)))

        #expect(String(bytes: delegate.sentData, encoding: .utf8) == "\u{1b}[D\u{1b}[D")
    }

    @Test func testOscSemanticPromptSpecialKeysAvoidVerticalArrowKeys() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A;cl=v;special_key=1\u{07}>\u{1b}]133;B\u{07}ab\r\n\u{1b}]133;B\u{07}cd")
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 2, row: 0)))

        // The shell's edit buffer is "ab\ncd" and the special backward key
        // moves over the embedded newline like any character, so reaching
        // the position before 'b' from the end takes four steps.
        let response = String(bytes: delegate.sentData, encoding: .utf8) ?? ""
        #expect(!response.contains("\u{1b}[A"))
        #expect(!response.contains("\u{1b}[B"))
        #expect(response == String(repeating: "\u{1b}[1;1u", count: 4))
    }

    @Test func testOscSemanticPromptVariantsAndSoftWrap() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 3, rows: 5, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A\u{07}abcd")
        #expect(terminal.semanticRowKind(at: 0) == .initial)
        #expect(terminal.semanticRowKind(at: 1) == .continuation)
        #expect(promptKinds(terminal, at: 1).isEmpty)
        #expect(terminal.semanticContent(at: Position(col: 0, row: 1)) == .prompt(.initial))

        // R4: `I` arms exactly like `B`; a hard line feed does not end the
        // input region.
        terminal.feed(text: "\u{1b}]133;B\u{07}x\u{1b}]133;I\u{07}\n")
        let inputRow = terminal.buffer.yBase + terminal.getCursorLocation().y
        let inputColumn = terminal.getCursorLocation().x
        terminal.feed(text: "o")
        #expect(terminal.semanticContent(at: Position(col: inputColumn, row: inputRow)) == .input)

        terminal.feed(text: "\u{1b}]133;P;k=s\u{07}")
        let secondaryRow = terminal.buffer.yBase + terminal.getCursorLocation().y
        #expect(promptKinds(terminal, at: secondaryRow).contains(.secondary))
        terminal.feed(text: "\u{1b}]133;N\u{07}")
        let nextPromptRow = terminal.buffer.yBase + terminal.getCursorLocation().y
        #expect(terminal.semanticPromptMarks(at: nextPromptRow).contains { $0.kind == .initial })
    }

    @Test func testOscSecondaryPromptDoesNotMovePromptOrigin() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 8))

        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}first\r\n")
        let promptStart = terminal.buffer.semanticPromptStartRow
        terminal.feed(text: "\u{1b}]133;P;k=s\u{07}more")

        #expect(terminal.buffer.semanticPromptStartRow == promptStart)
        #expect(promptKinds(terminal, at: promptStart! + 1).contains(.secondary))
    }

    @Test func testOscLineFeedWithoutMovementKeepsInitialPromptMarker() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))

        terminal.feed(text: "\u{1b}[1;2r\u{1b}[3;1H\u{1b}]133;A\u{07}\n")

        #expect(promptKinds(terminal, at: 2).contains(.initial))
    }

    @Test func testOscIndexAndNextLineUseTheSharedSemanticLineAdvanceRule() {
        for sequence in ["\u{1b}D", "\u{1b}E"] {
            let promptTerminal = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
            promptTerminal.feed(text: "\u{1b}]133;A\u{07}>" + sequence)
            #expect(promptTerminal.semanticRowKind(at: 1) == .continuation)

            let inputTerminal = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
            inputTerminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}x" + sequence + "o")
            let row = inputTerminal.buffer.yBase + inputTerminal.getCursorLocation().y
            let column = max(inputTerminal.getCursorLocation().x - 1, 0)
            #expect(inputTerminal.semanticContent(at: Position(col: column, row: row)) == .input)
        }
    }

    @Test func testOscPersistentInputSurvivesHardLineFeeds() {
        let terminal = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd\r\noutput")

        #expect(terminal.buffer.semanticContent == .input)
        #expect(terminal.semanticContent(at: Position(col: 0, row: 1)) == .input)

        terminal.sendUserInput([0x0d][...])
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 1)))

        let fixedCursor = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        fixedCursor.feed(text: "\u{1b}[1;2r\u{1b}[3;1H\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd\noutput")
        #expect(fixedCursor.buffer.semanticContent == .input)
        #expect(fixedCursor.semanticContent(at: Position(col: 4, row: 2)) == .input)
    }

    @Test func testOscCommandStartAfterCarriageReturnKeepsPromptMarker() {
        let terminal = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd\r\u{1b}]133;C\u{07}")

        #expect(promptKinds(terminal, at: 0).contains(.initial))
    }

    @Test func testOscSemanticPromptActionsDAndL() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd\u{1b}]133;D;0\u{07}")
        #expect(terminal.buffer.semanticContent == .output)

        terminal.feed(text: "done")
        let rowBeforeL = terminal.getCursorLocation().y
        terminal.feed(text: "\u{1b}]133;L\u{07}")
        #expect(terminal.getCursorLocation().x == 0)
        #expect(terminal.getCursorLocation().y == rowBeforeL + 1)
        #expect(terminal.buffer.semanticContent == .output)
    }

    @Test func testOscSemanticPromptResizePreservesContent() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        // Resize only changes the buffer geometry. It does not erase prompt or
        // input cells, even if the shell advertises prompt redraw support.
        terminal.feed(text: "\u{1b}]133;A;redraw=1\u{07}>\u{1b}]133;B\u{07}input")
        terminal.resize(cols: 21, rows: 4)
        #expect(terminal.semanticContent(at: Position(col: 1, row: 0)) == .input)
        #expect(terminal.buffer.lines[0].translateToString(trimRight: true) == ">input")

        terminal.feed(text: "\u{1b}]133;A;redraw=0\u{07}>\u{1b}]133;B\u{07}input")
        let row = terminal.getCursorLocation().y + terminal.buffer.yBase
        terminal.resize(cols: 22, rows: 4)
        #expect(terminal.semanticContent(at: Position(col: 1, row: row)) == .input)

        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}input")
        let bareRow = terminal.getCursorLocation().y + terminal.buffer.yBase
        terminal.resize(cols: 23, rows: 4)
        #expect(terminal.semanticContent(at: Position(col: 1, row: bareRow)) == .input)
    }

    @Test func testOscSemanticPromptOriginTracksResizeAndHistoryTrim() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 3, scrollback: 30))

        for _ in 0..<6 {
            terminal.feed(text: "0123456789abcdef\r\n")
        }
        terminal.feed(text: "\u{1b}]133;A;click_events=2\u{07}>\u{1b}]133;B\u{07}cmd")
        let oldStart = terminal.buffer.semanticPromptStartRow!

        terminal.resize(cols: 5, rows: 3)
        let resizedStart = terminal.buffer.semanticPromptStartRow!
        #expect(resizedStart != oldStart)
        #expect(promptKinds(terminal, at: resizedStart).contains(.initial))

        terminal.changeHistorySize(2)
        let trimmedStart = terminal.buffer.semanticPromptStartRow!
        #expect(trimmedStart < resizedStart)
        #expect(promptKinds(terminal, at: trimmedStart).contains(.initial))
    }

    @Test func testOscSemanticPromptOriginTracksClearScrollback() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 3, scrollback: 30))

        for _ in 0..<6 {
            terminal.feed(text: "line\r\n")
        }
        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd")
        let oldStart = terminal.buffer.semanticPromptStartRow!
        let removedRows = terminal.buffer.yBase
        #expect(removedRows > 0)

        terminal.clearScrollback()
        let newStart = terminal.buffer.semanticPromptStartRow!
        #expect(newStart == oldStart - removedRows)
        #expect(promptKinds(terminal, at: newStart).contains(.initial))
    }

    @Test func testOscSemanticPromptOriginTracksIndexScrolls() {
        let forward = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 10, rows: 4, scrollback: 0))
        forward.feed(text: "\u{1b}[4;1H\u{1b}]133;A\u{07}>\u{1b}D")
        #expect(forward.buffer.semanticPromptStartRow == 2)
        #expect(promptKinds(forward, at: 2).contains(.initial))

        let reverse = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 10, rows: 4, scrollback: 0))
        reverse.feed(text: "\u{1b}]133;A\u{07}>\u{1b}M")
        #expect(reverse.buffer.semanticPromptStartRow == 1)
        #expect(promptKinds(reverse, at: 1).contains(.initial))

        let recycle = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 10, rows: 2, scrollback: 2))
        recycle.feed(text: "1\r\n2\r\n3\r\n\u{1b}]133;A\u{07}>")
        let rowBeforeScroll = recycle.buffer.semanticPromptStartRow
        recycle.feed(text: "\u{1b}D")
        #expect(rowBeforeScroll == 3)
        #expect(recycle.buffer.semanticPromptStartRow == 2)
        #expect(promptKinds(recycle, at: 2).contains(.initial))

        let splice = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 10, rows: 3, scrollback: 2))
        splice.feed(text: "1\r\n2\r\n3\r\n4\r\n\u{1b}[1;2r\u{1b}[2;1H\u{1b}]133;A\u{07}>")
        let rowBeforeSplice = splice.buffer.semanticPromptStartRow
        splice.feed(text: "\u{1b}D")
        #expect(splice.buffer.semanticPromptStartRow == rowBeforeSplice! - 1)
        #expect(promptKinds(splice, at: rowBeforeSplice! - 1).contains(.initial))
    }


    @Test func testOscSemanticPromptOriginTracksMarginScrolls() {
        func terminalWithPrompt(row: Int) -> Terminal {
            let terminal = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 6, rows: 4, scrollback: 0))
            terminal.feed(text: "\u{1b}[?69h\u{1b}[2;5s\u{1b}[\(row + 1);2H\u{1b}]133;A\u{07}>")
            return terminal
        }

        let index = terminalWithPrompt(row: 3)
        index.feed(text: "\u{1b}D")
        #expect(index.buffer.semanticPromptStartRow == 2)
        #expect(promptKinds(index, at: 2).contains(.initial))

        let reverseIndex = terminalWithPrompt(row: 0)
        reverseIndex.feed(text: "\u{1b}M")
        #expect(reverseIndex.buffer.semanticPromptStartRow == 1)
        #expect(promptKinds(reverseIndex, at: 1).contains(.initial))

        let scrollUp = terminalWithPrompt(row: 2)
        scrollUp.feed(text: "\u{1b}[1S")
        #expect(scrollUp.buffer.semanticPromptStartRow == 1)
        #expect(promptKinds(scrollUp, at: 1).contains(.initial))

        let scrollDown = terminalWithPrompt(row: 1)
        scrollDown.feed(text: "\u{1b}[1T")
        #expect(scrollDown.buffer.semanticPromptStartRow == 2)
        #expect(promptKinds(scrollDown, at: 2).contains(.initial))

        let insertLine = terminalWithPrompt(row: 2)
        insertLine.feed(text: "\u{1b}[2;2H\u{1b}[1L")
        #expect(insertLine.buffer.semanticPromptStartRow == 3)
        #expect(promptKinds(insertLine, at: 3).contains(.initial))

        let deleteLine = terminalWithPrompt(row: 2)
        deleteLine.feed(text: "\u{1b}[2;2H\u{1b}[1M")
        #expect(deleteLine.buffer.semanticPromptStartRow == 1)
        #expect(promptKinds(deleteLine, at: 1).contains(.initial))
    }

    @Test func testOscEraseEntireLinePreservesPromptMarkerForRedisplay() {
        let terminal = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}[2K")

        #expect(promptKinds(terminal, at: 0) == [.initial])

        // Cell-content mutations never touch marks (R2): a full-line fill
        // erases the cells, not the line-level metadata.
        let filledTerminal = Terminal(delegate: SemanticDelegate(), options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        filledTerminal.feed(text: "\u{1b}]133;A\u{07}>")
        filledTerminal.buffer.lines[0].fill(with: CharData.Null)
        #expect(promptKinds(filledTerminal, at: 0) == [.initial])
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
        #expect(promptKinds(terminal, at: promptRow).contains(.initial))
        #expect(terminal.semanticRowKind(at: promptRow + 1) == .continuation)
        #expect(promptKinds(terminal, at: promptRow + 1).isEmpty)
        // The rows below yBase are untouched scrollback.
        for row in 0..<promptRow {
            #expect(promptKinds(terminal, at: row).isEmpty)
            #expect(terminal.semanticRowKind(at: row) == nil)
        }
    }

    /// Resize must preserve the active prompt when scrollback is present.
    @Test func testOscSemanticPromptResizePreservesActivePromptWithScrollback() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 3, scrollback: 40))

        for _ in 0..<10 {
            terminal.feed(text: "0123456789abcdef\r\n")
        }
        terminal.feed(text: "\u{1b}]133;A;redraw=1\u{07}>\u{1b}]133;B\u{07}Z9Q")
        terminal.resize(cols: 5, rows: 3)

        let promptSurvived = (0..<terminal.buffer.lines.count).contains { row in
            terminal.buffer.lines[row].translateToString(trimRight: true).contains(">Z9Q")
        }
        #expect(promptSurvived)
        let origin = terminal.activeSemanticPromptOrigin
        #expect(origin != nil)
        #expect(origin.map { terminal.semanticPromptMarks(at: $0.row).contains {
            $0.position == origin && $0.kind == .initial
        }} == true)
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    /// R4: `B` and `I` both arm the input region, and no output-side
    /// heuristic ends it: multi-row editors redraw without re-emitting `B`.
    @Test func testOscSimpleInputStaysArmedAcrossHardLineFeeds() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))

        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;I\u{07}first\r\nsecond")

        #expect(terminal.buffer.semanticContent == .input)
        #expect(terminal.buffer.semanticInput == .armed)
        #expect(terminal.semanticContent(at: Position(col: 0, row: 1)) == .input)
        #expect(terminal.semanticRowKind(at: 1) == .continuation)
    }

    @Test func testOscSubmissionSuspendsClicksWithoutChangingCellRoles() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abcd\u{1b}[2D")

        terminal.sendUserInput([0x0d][...])

        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(delegate.sentData == [0x0d])
        #expect(terminal.semanticContent(at: Position(col: 1, row: 0)) == .input)

        terminal.feed(text: "\u{1b}]133;B\u{07}")
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
    }

    @Test func testOscLineClickAcceptsSoftWrappedRows() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 4, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abcdef")

        #expect(terminal.buffer.lines[1].isWrapped)
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        let response = String(bytes: delegate.sentData, encoding: .utf8) ?? ""
        #expect(!response.contains("\u{1b}[A"))
        #expect(!response.contains("\u{1b}[B"))
    }

    @Test func testOscClickEventsRejectBlankAndOutOfRangeRows() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;click_events=1\u{07}>\u{1b}]133;B\u{07}abc")

        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 1)))
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 99)))
        #expect(delegate.sentData.isEmpty)
    }

    @Test func testOscRelativeClickEventsUsePrimaryAndSecondaryPromptRows() {
        let primaryDelegate = SemanticDelegate()
        let primary = Terminal(delegate: primaryDelegate,
                               options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        primary.feed(text: "\u{1b}]133;A;click_events=2\u{07}>\u{1b}]133;B\u{07}abc")
        #expect(primary.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(String(bytes: primaryDelegate.sentData, encoding: .utf8) == "\u{1b}[<0;2;0M")

        let secondaryDelegate = SemanticDelegate()
        let secondary = Terminal(delegate: secondaryDelegate,
                                 options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        secondary.feed(text: "\u{1b}]133;A;click_events=2\u{07}>\u{1b}]133;B\u{07}one\r\n" +
                             "\u{1b}]133;P;k=s\u{07}>>\u{1b}]133;B\u{07}two")
        #expect(secondary.handleSemanticPromptClick(at: Position(col: 2, row: 1)))
        #expect(String(bytes: secondaryDelegate.sentData, encoding: .utf8) == "\u{1b}[<0;3;0M")
    }

    @Test func testOscPromptAnchorsCoexistAndFollowCellEdits() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A\u{07}>abc\u{1b}]133;P;k=r\u{07}")

        #expect(terminal.semanticPromptMarks(at: 0) == [
            SemanticPromptAnchor(position: Position(col: 0, row: 0), kind: .initial),
            SemanticPromptAnchor(position: Position(col: 4, row: 0), kind: .right)
        ])
        #expect(terminal.activeSemanticPromptOrigin == Position(col: 0, row: 0))

        terminal.feed(text: "\u{1b}[2G\u{1b}[2@")
        #expect(terminal.semanticPromptMarks(at: 0).map(\.position.col) == [0, 6])

        terminal.feed(text: "\u{1b}[2P")
        #expect(terminal.semanticPromptMarks(at: 0).map(\.position.col) == [0, 4])

        terminal.feed(text: "\u{1b}[5G\u{1b}[1X")
        #expect(terminal.semanticPromptMarks(at: 0) == [
            SemanticPromptAnchor(position: Position(col: 0, row: 0), kind: .initial),
            SemanticPromptAnchor(position: Position(col: 4, row: 0), kind: .right)
        ])
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    @Test func testOscNarrowMarginScrollLeavesOutsideAnchorInPlace() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 8, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}[3;1H\u{1b}]133;A\u{07}>" +
                            "\u{1b}[?69h\u{1b}[5;7s\u{1b}[4;5H\u{1b}D")

        #expect(terminal.activeSemanticPromptOrigin == Position(col: 0, row: 2))
        #expect(terminal.semanticPromptMarks(at: 2).contains { $0.kind == .initial })
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    // A same-kind collision during a margin scroll is resolved by liveness.
    // Here `P;k=i` on a different line allocates a live group (R2: `P;k=i`
    // reuses only on the origin line, else allocates), and the scroll-up moves
    // that live origin onto row 0, displacing the dead first-`A` mark; exactly
    // one initial mark remains and the invariants hold.
    @Test func testOscMarginCopyResolvesSameKindCollisionByLiveness() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 8, rows: 3, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A\u{07}>" +
                            "\u{1b}[2;6H\u{1b}]133;P;k=i\u{07}" +
                            "\u{1b}[?69h\u{1b}[5;8s\u{1b}[1S")

        #expect(terminal.semanticPromptMarks(at: 0).filter { $0.kind == .initial }.count == 1)
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    @Test func testOscOriginRebindUsesMostRecentGroupAtCursor() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 10, rows: 24, scrollback: 0))
        terminal.feed(text: "\u{1b}[20;1H\u{1b}]133;A\u{07}>" +
                            "\u{1b}[?69h\u{1b}[5;8s" +
                            "\u{1b}[21;5H\u{1b}]133;A;click_events=2\u{07}>" +
                            "\u{1b}]133;B\u{07}x" +
                            "\u{1b}[21;24r\u{1b}[23;5H\u{1b}[2T")

        #expect(terminal.buffer.semanticPromptStartRow == 22)
        #expect(terminal.activeSemanticPromptOrigin == Position(col: 4, row: 22))
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 5, row: 22)))
        #expect(String(bytes: delegate.sentData, encoding: .utf8) == "\u{1b}[<0;6;0M")
    }

    @Test func testOscSteadyScrollDoesNotScanPromptRows() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 3, scrollback: 100))
        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}command")
        _ = terminal.activeSemanticPromptOrigin
        let scansBeforeOutput = terminal.buffer.semanticPromptRowScanCount

        for index in 0..<500 {
            terminal.feed(text: "\r\nline-\(index)")
        }

        #expect(terminal.buffer.semanticPromptRowScanCount == scansBeforeOutput)
        _ = terminal.activeSemanticPromptOrigin
        #expect(terminal.buffer.semanticPromptRowScanCount == scansBeforeOutput + 1)
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    @Test func testOscResizeClampsEveryAnchorToAValidCell() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 10, rows: 3, scrollback: 20))
        terminal.feed(text: "\u{1b}]133;A\u{07}>1234567\u{1b}]133;P;k=r\u{07}")
        #expect(terminal.semanticPromptMarks(at: 0).contains { $0.position.col == 8 })

        terminal.resize(cols: 5, rows: 3)

        for row in 0..<terminal.buffer.lines.count {
            for anchor in terminal.semanticPromptMarks(at: row) {
                #expect(anchor.position.col >= 0)
                #expect(anchor.position.col < terminal.buffer.lines[row].count)
                _ = terminal.buffer.lines[row].getWidth(index: anchor.position.col)
            }
        }
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    @Test func testOscWiderReflowDoesNotPlantContinuationMidLine() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 5, rows: 4, scrollback: 20))
        terminal.feed(text: "\u{1b}]133;A\u{07}abcdef\r\n\u{1b}]133;C\u{07}output")
        #expect(terminal.semanticRowKind(at: 1) == .continuation)
        #expect(terminal.semanticRowKind(at: 2) == nil)

        terminal.resize(cols: 10, rows: 4)

        let anchors = (0..<terminal.buffer.lines.count).flatMap {
            terminal.semanticPromptMarks(at: $0)
        }
        #expect(anchors.filter { $0.kind == .initial }.count == 1)
        #expect(anchors.allSatisfy { $0.kind != .continuation })
        // A widened output row reports no kind (acceptance 4).
        for row in 0..<terminal.buffer.lines.count
        where terminal.buffer.lines[row].translateToString(trimRight: true).contains("output") {
            #expect(terminal.semanticRowKind(at: row) == nil)
        }
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    @Test func testOscCommandEndClearsEchoedEnterContinuation() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}input\r\n" +
                            "\u{1b}]133;C\u{07}output")

        #expect(terminal.semanticContent(at: Position(col: 0, row: 1)) == .output)
        #expect(terminal.semanticRowKind(at: 1) == nil)
        // The echoed-Enter row was stamped while armed; the C/D backstop
        // clears the cursor row's epoch.
        #expect(terminal.buffer.lines[1].semanticHardContinuationGroup == nil)
    }

    /// The epoch is structural, not content: a whole-row erase (ED 2) does
    /// NOT clear it (that was the superseded rule). Group isolation (no old
    /// row chains a new group) is verified separately in
    /// `testOscAcceptanceGroupIsolation`.
    @Test func testOscWholeRowEraseKeepsEpoch() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 8, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=m\u{07}>\u{1b}]133;B\u{07}old\r\nline")
        #expect(terminal.buffer.lines[1].semanticHardContinuationGroup != nil)

        terminal.feed(text: "\u{1b}[2J\u{1b}[H")
        #expect(terminal.buffer.lines[1].semanticHardContinuationGroup != nil)
    }

    @Test func testOscFullWidthMarginScrollMovesHardContinuation() {
        func scrolledTerminal(withMargins: Bool) -> (Terminal, SemanticDelegate) {
            let delegate = SemanticDelegate()
            let terminal = Terminal(delegate: delegate,
                                    options: TerminalOptions(cols: 8, rows: 4, scrollback: 0))
            terminal.feed(text: "\u{1b}[2;1H\u{1b}]133;A;cl=m\u{07}>" +
                                "\u{1b}]133;B\u{07}ab\r\ncd")
            if withMargins {
                terminal.feed(text: "\u{1b}[?69h\u{1b}[1;8s")
            }
            terminal.feed(text: "\u{1b}[1S\u{1b}[2;3H")
            return (terminal, delegate)
        }

        let (plain, plainDelegate) = scrolledTerminal(withMargins: false)
        let (margined, marginedDelegate) = scrolledTerminal(withMargins: true)

        #expect(plain.semanticRowKind(at: 1) == .continuation)
        #expect(margined.semanticRowKind(at: 1) == .continuation)
        #expect(plain.handleSemanticPromptClick(at: Position(col: 0, row: 1)))
        #expect(margined.handleSemanticPromptClick(at: Position(col: 0, row: 1)))
        #expect(marginedDelegate.sentData == plainDelegate.sentData)
    }

    @Test func testOscNarrowMarginScrollLeavesHardContinuationAndRejectsClick() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 8, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}[?69h\u{1b}[3;6s" +
                            "\u{1b}[2;3H\u{1b}]133;A;cl=m\u{07}>" +
                            "\u{1b}]133;B\u{07}a\r\nb" +
                            "\u{1b}[1S\u{1b}[2;4H")

        // A narrow-margin copy leaves the epoch in place (the conservative
        // choice); the sheared group yields dead clicks, never injection.
        #expect(terminal.buffer.lines[2].semanticHardContinuationGroup != nil)
        #expect(terminal.semanticRowKind(at: 1) == nil)
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 2, row: 1)))
        #expect(delegate.sentData.isEmpty)
    }

    @Test func testOscScrollDerivesContinuationWithoutStoredMarks() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 8, rows: 2, scrollback: 0))
        terminal.feed(text: "\u{1b}[2;1H\u{1b}]133;A\u{07}>\n")

        let promptRow = terminal.buffer.semanticPromptStartRow!
        #expect(terminal.semanticRowKind(at: promptRow) == .initial)
        #expect(terminal.semanticRowKind(at: promptRow + 1) == .continuation)
        #expect(terminal.semanticPromptMarks(at: promptRow + 1).isEmpty)
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    /// R4: newlines inside an `ESC[200~`/`ESC[201~` bracketed-paste region
    /// are literal text and leave the buffer armed — even when the paste is
    /// split across sendUserInput calls — while a kitty CSI-u Enter press
    /// and a bare CR are submissions.
    @Test func testOscUserInputPasteStaysArmedAndEnterSubmits() {
        let pasteDelegate = SemanticDelegate()
        let pasted = Terminal(delegate: pasteDelegate,
                              options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        pasted.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
        let paste = [UInt8]("\u{1b}[200~command\n\u{1b}[201~".utf8)

        pasted.sendUserInput(paste[...])

        #expect(pasteDelegate.sentData == paste)
        #expect(pasted.buffer.semanticInput == .armed)
        pasteDelegate.reset()
        #expect(pasted.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(!pasteDelegate.sentData.isEmpty)

        let split = Terminal(delegate: SemanticDelegate(),
                             options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        split.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
        split.sendUserInput([UInt8]("\u{1b}[200~part1\n".utf8)[...])
        #expect(split.buffer.semanticInput == .armed)
        split.sendUserInput([UInt8]("part2\n\u{1b}[201~".utf8)[...])
        #expect(split.buffer.semanticInput == .armed)
        split.sendUserInput([UInt8]("\r".utf8)[...])
        #expect(split.buffer.semanticInput == .submitted)

        let kittyDelegate = SemanticDelegate()
        let kitty = Terminal(delegate: kittyDelegate,
                             options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        kitty.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
        let submission = [UInt8]("\u{1b}[13u".utf8)

        kitty.sendUserInput(submission[...])

        #expect(kittyDelegate.sentData == submission)
        #expect(!kitty.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
    }

    @Test func testOscSplitPasteEndThenEnterSubmits() {
        let pasteEnd = [UInt8]("\u{1b}[201~".utf8)
        for splitOffset in 1..<pasteEnd.count {
            let terminal = Terminal(delegate: SemanticDelegate(),
                                    options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
            terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
            terminal.sendUserInput([UInt8]("\u{1b}[200~text\n".utf8)[...])
            terminal.sendUserInput(pasteEnd[..<splitOffset])
            terminal.sendUserInput(pasteEnd[splitOffset...])
            #expect(terminal.buffer.semanticInput == .armed)

            terminal.sendUserInput([0x0d][...])

            #expect(terminal.buffer.semanticInput == .submitted)
        }
    }

    @Test func testOscSplitPasteStartKeepsNewlineLiteral() {
        let pasteStart = [UInt8]("\u{1b}[200~".utf8)
        for splitOffset in 1..<pasteStart.count {
            let terminal = Terminal(delegate: SemanticDelegate(),
                                    options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
            terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
            terminal.sendUserInput(pasteStart[..<splitOffset])
            terminal.sendUserInput(pasteStart[splitOffset...])
            terminal.sendUserInput([0x0a][...])

            #expect(terminal.buffer.semanticInput == .armed)
        }
    }

    /// Acceptance 1: thirty repeated `CR EL A "> " B` repaints leave exactly
    /// one mark on the row — re-marking replaces, it does not append.
    @Test func testOscRepeatedRedisplayLeavesOneMark() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        for _ in 0..<30 {
            terminal.feed(text: "\r\u{1b}[2K\u{1b}]133;A\u{07}> \u{1b}]133;B\u{07}")
        }
        #expect(promptKinds(terminal, at: 0) == [.initial])
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    /// Acceptance 2: DCH at the prompt column, then a click, still moves
    /// the cursor — cell mutations never destroy marks.
    @Test func testOscDeleteCharsAtPromptColumnKeepsClickRouting() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}hi")

        terminal.feed(text: "\u{1b}[1;1H\u{1b}[1P")

        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(!delegate.sentData.isEmpty)
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    /// Acceptance 5: cols-width input with a pending wrap: the cursor offset
    /// is unclamped, so a click on the first cell emits `cols` movements and
    /// a click on the last cell emits one.
    @Test func testOscPendingWrapUsesUnclampedCursorOffset() {
        let width = 10
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: width, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}\u{1b}]133;B\u{07}" +
                            String(repeating: "x", count: width))
        #expect(terminal.buffer.x == width)

        #expect(terminal.handleSemanticPromptClick(at: Position(col: 0, row: 0)))
        #expect(delegate.sentData.count == width * EscapeSequences.moveLeftNormal.count)

        delegate.reset()
        #expect(terminal.handleSemanticPromptClick(at: Position(col: width - 1, row: 0)))
        #expect(delegate.sentData.count == EscapeSequences.moveLeftNormal.count)
    }

    /// Acceptance 6: an alternate-screen visit ends the input region on both
    /// buffers, tags no new cells as input, and only `B` re-arms.
    @Test func testOscAlternateScreenSubmitsBothBuffers() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")

        terminal.feed(text: "\u{1b}[?1049h")
        #expect(terminal.buffer.semanticInput == .submitted)
        let altRow = terminal.buffer.yBase + terminal.getCursorLocation().y
        let altColumn = terminal.getCursorLocation().x
        terminal.feed(text: "full screen")
        #expect(terminal.semanticContent(at: Position(col: altColumn, row: altRow)) != .input)

        terminal.feed(text: "\u{1b}[?1049l")
        #expect(terminal.buffer.semanticInput == .submitted)
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))

        terminal.feed(text: "\u{1b}]133;B\u{07}")
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
    }

    @Test func testOscSecondaryAKeepsPrimaryOriginAndClickRange() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=v\u{07}>\u{1b}]133;B\u{07}one\r\n" +
                            "\u{1b}]133;A;k=s\u{07}>>\u{1b}]133;B\u{07}two")

        #expect(terminal.activeSemanticPromptOrigin == Position(col: 0, row: 0))
        #expect(promptKinds(terminal, at: 1).contains(.secondary))
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
    }

    @Test func testOscRightPromptAStaysOnCurrentRow() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A\u{07}>abc\u{1b}]133;A;k=r\u{07}RIGHT")

        #expect(terminal.activeSemanticPromptOrigin == Position(col: 0, row: 0))
        #expect(promptKinds(terminal, at: 0) == [.initial, .right])
        #expect(promptKinds(terminal, at: 1).isEmpty)
    }

    @Test func testOscMultipleTraversalCountsEmbeddedNewline() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=m\u{07}>\u{1b}]133;B\u{07}ab\r\ncd")

        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 0)))
        #expect(String(bytes: delegate.sentData, encoding: .utf8) ==
                String(repeating: "\u{1b}[D", count: 5))
    }

    @Test func testOscRowMutationsMaintainAnchorInvariants() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 12, rows: 4, scrollback: 20))
        terminal.feed(text: "\u{1b}]133;A\u{07}>abc\u{1b}]133;P;k=r\u{07}")
        #expect(terminal.buffer.semanticPromptInvariantsHold())

        for sequence in ["\u{1b}[2G\u{1b}[2@", "\u{1b}[2P", "\r\u{1b}[2K",
                         "\u{1b}[4;1H\n", "\u{1b}[1S", "\u{1b}[1T"] {
            terminal.feed(text: sequence)
            #expect(terminal.buffer.semanticPromptInvariantsHold())
        }
        for width in [6, 18, 5, 12] {
            terminal.resize(cols: width, rows: 4)
            #expect(terminal.buffer.semanticPromptInvariantsHold())
        }
    }

    // A truncated CSI whose terminator is the ESC of the following sequence
    // must not swallow that ESC: the incremental scanner abandons the
    // truncated CSI on ESC, so the trailing `ESC[201~` still closes the paste
    // and a later bare CR submits. The pre-fix scanner consumed the ESC as
    // the CSI final byte and stuck the buffer armed until reset.
    @Test func testOscTruncatedCsiBeforePasteEndDoesNotStickArmed() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
        terminal.sendUserInput([UInt8]("\u{1b}[200~text".utf8)[...])
        // Truncated CSI (no final byte) immediately followed by the paste end.
        terminal.sendUserInput([UInt8]("\u{1b}[12;34\u{1b}[201~".utf8)[...])
        #expect(terminal.buffer.semanticInput == .armed)

        terminal.sendUserInput([0x0d][...])
        #expect(terminal.buffer.semanticInput == .submitted)
    }

    // The same swallow, but split across two calls: the truncated CSI ends
    // one buffer and the paste-end starts the next.
    @Test func testOscTruncatedCsiSplitAcrossCallsDoesNotStickArmed() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
        terminal.sendUserInput([UInt8]("\u{1b}[200~text\u{1b}[12;34".utf8)[...])
        terminal.sendUserInput([UInt8]("\u{1b}[201~".utf8)[...])
        terminal.sendUserInput([0x0d][...])
        #expect(terminal.buffer.semanticInput == .submitted)
    }

    // The keypad Enter under DECKPAM is `ESC O M` with no raw CR byte; it is
    // a submission on the safe side of R4's asymmetry.
    @Test func testOscKeypadEnterSubmits() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
        terminal.sendUserInput([UInt8]("\u{1b}OM".utf8)[...])
        #expect(terminal.buffer.semanticInput == .submitted)
    }

    // A same-kind collision during a margin scroll is resolved by liveness,
    // not position: when the live origin's mark is the one that moves onto a
    // line holding a stale same-kind mark, the origin wins. Here the origin
    // (from `A`, inside the margin at column 2) scrolls up onto row 0, which
    // carries a stale `P`-authored initial at column 0 (outside the margin).
    // The origin must survive at column 2; keeping the stationary mark would
    // route clicks from the dead prompt.
    @Test func testOscMarginScrollKeepsMovedLiveOrigin() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 8, rows: 3, scrollback: 0))
        terminal.feed(text: "\u{1b}[1;1H\u{1b}]133;P;k=i\u{07}" +   // stale initial @ (0,0)
                            "\u{1b}[?69h\u{1b}[3;8s" +               // DECLRMM margins cols 3..8
                            "\u{1b}[2;3H\u{1b}]133;A\u{07}" +        // live origin @ (2,1)
                            "\u{1b}]133;B\u{07}x" +
                            "\u{1b}[1S")                             // scroll region up by one

        #expect(terminal.activeSemanticPromptOrigin == Position(col: 2, row: 0))
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    // A.2: in the real pty ordering the user's submission (registerUserInput
    // CR) precedes the shell's echoed CRLFs and any PS0/DEBUG-trap output, so
    // those rows land in the `.submitted` state and are never stamped. No row
    // after the input derives as a continuation, and a `cl=m` click on the
    // input lands exactly.
    @Test func testOscArmedGatingSkipsEchoedAndPreCommandRows() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 5, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}ab")

        // The user submits; state flips to submitted before the echo arrives.
        terminal.sendUserInput([0x0d][...])
        // Echoed CRLF, a PS0-style trap line, another newline, then C.
        terminal.feed(text: "\r\ntrap-output\r\n\u{1b}]133;C\u{07}result")

        for row in 1..<terminal.buffer.lines.count {
            #expect(terminal.semanticRowKind(at: row) == nil)
            #expect(terminal.buffer.lines[row].semanticHardContinuationGroup == nil)
        }
    }

    // A deferred pointer click captures the clicked line's identity, not its
    // absolute row: after scrollback trims rows during the coalescing delay,
    // the row is re-resolved from the line so it still points at the same
    // content. Identity alone is insufficient: a recycled line object is
    // reused for the next prompt, so the captured generation must match too.
    @Test func testOscDeferredClickResolvesLineIdentityWhenNotRecycled() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 10, rows: 3, scrollback: 8))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}cmd")
        let capturedRow = terminal.buffer.semanticPromptStartRow!
        let capturedLine = terminal.bufferLine(atRow: capturedRow)!
        let capturedGen = capturedLine.recycleGeneration

        // Push the line into scrollback without overflowing it (no recycle);
        // its generation is unchanged, so it re-resolves to its current row.
        for index in 0..<4 { terminal.feed(text: "\r\nline-\(index)") }
        #expect(capturedLine.recycleGeneration == capturedGen)

        let resolved = terminal.semanticRow(forLineIdentity: capturedLine,
                                            recycleGeneration: capturedGen)
        #expect(resolved != nil)
        if let resolved {
            #expect(terminal.buffer.lines[resolved] === capturedLine)
        }
        _ = capturedRow
    }

    // B.2: when the captured line object is recycled (reused as a new row),
    // the generation moves on and the deferred click is dropped, even though
    // the object is still present in the array and identity would match.
    @Test func testOscDeferredClickDropsRecycledLine() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 10, rows: 3, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}cmd")
        let capturedLine = terminal.bufferLine(atRow: terminal.buffer.semanticPromptStartRow!)!
        let capturedGen = capturedLine.recycleGeneration
        #expect(terminal.semanticRow(forLineIdentity: capturedLine,
                                     recycleGeneration: capturedGen) != nil)

        // Overflow the buffer so the captured object is recycled.
        for index in 0..<10 { terminal.feed(text: "\r\nline-\(index)") }

        #expect(capturedLine.recycleGeneration != capturedGen)
        #expect(terminal.semanticRow(forLineIdentity: capturedLine,
                                     recycleGeneration: capturedGen) == nil)
    }

    // E.3: `HeadlessTerminal.send` runs the submission heuristic (marshaled
    // onto the effective queue), so a host forwarding clicks cannot inject
    // into a running program. Driving the real `send` and asserting the
    // post-drain submitted state — red when the registration hop is deleted.
    @Test func testHeadlessSendRunsSubmissionHeuristic() {
        let queue = DispatchQueue(label: "test.osc133.headless")
        let headless = HeadlessTerminal(queue: queue) { _ in }
        let terminal = headless.terminal!
        terminal.terminalLock.withLock {
            terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd")
        }
        #expect(terminal.terminalLock.withLock { terminal.buffer.semanticInput } == .armed)

        headless.send(data: [0x0d][...])
        queue.sync { }   // drain the registration

        #expect(terminal.terminalLock.withLock { terminal.buffer.semanticInput } == .submitted)
    }

    // B.4 exit criterion: the headless `send` marshals `registerUserInput`
    // onto the process serial queue, where `feed` also runs, so all terminal
    // state mutation is serialized even when `send` is called from arbitrary
    // threads. This reproduces that pattern for the thread sanitizer.
    // F.3: the E.3 fix is the nil-queue fallback. Constructed with the default
    // init, `send` must reach the submission heuristic on the same private
    // serial queue that LocalProcess uses for queued process output. Deleting
    // the hop leaves the buffer armed → this goes red.
    @Test func testHeadlessNilQueueSendRunsSubmissionHeuristic() {
        let headless = HeadlessTerminal { _ in }
        let terminal = headless.terminal!
        terminal.terminalLock.withLock {
            terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd")
        }
        #expect(terminal.terminalLock.withLock { terminal.buffer.semanticInput } == .armed)

        headless.send(data: [0x0d][...])
        headless.deliveryQueue.sync { }
        #expect(terminal.terminalLock.withLock { terminal.buffer.semanticInput } == .submitted)
    }

    // F.3: the TSan stress drives the real `HeadlessTerminal.send` (marshaling
    // registration onto the process queue) racing the feed path on that queue,
    // and asserts the invariants survive — no vacuous `#expect(true)`.
    @Test func testHeadlessConcurrentSendFeedIsSerialized() {
        let queue = DispatchQueue(label: "test.osc133.headless.stress")
        let headless = HeadlessTerminal(queue: queue) { _ in }
        let terminal = headless.terminal!
        let inputAccess = HeadlessInputTestAccess(headless)
        let terminalAccess = LockedTerminalTestAccess(terminal)
        let group = DispatchGroup()
        for i in 0..<300 {
            group.enter()
            DispatchQueue.global().async {
                inputAccess.send([0x0d][...])   // marshals onto `queue`
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                queue.async {
                    terminalAccess.withLock { terminal in
                        terminal.feed(
                            text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd-\(i)\r\n")
                    }
                }
                group.leave()
            }
        }
        group.wait()
        queue.sync { }   // drain
        #expect(terminal.terminalLock.withLock { terminal.buffer.semanticPromptInvariantsHold() })
    }

    // F exit criterion: the invariant checker passes on every healthy flow
    // probed this session.
    @Test func testOscInvariantsHoldOnHealthyFlows() {
        func fresh() -> Terminal {
            Terminal(delegate: SemanticDelegate(),
                     options: TerminalOptions(cols: 20, rows: 6, scrollback: 8))
        }
        // plain single-line command
        let plain = fresh()
        plain.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}ls\u{1b}]133;C\u{07}out")
        #expect(plain.buffer.semanticPromptInvariantsHold())

        // multi-line input (hard continuation)
        let multi = fresh()
        multi.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}one\r\ntwo\u{1b}]133;C\u{07}out")
        #expect(multi.buffer.semanticPromptInvariantsHold())

        // right prompt (RPROMPT)
        let rprompt = fresh()
        rprompt.feed(text: "\u{1b}]133;A\u{07}>abc\u{1b}]133;A;k=r\u{07}RP\u{1b}]133;B\u{07}x")
        #expect(rprompt.buffer.semanticPromptInvariantsHold())

        // repaint (reuse) then post-C
        let repaint = fresh()
        repaint.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd")
        repaint.feed(text: "\r\u{1b}[2K\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd\u{1b}]133;C\u{07}out")
        #expect(repaint.buffer.semanticPromptInvariantsHold())

        // alt-screen round trip mid-prompt
        let alt = fresh()
        alt.feed(text: "\u{1b}]133;A\u{07}>\u{1b}[?1049h\u{1b}[?1049lrecovered")
        #expect(alt.buffer.semanticPromptInvariantsHold())
    }

    // F.1: a COMPLETED PS2 command's secondary row still classifies (its
    // joining mark chains to its OWN group), even after the next group
    // allocates, so the invariant checker does not false-positive and the new
    // group's geometry excludes it. This is the verbatim convergence probe.
    @Test func testOscCompletedPS2RowClassifiesAndIsolates() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 6, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}if true")
        terminal.sendUserInput([0x0d][...])                     // local Return: suspends
        terminal.feed(text: "\r\n\u{1b}]133;P;k=s\u{07}>>\u{1b}]133;B\u{07}fi")
        let ps2 = terminal.buffer.semanticPromptStartRow! + 1
        #expect(terminal.semanticRowKind(at: ps2) == .continuation)

        // Finish the command, then start a fresh group below it.
        terminal.sendUserInput([0x0d][...])
        terminal.feed(text: "\r\n\u{1b}]133;C\u{07}output")
        terminal.feed(text: "\r\n\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}next")

        // The now-dead PS2 row still derives its own group's kind (not nil), so
        // the invariant holds; the new group refuses a click on it.
        #expect(terminal.semanticRowKind(at: ps2) == .continuation)
        #expect(terminal.buffer.semanticPromptInvariantsHold())
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 1, row: ps2)))
    }

    // F.2a: `freshSemanticPromptLine`'s LF stamps the landing row with the
    // outgoing group's epoch; after allocation the new origin row must not
    // carry that foreign epoch (else E.4 absorption later wipes its own cells).
    @Test func testOscFreshLineStampDoesNotLeaveForeignEpochOnOrigin() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd")   // armed, cursor mid-line
        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}new")   // A mid-line -> fresh-line, new group

        let origin = terminal.buffer.semanticPromptStartRow!
        let epoch = terminal.buffer.lines[origin].semanticHardContinuationGroup
        #expect(epoch == nil || epoch == terminal.buffer.activeSemanticGroupID)
        #expect(terminal.semanticRowKind(at: origin) == .initial)
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    // F.2b: an alternate-screen round trip resets `.prompt` tagging (not just
    // `.input`), so a prompt hook that launches a full-screen tool does not
    // leave later output tagged as prompt.
    @Test func testOscAltScreenResetsPromptTagging() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A\u{07}>")              // normal buffer: .prompt
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1049l")       // alt round trip
        let row = terminal.buffer.yBase + terminal.getCursorLocation().y
        let col = terminal.getCursorLocation().x
        terminal.feed(text: "out")

        if case .prompt = terminal.semanticContent(at: Position(col: col, row: row)) {
            Issue.record("post-alt output was tagged as prompt")
        }
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    // F.2c: a repaint that reuses the group can still reconfigure the click
    // options — the options are not reuse-scoped, only the group ID is.
    @Test func testOscRepaintReconfiguresClickMode() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 8, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
        #expect(terminal.semanticPromptClickMode == .cursorKeys(.line))

        terminal.feed(text: "\r\u{1b}[2K\u{1b}]133;A;cl=m\u{07}>\u{1b}]133;B\u{07}abc")
        #expect(terminal.semanticPromptClickMode == .cursorKeys(.multiple))
    }

    // E.4: `finishSemanticLineAdvance` stamps only, it never writes nil. A
    // line feed while submitted that lands on a row already carrying an epoch
    // must leave that epoch intact (clearing it is a destruction path outside
    // R1's list). Neutering to "write nil when not stamping" clears it.
    @Test func testOscSubmittedLineFeedDoesNotClearEpoch() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}a\r\nb")
        #expect(terminal.buffer.lines[1].semanticHardContinuationGroup != nil)

        terminal.sendUserInput([0x0d][...])          // -> submitted
        terminal.feed(text: "\u{1b}[1;1H\n")         // LF lands on the epoch row
        #expect(terminal.buffer.lines[1].semanticHardContinuationGroup != nil)
    }

    // Acceptance 9a: a repeated same-origin A/B repaint while armed retains
    // the group ID (ghostty's PS1-embedded A re-emits on reset-prompt/SIGWINCH).
    @Test func testOscAcceptance9aRepaintRetainsGroup() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}cmd")
        let g1 = terminal.buffer.activeSemanticGroupID
        terminal.feed(text: "\r\u{1b}[2K\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}cmd")
        #expect(terminal.buffer.activeSemanticGroupID == g1)
    }

    // Acceptance 9b: `D` then `A`/`B` on the same line object allocates a new
    // group (the previous command ended, so it is not a repaint).
    @Test func testOscAcceptance9bCommandEndThenSameLineAllocates() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}cmd\u{1b}]133;D\u{07}")
        let g1 = terminal.buffer.activeSemanticGroupID
        terminal.feed(text: "\r\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}new")
        #expect(terminal.buffer.activeSemanticGroupID != g1)
    }

    // Acceptance 9c: `N`/`B` while still armed always allocates a new group.
    @Test func testOscAcceptance9cNextWhileArmedAllocates() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}cmd")
        let g1 = terminal.buffer.activeSemanticGroupID
        terminal.feed(text: "\r\u{1b}]133;N\u{07}>\u{1b}]133;B\u{07}x")
        #expect(terminal.buffer.activeSemanticGroupID != g1)
    }

    // Acceptance 9d: a local Return (suspends clicks, does not close the group)
    // followed by `P;k=s`/`B` retains the group ID and re-arms clicks against it.
    @Test func testOscAcceptance9dLocalReturnThenSecondaryRetains() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}cmd")
        let g1 = terminal.buffer.activeSemanticGroupID

        terminal.sendUserInput([0x0d][...])   // local Return: suspends, keeps group
        #expect(terminal.buffer.semanticInput == .submitted)
        #expect(terminal.buffer.activeSemanticGroupID == g1)

        terminal.feed(text: "\r\n\u{1b}]133;P;k=s\u{07}>>\u{1b}]133;B\u{07}more")
        #expect(terminal.buffer.activeSemanticGroupID == g1)
        #expect(terminal.buffer.semanticInput == .armed)
        // The PS2 row chains structurally and its input is clickable again.
        let ps2 = terminal.buffer.semanticPromptStartRow! + 1
        #expect(terminal.semanticRowKind(at: ps2) == .continuation)
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 3, row: ps2)))
    }

    // Acceptance 9e: a local Return followed by `A;k=i`/`B` allocates a new
    // group (a fresh primary prompt, not a PS2 continuation).
    @Test func testOscAcceptance9eLocalReturnThenInitialAllocates() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}cmd")
        let g1 = terminal.buffer.activeSemanticGroupID
        terminal.sendUserInput([0x0d][...])
        terminal.feed(text: "\r\n\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}new")
        #expect(terminal.buffer.activeSemanticGroupID != g1)
    }

    // Acceptance 9f: reuse is refused when the BufferLine identity changed
    // (recycling), even at the same numeric row — the origin object is gone,
    // so the next `A` allocates rather than adopting a recycled row.
    @Test func testOscAcceptance9fRecycledIdentityAllocates() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 2, scrollback: 0))
        terminal.feed(text: "\u{1b}[2;1H\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}cmd")
        let g1 = terminal.buffer.activeSemanticGroupID
        // Scroll enough to recycle the origin line object out of existence.
        terminal.feed(text: "\r\n\r\n\r\n")
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}new")
        #expect(terminal.buffer.activeSemanticGroupID != g1)
    }

    // C.1: a stale secondary mark from a dead group, surviving on a row that
    // the active group later spans, must not be chosen as the relative origin.
    // The old group's secondary sits on row 1; the new group is anchored at
    // row 0 and spans down through it. A `click_events=2` report on row 2 must
    // be relative to the live origin (row 0 → y=2), not the dead secondary
    // (row 1 → y=1).
    @Test func testOscRelativeOriginIgnoresDeadGroupSecondary() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 8, rows: 4, scrollback: 0))
        // Group 1: origin row 0, a PS2 secondary on row 1, then it ends.
        terminal.feed(text: "\u{1b}]133;A;click_events=2\u{07}>\u{1b}]133;B\u{07}on\r\n" +
                            "\u{1b}]133;P;k=s\u{07}>>\u{1b}]133;B\u{07}tw\u{1b}]133;C\u{07}")
        // Group 2: re-anchored at row 0 (cursor home, at the left margin so no
        // fresh line), spanning rows 0..2 as multi-row input.
        terminal.feed(text: "\u{1b}[1;1H\u{1b}]133;A;click_events=2\u{07}" +
                            "\u{1b}]133;B\u{07}aa\r\nbb\r\ncc")

        #expect(terminal.handleSemanticPromptClick(at: Position(col: 1, row: 2)))
        #expect(String(bytes: delegate.sentData, encoding: .utf8) == "\u{1b}[<0;2;2M")
    }

    // B.3: a new or recycled line must get the active buffer as its owner after
    // an alternate-screen transition. A stale owner corrupts liveness dedup.
    @Test func testOscLineOwnerIsSetAtAttachAfterAltScreen() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 8, rows: 3, scrollback: 4))
        terminal.feed(text: "\u{1b}]133;A\u{07}>\u{1b}]133;B\u{07}cmd")
        // Enter the alternate screen and scroll it to allocate and recycle
        // lines owned by the alternate buffer.
        terminal.feed(text: "\u{1b}[?1049h")
        for i in 0..<5 { terminal.feed(text: "alt-\(i)\r\n") }
        terminal.feed(text: "\u{1b}[?1049l")
        // Return to the normal screen and scroll it to allocate and recycle
        // lines owned by the normal buffer.
        for i in 0..<5 { terminal.feed(text: "norm-\(i)\r\n") }

        // Every line attached to the normal buffer is owned by that buffer.
        for row in 0..<terminal.buffer.lines.count {
            #expect(terminal.buffer.lines[row].owningBuffer === terminal.buffer)
        }
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }

    // B.1: a CR/LF arriving while the submission scanner is mid-sequence
    // (`.escape`/`.csi`/`.ss3`) aborts the sequence and submits. `ESC` then
    // `Enter` is the standard vi-mode sequence; the pre-fix scanner swallowed
    // it and left the buffer armed.
    @Test func testOscMidSequenceNewlineSubmits() {
        let prefixes: [[UInt8]] = [
            [0x1b],                               // ESC (→ escape)
            [UInt8]("\u{1b}[12;34".utf8),         // truncated CSI (→ csi)
            [UInt8]("\u{1b}O".utf8),              // SS3 (→ ss3)
        ]
        for prefix in prefixes {
            for splitAcrossCalls in [false, true] {
                let terminal = Terminal(delegate: SemanticDelegate(),
                                        options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
                terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
                if splitAcrossCalls {
                    terminal.sendUserInput(prefix[...])
                    terminal.sendUserInput([0x0d][...])
                } else {
                    terminal.sendUserInput((prefix + [0x0d])[...])
                }
                #expect(terminal.buffer.semanticInput == .submitted)
            }
        }
    }

    // The mirror of B.1: a newline inside a bracketed paste, even one that
    // follows a truncated escape in the pasted content, is literal and must
    // not submit.
    @Test func testOscMidSequenceNewlineInsidePasteDoesNotSubmit() {
        let terminal = Terminal(delegate: SemanticDelegate(),
                                options: TerminalOptions(cols: 20, rows: 3, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{07}>\u{1b}]133;B\u{07}abc")
        terminal.sendUserInput([UInt8]("\u{1b}[200~\u{1b}[12;34\n".utf8)[...])
        #expect(terminal.buffer.semanticInput == .armed)
    }

    // Acceptance 8: in-place repaint for ED 2. A multi-row `B` input with hard
    // line feeds; erase each whole row and repaint without another line feed
    // or `B`; clicks on all repainted input rows still work; then `C` stops
    // routing. Cell erasure never clears the continuation epoch.
    @Test func testOscAcceptanceEraseAndRepaintKeepsClicksThenCStops() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 8, rows: 4, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=m\u{07}>\u{1b}]133;B\u{07}ab\r\ncd")
        #expect(terminal.semanticRowKind(at: 1) == .continuation)

        // Erase both input rows whole and repaint them in place (no LF, no B).
        terminal.feed(text: "\u{1b}[1;2H\u{1b}[2K\u{1b}[1;2Hxy" +
                            "\u{1b}[2;1H\u{1b}[2K\u{1b}[2;1Hzw")
        #expect(terminal.semanticRowKind(at: 1) == .continuation)
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 0, row: 1)))
        #expect(!delegate.sentData.isEmpty)

        terminal.feed(text: "\u{1b}]133;C\u{07}")
        delegate.reset()
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 0, row: 1)))
        #expect(delegate.sentData.isEmpty)
    }

    // Acceptance 9: group isolation. After an erase-and-repaint, a new prompt
    // group started on a screen still holding the old group's epochs — no old
    // row derives as a continuation of the new group, and a click above the
    // new origin is refused.
    @Test func testOscAcceptanceGroupIsolation() {
        let delegate = SemanticDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: 8, rows: 5, scrollback: 0))
        terminal.feed(text: "\u{1b}]133;A;cl=m\u{07}>\u{1b}]133;B\u{07}ab\r\ncd")
        // A new group lower on the same screen, old epochs still present above.
        terminal.feed(text: "\u{1b}[4;1H\u{1b}]133;A;cl=m\u{07}>\u{1b}]133;B\u{07}ef")
        let newOrigin = terminal.buffer.semanticPromptStartRow!
        #expect(newOrigin == 3)

        // A click above the new origin — on the old group's rows — is refused:
        // those rows are not part of the active group's geometry, so their
        // stranded epochs never chain the new prompt.
        #expect(!terminal.handleSemanticPromptClick(at: Position(col: 0, row: 1)))
        #expect(delegate.sentData.isEmpty)
        // The new group's own click works.
        #expect(terminal.handleSemanticPromptClick(at: Position(col: 0, row: newOrigin)))
        #expect(terminal.buffer.semanticPromptInvariantsHold())
    }
}
#endif
