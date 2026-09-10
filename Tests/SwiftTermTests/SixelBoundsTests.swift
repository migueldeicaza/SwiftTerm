#if os(macOS)
import Testing
@testable import SwiftTerm

struct SixelBoundsTests {
    @Test(arguments: [
        "#0!999999999999999999999999999999999999999~",
        "#999999999999999999999999999999999999999~",
        "\"1;1;99999999999999999999999999999999999;1#0~",
        "\"1;1;16777217;1#0~",
        "\"1;1;8192;8192#0~",
        "#0!16777217~",
        "#0!3000000~",
        "#0!2000000~-!2000000~",
        "#0!16777216?$!1?",
    ])
    func rejectsUnboundedImages(payload: String) {
        let host = HeadlessTerminal { _ in }
        host.terminal.feed(text: "\u{1b}Pq\(payload)\u{1b}\\")
        #expect(host.images.isEmpty)
        host.terminal.feed(text: "OK")
        #expect(host.terminal.getLine(row: 0)?.translateToString(trimRight: true).contains("OK") == true)
    }

    @Test func validRepeatPaletteAndFinalBandKeepExactPixels() {
        let host = HeadlessTerminal { _ in }
        host.terminal.feed(text: "\u{1b}Pq\"1;1;3;6#1;2;100;0;0#1!3~\u{1b}\\")
        #expect(host.images.count == 1)
        guard let image = host.images.first else { return }
        #expect(image.1 == 3)
        #expect(image.2 == 6)
        #expect(image.0 == Array(repeating: [UInt8(255), 0, 0, 255], count: 18).flatMap { $0 })
    }

    @Test func defaultPaletteAndZeroRepeatRemainValid() {
        let host = HeadlessTerminal { _ in }
        host.terminal.feed(text: "\u{1b}Pq!0~\u{1b}\\")
        #expect(host.images.count == 1)
        #expect(host.images.first?.1 == 1)
        #expect(host.images.first?.2 == 6)
    }

    @Test func rasterAtPixelLimitDoesNotForceLargeAllocation() {
        let host = HeadlessTerminal { _ in }
        host.terminal.feed(text: "\u{1b}Pq\"1;1;4096;4096#0~\u{1b}\\")
        #expect(host.images.count == 1)
        #expect(host.images.first?.0.count == 24)
    }
}
#endif
