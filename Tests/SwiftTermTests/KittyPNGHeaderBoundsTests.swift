import Foundation
import Testing
@testable import SwiftTerm

struct KittyPNGHeaderBoundsTests {
    private func header(width: UInt32, height: UInt32) -> Data {
        var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
        for value in [width, height] {
            for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        bytes += [16, 6, 0, 0, 0, 0, 0, 0, 0]
        return Data(bytes)
    }

    @Test func headerRejectsInvalidOrExcessiveDimensionsBeforeDecode() {
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate)
        for (width, height): (UInt32, UInt32) in [(0, 1), (1, 0), (.max, 1), (1, .max), (10_001, 1), (10_000, 10_000)] {
            let data = header(width: width, height: height)
            #expect(!terminal.validateKittyPNGHeader(data))
            #expect(terminal.decodeTerminalImage(data) == nil)
        }
        #expect(!terminal.validateKittyPNGHeader(Data(header(width: 1, height: 1).prefix(24))))
        #expect(terminal.validateKittyPNGHeader(header(width: 1, height: 1)))
        #expect(terminal.validateKittyPNGHeader(header(width: 1000, height: 1000)))
    }
}
