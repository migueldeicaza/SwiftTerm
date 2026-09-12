import XCTest
import SwiftTerm
@testable import SwiftTermWebWasm

final class InputFacadeTests: XCTestCase {
    func testTextLimitsAndInvalidHandles() {
        let handle = terminalCreate(4, 2, 0)
        defer { _ = terminalDestroy(handle) }
        XCTAssertEqual(terminalText(0, 0, 0), ABI.invalidHandle)
        XCTAssertEqual(terminalText(handle, 0, 0), 0)
        XCTAssertEqual(terminalText(handle, 0, 65537), ABI.invalidArgument)
        XCTAssertEqual(terminalText(handle, 1, 1), ABI.outOfBounds)
        XCTAssertEqual(terminalPointerModes(0), ABI.invalidHandle)
        XCTAssertEqual(terminalPointerModes(handle), 128)
    }

    func testMouseValidationAndTracking() {
        let handle = terminalCreate(4, 2, 0)
        defer { _ = terminalDestroy(handle) }
        XCTAssertEqual(terminalMouse(0, 0, 0, 0, 0, 0, 0, 0), ABI.invalidHandle)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 0, 0, 0, 0), 0)
        XCTAssertEqual(terminalMouse(handle, 4, 0, 0, 0, 0, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 0, 3, 0, 0, 0, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 1, 4, 0, 0, 0, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 2, 4, 0, 0, 0, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 3, 0, 0, 0, 0, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 16, 0, 0, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 4, 0, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 0, 2, 0, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 0, 0, 65536, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 0, 0, UInt32.max, 0), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 0, 0, 65535, 65535), 0)
        XCTAssertEqual(WasmRuntime.shared.mutate(handle) { entry in
            entry.terminal.feed(text: "\u{1b}[?9h")
            return 0
        }, 0)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 0, 0, 0, 0), 1)
        XCTAssertEqual(terminalMouse(handle, 1, 0, 0, 0, 0, 0, 0), 0)
        XCTAssertEqual(terminalMouse(handle, 2, 0, 0, 0, 0, 0, 0), 0)
    }

    func testMouseUsesLogicalPixelBounds() {
        let handle = terminalCreate(4, 2, 0)
        defer { _ = terminalDestroy(handle) }
        XCTAssertEqual(terminalResize(handle, 4, 2, 8, 16), 0)
        XCTAssertEqual(WasmRuntime.shared.mutate(handle) { entry in
            entry.terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1016h")
            return 0
        }, 0)
        XCTAssertEqual(terminalPointerModes(handle), 128 | 4 | (4 << 3))
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 3, 1, 31, 31), 1)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 3, 1, 32, 31), ABI.invalidArgument)
        XCTAssertEqual(terminalMouse(handle, 0, 0, 0, 3, 1, 31, 32), ABI.invalidArgument)
    }
}
