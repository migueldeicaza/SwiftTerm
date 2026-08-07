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
        let terminal = view.getTerminal ()
        #expect (terminal.options.scrollback == 1234)
        #expect (terminal.options.cursorStyle == .steadyBar)
        #expect (terminal.options.termName == "xterm-direct")
        // Zero-sized frame: the requested dimensions are used as-is
        #expect (terminal.cols == 132)
        #expect (terminal.rows == 50)
    }

    @Test func sizedFrameRecomputesGrid () {
        var options = TerminalOptions.default
        options.cols = 132
        options.rows = 50
        let view = TerminalView (frame: CGRect (x: 0, y: 0, width: 400, height: 300), options: options)
        let terminal = view.getTerminal ()
        #expect (terminal.cols != 132 || terminal.rows != 50)
        #expect (terminal.options.scrollback == TerminalOptions.default.scrollback)
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
