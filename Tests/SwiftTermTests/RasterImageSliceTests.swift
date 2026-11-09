//
//  RasterImageSliceTests.swift
//  SwiftTermTests
//
//  A headless host (for example a session helper that sends rows to another
//  process) reads the image slices of each line with `rasterImageSlices`.
//

import Foundation
import Testing
@testable import SwiftTerm

final class RasterSliceDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

struct RasterImageSliceTests {
    @Test func slicesFollowTheirLines() throws {
        let delegate = RasterSliceDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 5, scrollback: 100))
        terminal.feed(text: "top\r\nab")
        let pixels = [UInt8](repeating: 255, count: 30 * 25 * 4)
        let image = try #require(TerminalRasterImage(id: 7, width: 30, height: 25, rgba: pixels))
        // 10 × 10 pixel cells: 25 pixels high is three slices, at column 2.
        terminal.terminalLock.withLock {
            terminal.insertRasterImage(image, cellWidth: 10, cellHeight: 10)
        }
        let slices = terminal.terminalLock.withLock {
            (0..<terminal.buffer.lines.count).flatMap { terminal.rasterImageSlices(atRow: $0) }
        }
        #expect(slices.count == 3)
        #expect(slices.map(\.row) == [1, 2, 3])
        #expect(slices.allSatisfy { $0.column == 2 && $0.image.id == 7 && $0.width == 30 })
        #expect(slices.map(\.height) == [10, 10, 5])
        #expect(slices.last?.sourceY == 20)

        // Scrolling moves the lines into the scrollback; the slices stay on them.
        terminal.feed(text: "\r\n1\r\n2\r\n3\r\n4\r\n5")
        let after = terminal.terminalLock.withLock {
            (0..<terminal.buffer.lines.count).flatMap { terminal.rasterImageSlices(atRow: $0) }
        }
        #expect(after.map(\.row) == [1, 2, 3])
        #expect(terminal.terminalLock.withLock { terminal.rasterImageSlices(atRow: 99) }.isEmpty)
    }
}
