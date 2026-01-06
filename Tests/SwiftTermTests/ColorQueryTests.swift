import XCTest
@testable import SwiftTerm

final class ColorQueryTests: XCTestCase {
    private final class TestDelegate: TerminalDelegate {
        var sent: [[UInt8]] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            sent.append(Array(data))
        }
    }

    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    func testOsc10And11ColorQueriesReply() {
        let delegate = TestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 0)
        )

        terminal.foregroundColor = Color(red: 0x1111, green: 0x2222, blue: 0x3333)
        terminal.backgroundColor = Color(red: 0x4444, green: 0x5555, blue: 0x6666)

        terminal.feed(text: "\u{1b}]10;?\u{07}")
        terminal.feed(text: "\u{1b}]11;?\u{07}")

        XCTAssertEqual(delegate.sent.count, 2)
        XCTAssertEqual(delegate.sent[0], bytes("\u{1b}]10;rgb:1111/2222/3333\u{07}"))
        XCTAssertEqual(delegate.sent[1], bytes("\u{1b}]11;rgb:4444/5555/6666\u{07}"))
    }
}
