//
//  ProfileSupportTests.swift
//
//  Tests for the configuration surface used by host applications to implement
//  profiles: CursorStyle naming/coding, public color parsing and palettes, and
//  TerminalOptions injection into TerminalView.
//
#if os(macOS)
import Foundation
import Testing
import AppKit

@testable import SwiftTerm

final class CursorStyleTests {
    @Test func tagNameRoundTrips () {
        for style in CursorStyle.allCases {
            #expect (CursorStyle (tagName: style.tagName) == style)
        }
    }

    @Test func displayNamesAreUnique () {
        let names = Set (CursorStyle.allCases.map { $0.displayName })
        #expect (names.count == CursorStyle.allCases.count)
    }

    @Test func unknownTagNameFails () {
        #expect (CursorStyle (tagName: "wobblyBlock") == nil)
    }

    @Test func interpolationIsUnchanged () {
        // The library must not adopt CustomStringConvertible: clients persist
        // "\(style)" and parse it back with from(string:)
        #expect ("\(CursorStyle.blinkBlock)" == "blinkBlock")
        #expect (CursorStyle.from (string: "\(CursorStyle.steadyBar)") == .steadyBar)
    }

    private final class CursorStyleDelegate: TerminalDelegate {
        var observedStyle: CursorStyle?

        func send (source: Terminal, data: ArraySlice<UInt8>) {}

        func cursorStyleChanged (source: Terminal, newStyle: CursorStyle) {
            observedStyle = source.options.cursorStyle
        }
    }

    @Test func callbackSeesTheNewCursorStyle () {
        let delegate = CursorStyleDelegate()
        let terminal = Terminal(delegate: delegate)

        terminal.setCursorStyle(.steadyUnderline)

        #expect(delegate.observedStyle == .steadyUnderline)
    }
}

final class ColorParseTests {
    @Test func parsesSixDigitHex () throws {
        let color = try #require (Color.parse ("#ff8000"))
        #expect (Int (color.red) == 0xff * 257)
        #expect (Int (color.green) == 0x80 * 257)
        #expect (Int (color.blue) == 0)
    }

    @Test func parsesThreeDigitHex () throws {
        // Regression test: the blue component used to read two hex digits and overflow
        let color = try #require (Color.parse ("#abc"))
        #expect (Int (color.red) == 0xa * 0x1010)
        #expect (Int (color.green) == 0xb * 0x1010)
        #expect (Int (color.blue) == 0xc * 0x1010)
    }

    @Test func parsesXParseForm () throws {
        let color = try #require (Color.parse ("rgb:12/34/56"))
        #expect (Int (color.red) == 0x12 * 257)
        #expect (Int (color.green) == 0x34 * 257)
        #expect (Int (color.blue) == 0x56 * 257)
    }

    @Test func rejectsGarbage () {
        #expect (Color.parse ("not a color") == nil)
        #expect (Color.parse ("") == nil)
        // Invalid hex digits and lengths must return nil, not black
        #expect (Color.parse ("#zzzzzz") == nil)
        #expect (Color.parse ("#12345") == nil)
        #expect (Color.parse ("rgb:12/34") == nil)
        #expect (Color.parse ("rgb:12/34/xy") == nil)
        #expect (Color.parse ("rgb:12345/1/1") == nil)
    }

    @Test func formattedRoundTrips () {
        let original = Color (red: 0x1234, green: 0xabcd, blue: 0xffff)
        let reparsed = Color.parse (original.formatted ())
        #expect (reparsed == original)
    }

    @Test func eightBitInitScalesAndClamps () {
        let color = Color (red8: 255, green8: 0, blue8: 300)
        #expect (color.red == 65535)
        #expect (color.blue == 65535)   // clamped to 255 then scaled
        #expect (color.green == 0)
    }

    @Test func builtinPalettesHaveSixteenColors () {
        for palette in [Color.paleColors, Color.vgaColors, Color.terminalAppColors,
                        Color.xtermColors, Color.defaultInstalledColors] {
            #expect (palette.count == 16)
        }
    }

    @Test func nativeBridgeRoundTrips () {
        let original = Color (red8: 40, green8: 44, blue8: 52)
        let bridged = Color (nsColor: original.nsColor)
        // sRGB conversion can wobble by a rounding step per channel
        #expect (abs (Int (bridged.red) - Int (original.red)) <= 257)
        #expect (abs (Int (bridged.green) - Int (original.green)) <= 257)
        #expect (abs (Int (bridged.blue) - Int (original.blue)) <= 257)
    }
}

final class BellStyleTests {
    @Test func tagNameRoundTrips () {
        for style in BellStyle.allCases {
            #expect (BellStyle (tagName: style.tagName) == style)
        }
        #expect (BellStyle (tagName: "kazoo") == nil)
    }
}

@MainActor
final class BellDispatchTests {
    final class CountingDelegate: TerminalViewDelegate {
        var bells = 0
        func sizeChanged (source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle (source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate (source: TerminalView, directory: String?) {}
        func send (source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled (source: TerminalView, position: Double) {}
        func rangeChanged (source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink (source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy (source: TerminalView, content: Data) {}
        func bell (source: TerminalView) {
            bells += 1
        }
    }

    @Test func bellStyleGatesDelegate () {
        let view = TerminalView (frame: CGRect (x: 0, y: 0, width: 400, height: 300))
        let delegate = CountingDelegate ()
        view.terminalDelegate = delegate

        view.bellStyle = .sound
        view.bell(source: view.terminal)
        #expect (delegate.bells == 1)

        view.bellStyle = .none
        view.bell(source: view.terminal)
        #expect (delegate.bells == 1)

        view.bellStyle = .visual
        view.bell(source: view.terminal)
        #expect (delegate.bells == 1)

        view.bellStyle = .soundAndVisual
        view.bell(source: view.terminal)
        #expect (delegate.bells == 2)
    }
}

final class ClearScrollbackTests {
    class DummyDelegate: TerminalDelegate {
        func send (source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test func clearScrollbackDropsHistoryKeepsScreen () {
        let terminal = Terminal (delegate: DummyDelegate (),
                                 options: TerminalOptions (cols: 20, rows: 5, scrollback: 100))
        for i in 0..<30 {
            terminal.feed (text: "line \(i)\r\n")
        }
        let buffer = terminal.buffer
        #expect (buffer.yBase > 0)
        let visibleBefore = terminal.getText (
            start: Position (col: 0, row: buffer.yBase),
            end: Position (col: 19, row: buffer.yBase))

        terminal.clearScrollback ()
        #expect (buffer.yBase == 0)
        #expect (buffer.yDisp == 0)
        let visibleAfter = terminal.getText (
            start: Position (col: 0, row: 0),
            end: Position (col: 19, row: 0))
        #expect (visibleAfter == visibleBefore)
    }

    @Test func clearScrollbackOnEmptyBufferIsANoop () {
        let terminal = Terminal (delegate: DummyDelegate (),
                                 options: TerminalOptions (cols: 20, rows: 5, scrollback: 100))
        terminal.feed (text: "hello")
        terminal.clearScrollback ()
        #expect (terminal.buffer.yBase == 0)
        let text = terminal.getText (start: Position (col: 0, row: 0),
                                     end: Position (col: 5, row: 0))
        #expect (text == "hello")
    }
}

@MainActor
final class BackgroundOpacityTests {
    @Test func opacityIsClampedAndCarriedInAlpha () {
        let view = TerminalView (frame: CGRect (x: 0, y: 0, width: 400, height: 300))
        #expect (view.backgroundOpacity == 1.0)

        view.nativeBackgroundColor = NSColor (srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        view.backgroundOpacity = 0.5
        #expect (abs (view.backgroundOpacity - 0.5) < 0.001)
        #expect (abs (view.nativeBackgroundColor.alphaComponent - 0.5) < 0.001)
        // The base color is preserved
        #expect (abs (view.nativeBackgroundColor.redComponent - 0.1) < 0.01)

        view.backgroundOpacity = 3.0
        #expect (view.backgroundOpacity == 1.0)
        view.backgroundOpacity = -1.0
        #expect (view.backgroundOpacity == 0.0)
    }

    @Test func alphaBearingBackgroundReadsAsOpacity () {
        let view = TerminalView (frame: CGRect (x: 0, y: 0, width: 400, height: 300))
        view.nativeBackgroundColor = NSColor (srgbRed: 0, green: 0, blue: 0, alpha: 0.85)
        #expect (abs (view.backgroundOpacity - 0.85) < 0.001)
    }
}

@MainActor
final class TerminalViewOptionsTests {
    @Test func startupOptionsReachTheTerminal () {
        var options = TerminalOptions.default
        options.scrollback = 1234
        options.cursorStyle = .steadyBar
        options.termName = "xterm-direct"
        options.cols = 132
        options.rows = 50

        let view = TerminalView (frame: .zero, options: options)
        view.withTerminal { terminal in
            #expect (terminal.options.scrollback == 1234)
            #expect (terminal.options.cursorStyle == .steadyBar)
            #expect (terminal.options.termName == "xterm-direct")
            // Zero-sized frame: the requested dimensions are used as-is
            #expect (terminal.cols == 132)
            #expect (terminal.rows == 50)
        }
    }

    @Test func sizedFrameRecomputesGrid () {
        var options = TerminalOptions.default
        options.cols = 132
        options.rows = 50
        let view = TerminalView (frame: CGRect (x: 0, y: 0, width: 400, height: 300), options: options)
        view.withTerminal { terminal in
            #expect (terminal.cols != 132 || terminal.rows != 50)
            #expect (terminal.options.scrollback == TerminalOptions.default.scrollback)
        }
    }

    @Test func resetFontSizeRestoresCellDimensions () {
        let view = TerminalView (frame: CGRect (x: 0, y: 0, width: 400, height: 300))
        let originalWidth = view.cellDimension.width
        view.font = NSFont.monospacedSystemFont (ofSize: 30, weight: .regular)
        #expect (view.cellDimension.width != originalWidth)
        view.resetFontSize ()
        #expect (view.cellDimension.width == originalWidth)
    }
}
#endif
