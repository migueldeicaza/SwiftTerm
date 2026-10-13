#if os(macOS)
import CoreGraphics
import Testing
@testable import SwiftTerm

struct SixelRenderingTests {
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

    @Test func rasterAttributesDoNotForceLargeAllocation() {
        let host = HeadlessTerminal { _ in }
        host.terminal.feed(text: "\u{1b}Pq\"1;1;4096;4096#0~\u{1b}\\")
        #expect(host.images.count == 1)
        #expect(host.images.first?.0.count == 24)
    }
    @Test func transparentColorPassesPreserveEarlierPixels() {
        let host = HeadlessTerminal { _ in }
        host.terminal.feed(text: "\u{1b}Pq#1;2;100;0;0#1!3~$#2!3?$#3!3?\u{1b}\\")
        #expect(host.images.count == 1)
        guard let image = host.images.first else { return }
        #expect(image.1 == 3)
        #expect(image.2 == 6)
        #expect(image.0 == Array(repeating: [UInt8(255), 0, 0, 255], count: 18).flatMap { $0 })
    }

#if canImport(AppKit)
    /// The cell width is in points; Sixel images are in device pixels.
    @Test func sixelImagesTakeTheTerminalWidthOnlyWhenWiderInDevicePixels() {
        func isFullWidth(_ width: Int, scale: CGFloat) -> Bool {
            if case .percent(100) = TerminalView.sixelWidthRequest(imageWidth: width, columns: 80,
                                                                   cellWidth: 8, imageScale: scale) {
                return true
            }
            return false
        }
        // 80 columns of 8 points: 640 points, 1280 device pixels at 2×.
        #expect(!isFullWidth(1000, scale: 2))
        #expect(!isFullWidth(1280, scale: 2))
        #expect(isFullWidth(1281, scale: 2))
        #expect(!isFullWidth(640, scale: 1))
        #expect(isFullWidth(641, scale: 1))
    }
#endif

    @Test(arguments: [
        "!999999999999999999999999~",
        "!\(Int.max)~",
        "!\(Int.max)?~~",
        "#999999999999999999999999~"
    ])
    func unrepresentableNumbersDoNotTrap(payload: String) {
        let host = HeadlessTerminal { _ in }
        host.terminal.feed(text: "\u{1b}Pq" + payload + "\u{1b}\\OK")
        #expect(host.images.isEmpty)
        #expect(host.terminal.getCursorLocation().x == 2)
    }

}
#endif
