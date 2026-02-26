//
//  GhosttyImplicitLinkDetectionTests.swift
//
//
//  Created by Codex on 2/26/26.
//

import Foundation
import Testing

@testable import SwiftTerm

final class GhosttyImplicitLinkDetectionTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
    }

    private func makeTerminal(for input: String) -> Terminal {
        let cols = max(256, input.count + 8)
        return Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: 1))
    }

    private func assertImplicitMatch(input: String, expected: String) {
        let terminal = makeTerminal(for: input)
        terminal.feed(text: input)

        guard let expectedRange = input.range(of: expected) else {
            Issue.record("expected match not found in input: \(expected)")
            return
        }

        let expectedStart = input.distance(from: input.startIndex, to: expectedRange.lowerBound)
        let hitOffset = expectedStart + min(1, max(expected.count - 1, 0))
        let link = terminal.link(at: .buffer(Position(col: hitOffset, row: 0)), mode: .explicitAndImplicit)
        #expect(link == expected)
    }

    private func assertNoImplicitMatch(input: String) {
        let terminal = makeTerminal(for: input)
        terminal.feed(text: input)

        let colsToCheck = max(1, input.count)
        for col in 0..<colsToCheck {
            let link = terminal.link(at: .buffer(Position(col: col, row: 0)), mode: .explicitAndImplicit)
            #expect(link == nil)
        }
    }

    @Test func testGhosttyStyleImplicitPositiveCases() {
        let cases: [(String, String)] = [
            ("hello https://example.com world", "https://example.com"),
            ("https://example.com/foo(bar) more", "https://example.com/foo(bar)"),
            ("https://example.com/foo(bar)baz more", "https://example.com/foo(bar)baz"),
            ("Link inside (https://example.com) parens", "https://example.com"),
            ("Link period https://example.com. More text.", "https://example.com"),
            ("Link trailing comma https://example.com, more text.", "https://example.com"),
            ("Link in double quotes \"https://example.com\" and more", "https://example.com"),
            ("Link in single quotes 'https://example.com' and more", "https://example.com"),
            ("some file with https://google.com https://duckduckgo.com links.", "https://google.com"),
            ("and links in it. links https://yahoo.com mailto:test@example.com ssh://1.2.3.4", "https://yahoo.com"),
            ("also match http://example.com non-secure links", "http://example.com"),
            ("match tel://+12123456789 phone numbers", "tel://+12123456789"),
            ("match tel:+18005551234 tel links", "tel:+18005551234"),
            ("match with query url https://example.com?query=1&other=2 and more text.", "https://example.com?query=1&other=2"),
            ("url with dashes [mode 2027](https://github.com/contour-terminal/terminal-unicode-core) for better unicode support", "https://github.com/contour-terminal/terminal-unicode-core"),
            ("dot.http://example.com", "http://example.com"),
            ("weird characters https://example.com/~user/?query=1&other=2#hash and more", "https://example.com/~user/?query=1&other=2#hash"),
            ("square brackets https://example.com/[foo] and more", "https://example.com/[foo]"),
            ("[13]:TooManyStatements: TempFile#assign_temp_file_to_entity has approx 7 statements [https://example.com/docs/Too-Many-Statements.md]", "https://example.com/docs/Too-Many-Statements.md"),
            ("match ftp://example.com ftp links", "ftp://example.com"),
            ("match file://example.com file links", "file://example.com"),
            ("match ssh://example.com ssh links", "ssh://example.com"),
            ("match git://example.com git links", "git://example.com"),
            ("/tmp/test.txt http://www.google.com", "/tmp/test.txt"),
            ("match news:comp.infosystems.www.servers.unix news links", "news:comp.infosystems.www.servers.unix"),
            ("Serving HTTP on :: port 8000 (http://[::]:8000/)", "http://[::]:8000/"),
            ("IPv6 address https://[2001:db8::1]:8080/path", "https://[2001:db8::1]:8080/path"),
            ("../example.py", "../example.py"),
            ("../example.py ", "../example.py "),
            ("first time ../example.py contributor ", "../example.py"),
            ("src/config/url.zig", "src/config/url.zig"),
            ("app/folder/file.rb:1", "app/folder/file.rb:1"),
            ("lib/ghostty/terminal.zig:42:10", "lib/ghostty/terminal.zig:42:10"),
            ("~/foo/bar.txt", "~/foo/bar.txt"),
            ("$HOME/src/config/url.zig", "$HOME/src/config/url.zig"),
            ("foo/$BAR/baz", "foo/$BAR/baz"),
            (".foo/bar/$VAR", ".foo/bar/$VAR"),
            (".config/ghostty/config", ".config/ghostty/config"),
            ("loaded from .local/share/ghostty/state.db now", ".local/share/ghostty/state.db"),
            ("  - shared/src/foo/SomeItem.m:12, shared/src/", "shared/src/foo/SomeItem.m:12"),
            ("foo.local/share", "foo.local/share"),
            ("2024/report.txt", "2024/report.txt"),
            ("./spaces-end.   ", "./spaces-end.   "),
            ("./space middle", "./space middle")
        ]

        for (input, expected) in cases {
            assertImplicitMatch(input: input, expected: expected)
        }
    }

    @Test func testGhosttyStyleImplicitNoMatchCases() {
        let noMatchCases = [
            "example.com",
            "www.example.com",
            "input/output",
            "foo/bar",
            "$10/bar",
            "$10/$20",
            "$10/bar.txt",
            "foo/bar,baz.txt",
            "foo$BAR/baz.txt",
            "foo~/bar.txt",
            "// foo bar",
            "//foo"
        ]

        for input in noMatchCases {
            assertNoImplicitMatch(input: input)
        }
    }
}

