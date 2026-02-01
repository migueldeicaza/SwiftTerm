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

}
#endif
