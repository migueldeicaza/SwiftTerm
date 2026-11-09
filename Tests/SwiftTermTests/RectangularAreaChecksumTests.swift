import Foundation
import Testing

@testable import SwiftTerm

/// DECRQCRA can read back the screen, so the host must enable it.
final class RectangularAreaChecksumTests: TerminalDelegate {
    var responses: [String] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        responses.append(String(decoding: data, as: UTF8.self))
    }

    func isProcessTrusted(source: Terminal) -> Bool { true }

    private func checksum(_ terminal: Terminal) -> String? {
        responses.removeAll()
        terminal.feed(text: "\u{1b}[7;1;1;1;1;1*y")
        return responses.joined().split(separator: "~").last.map { String($0.prefix(4)) }
    }

    @Test func defaultFollowsTheBuildConfiguration() {
        #if DEBUG
        #expect(TerminalOptions.default.enableRectangularAreaChecksum == true)
        #else
        #expect(TerminalOptions.default.enableRectangularAreaChecksum == false)
        #endif
    }

    @Test func disabledAnswersZeroAndEnabledAnswersTheChecksum() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(
            cols: 10, rows: 2, enableRectangularAreaChecksum: false))
        terminal.feed(text: "A")
        #expect(checksum(terminal) == "0000")

        terminal.enableRectangularAreaChecksum = true
        // "A" is 0x41.
        #expect(checksum(terminal) == "0041")

        terminal.enableRectangularAreaChecksum = false
        #expect(checksum(terminal) == "0000")
    }
}
