//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/29/21.
//
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class ColorTests {
    private func rgb8(_ color: Color) -> (Int, Int, Int) {
        return (Int(color.red / 257), Int(color.green / 257), Int(color.blue / 257))
    }

    @Test func testExtendedColor() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        
        let t = h.terminal!
        
        // This tests that we are setting both foreground and background colors
        // using the semicolon style (there was some ambiguity that I had to deal with).
        t.feed (text: "\u{1b}[38;2;19;49;174;48;2;23;56;179mString\n\r")
        var chattr = t.buffer.getChar(at: Position (col: 0, row: 0))
        #expect(chattr.code == Int32(UInt8(ascii: "S")))
        #expect(chattr.attribute.fg == .trueColor(red: 19, green: 49, blue: 174))
        #expect(chattr.attribute.bg == .trueColor(red: 23, green: 56, blue: 179))
        
        // This is the new style
        t.feed (text: "\u{1b}[38:2::255:10:255mHello\n\r")
        chattr = t.buffer.getChar(at: Position (col: 0, row: 1))
        #expect(chattr.code == Int32(UInt8(ascii: "H")))
        #expect(chattr.attribute.fg == .trueColor(red: 255, green: 10, blue: 255))
        #expect(chattr.attribute.bg == .trueColor(red: 23, green: 56, blue: 179))
        
        // Partial sequences do not get parsed
        t.feed (text: "\u{1b}[38:2::255mPartial\n\r")
        chattr = t.buffer.getChar(at: Position (col: 0, row: 2))
        #expect(chattr.code == Int32(UInt8(ascii: "P")))
        #expect(chattr.attribute.bg == .defaultColor)
        #expect(chattr.attribute.fg == .defaultColor)
    }

    @Test func testAnsi256PaletteXtermStrategy() {
        let palette = Color.setupDefaultAnsiColors(initialColors: Color.xtermColors,
                                                   strategy: .xterm)

        #expect(palette.count == 256)
        for i in 0..<16 {
            #expect(palette[i] == Color.xtermColors[i])
        }

        // Keep historical xterm values for the generated region.
        #expect(rgb8(palette[16]) == (0, 0, 0))
        #expect(rgb8(palette[17]) == (0, 0, 95))
        #expect(rgb8(palette[231]) == (255, 255, 255))
        #expect(rgb8(palette[232]) == (8, 8, 8))
        #expect(rgb8(palette[255]) == (238, 238, 238))
    }

    @Test func testAnsi256PaletteBase16LabStrategyMatchesGhosttyReferenceIndices() {
        let bg = Color(red8: 0, green8: 0, blue8: 0)
        let fg = Color(red8: 255, green8: 255, blue8: 255)

        let generated = Color.setupDefaultAnsiColors(initialColors: Color.xtermColors,
                                                     strategy: .base16Lab,
                                                     backgroundColor: bg,
                                                     foregroundColor: fg)
        let xterm = Color.setupDefaultAnsiColors(initialColors: Color.xtermColors,
                                                 strategy: .xterm)

        #expect(generated.count == 256)
        for i in 0..<16 {
            #expect(generated[i] == Color.xtermColors[i])
        }

        // These values are from the gist/Ghostty interpolation model.
        #expect(rgb8(generated[16]) == (0, 0, 0))
        #expect(rgb8(generated[17]) == (24, 12, 46))
        #expect(rgb8(generated[21]) == (0, 0, 238))
        #expect(rgb8(generated[196]) == (205, 0, 0))
        #expect(rgb8(generated[231]) == (255, 255, 255))
        #expect(rgb8(generated[232]) == (14, 14, 14))
        #expect(rgb8(generated[255]) == (243, 243, 243))

        // Ensure strategy actually changes the generated entries.
        #expect(rgb8(generated[17]) != rgb8(xterm[17]))
        #expect(rgb8(generated[232]) != rgb8(xterm[232]))
    }

    @Test func testTerminalAnsi256PaletteStrategyRuntimeToggle() {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue) { _ in }
        let terminal = h.terminal!
        terminal.backgroundColor = Color(red8: 0, green8: 0, blue8: 0)
        terminal.foregroundColor = Color(red8: 255, green8: 255, blue8: 255)

        terminal.installPalette(colors: Color.xtermColors)
        #expect(terminal.ansi256PaletteStrategy == .base16Lab)
        #expect(rgb8(terminal.ansiColors[17]) == (24, 12, 46))

        terminal.ansi256PaletteStrategy = .xterm
        #expect(rgb8(terminal.ansiColors[17]) == (0, 0, 95))
        #expect(rgb8(terminal.ansiColors[232]) == (8, 8, 8))

        terminal.ansi256PaletteStrategy = .base16Lab
        #expect(rgb8(terminal.ansiColors[17]) == (24, 12, 46))
        #expect(rgb8(terminal.ansiColors[232]) == (14, 14, 14))
    }
}
#endif
