//
//  MarkedTextOverlayColorTests.swift
//
//  The IME / dictation marked-text overlay takes its colors from the cell under
//  the caret, so it blends into rows a TUI paints with an explicit background
//  (Codex's input line) instead of drawing a band of the default background
//  across them.
//
#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

// Drives a TerminalView's input path, which must run on the main thread (F.4).
@MainActor
final class MarkedTextOverlayColorTests {

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
    }

    private func mark(_ view: TerminalView, _ text: String) {
        view.setMarkedText(text,
                           selectedRange: NSRange(location: (text as NSString).length, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func overlay(in view: TerminalView) -> DictationOverlayTextView? {
        view.subviews.lazy.compactMap { $0 as? DictationOverlayTextView }.first
    }

    private func foreground(of overlay: DictationOverlayTextView) -> NSColor? {
        overlay.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    /// The background the renderer fills the caret's cell with.
    private func renderedBackgroundAtCaret(in view: TerminalView) -> NSColor? {
        view.withTerminal { terminal in
            let buffer = terminal.displayBuffer
            let row = buffer.yBase + buffer.y
            let info = view.buildAttributedStringLocked(row: row, line: buffer.lines[row], cols: buffer.cols)
            guard let segment = info.segments.first(where: {
                $0.column <= buffer.x && buffer.x < $0.column + $0.columnWidth
            }) else { return nil }
            return segment.attributedString.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
    }

    private func ansiColor(_ index: Int, in view: TerminalView) -> NSColor {
        view.withTerminal { NSColor.make(color: $0.ansiColors[index]) }
    }

    private func rgb(_ color: NSColor) -> [Int] {
        let c = color.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    @Test func testOverlayUsesTheDefaultColorsOnAnUncoloredCell() throws {
        let view = makeView()
        mark(view, "ce shi")
        let overlay = try #require(overlay(in: view))
        #expect(rgb(overlay.overlayBackgroundColor) == rgb(view.effectiveNativeBackgroundColor))
        #expect(rgb(try #require(foreground(of: overlay))) == rgb(view.effectiveNativeForegroundColor))
    }

    /// Codex fills its input line with an explicit background and parks the
    /// caret on it.
    @Test func testOverlayTakesTheBackgroundOfTheCellUnderTheCaret() throws {
        let view = makeView()
        view.feed(text: "\u{1b}[48;2;64;64;64m          \u{1b}[0m\r")
        mark(view, "ce shi")
        let overlay = try #require(overlay(in: view))
        #expect(rgb(overlay.overlayBackgroundColor) == [64, 64, 64])
    }

    /// The cell under the caret of an empty prompt often holds a dimmed
    /// placeholder; adopting its foreground would dim the marked text too.
    @Test func testOverlayKeepsTheDefaultForegroundOverAColoredCell() throws {
        let view = makeView()
        view.feed(text: "\u{1b}[38;2;100;100;100;48;2;64;64;64mplaceholder\u{1b}[0m\r")
        mark(view, "ce shi")
        let overlay = try #require(overlay(in: view))
        #expect(rgb(try #require(foreground(of: overlay))) == rgb(view.effectiveNativeForegroundColor))
    }

    /// Reverse video swaps the default pair; keeping the default foreground
    /// would paint the marked text in the overlay's own background color.
    @Test func testOverlaySwapsTheDefaultPairUnderReverseVideo() throws {
        let view = makeView()
        view.feed(text: "\u{1b}[7m          \u{1b}[0m\r")
        mark(view, "ce shi")
        let overlay = try #require(overlay(in: view))
        #expect(rgb(overlay.overlayBackgroundColor) == rgb(view.effectiveNativeForegroundColor))
        #expect(rgb(try #require(foreground(of: overlay))) == rgb(view.effectiveNativeBackgroundColor))
    }

    /// Bold brightens a cell's foreground but never its background.
    @Test func testOverlayIgnoresBoldOnAnAnsiBackground() throws {
        let view = makeView()
        view.feed(text: "\u{1b}[1;41m          \u{1b}[0m\r")
        mark(view, "ce shi")
        let overlay = try #require(overlay(in: view))
        #expect(rgb(overlay.overlayBackgroundColor) == rgb(try #require(renderedBackgroundAtCaret(in: view))))
        #expect(rgb(overlay.overlayBackgroundColor) == rgb(ansiColor(1, in: view)))
    }

    /// Under reverse video the background comes from the cell's foreground
    /// color, which bold still must not brighten.
    @Test func testOverlayIgnoresBoldUnderReverseVideo() throws {
        let view = makeView()
        view.feed(text: "\u{1b}[1;7;31m          \u{1b}[0m\r")
        mark(view, "ce shi")
        let overlay = try #require(overlay(in: view))
        #expect(rgb(overlay.overlayBackgroundColor) == rgb(try #require(renderedBackgroundAtCaret(in: view))))
        #expect(rgb(overlay.overlayBackgroundColor) == rgb(ansiColor(1, in: view)))
    }

    /// With bright colors disabled the renderer collapses a bright background
    /// to its base color; the overlay has to follow it.
    @Test func testOverlayFollowsTheRendererWithBrightColorsDisabled() throws {
        let view = makeView()
        view.useBrightColors = false
        view.feed(text: "\u{1b}[101m          \u{1b}[0m\r")
        mark(view, "ce shi")
        let overlay = try #require(overlay(in: view))
        #expect(rgb(overlay.overlayBackgroundColor) == rgb(try #require(renderedBackgroundAtCaret(in: view))))
    }
}
#endif
