//
//  GraphemeColumnWidthTests.swift
//
//  UnicodeUtil.columnWidth(of:regionalIndicatorWidth:) gives a whole grapheme
//  the columns the terminal's insert path gives it.
//

import Foundation
import Testing

@testable import SwiftTerm

@Suite final class GraphemeColumnWidthTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private static let characters: [String] = [
        "a", "日", "𠮷", "😀", "❤️", "☺️", "✌️", "⌚︎", "e\u{301}", "कि", "क्ष",
        "\u{200B}", "\u{301}", "🇯🇵", "🇯", "👩‍👩‍👦", "👍🏽", "ก",
    ]

    private func terminalWidth(of character: String, _ regionalIndicatorWidth: RegionalIndicatorWidth) -> Int {
        var options = TerminalOptions(cols: 10, rows: 2)
        options.regionalIndicatorWidth = regionalIndicatorWidth
        let terminal = Terminal(delegate: self, options: options)
        terminal.feed(text: character)
        return terminal.buffer.x
    }

    @Test(arguments: characters, [RegionalIndicatorWidth.wide, .narrow])
    func widthMatchesTheTerminal(_ character: String, _ regionalIndicatorWidth: RegionalIndicatorWidth) {
        #expect(UnicodeUtil.columnWidth(of: Character(character), regionalIndicatorWidth: regionalIndicatorWidth)
                == terminalWidth(of: character, regionalIndicatorWidth))
    }
}
