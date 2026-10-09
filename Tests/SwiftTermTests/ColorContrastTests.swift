//
//  ColorContrastTests.swift
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

final class ColorContrastTests {
    private let white = ColorContrast.RGB.white
    private let black = ColorContrast.RGB.black

    @Test func colorThatAlreadyReachesTheRatioIsUnchanged() {
        let darkGray = ColorContrast.RGB(red: 0.2, green: 0.2, blue: 0.2)
        #expect(ColorContrast.adjusted(darkGray, toReach: 4.5, against: white) == darkGray)
    }

    @Test func lightTextOnLightBackgroundDarkensJustEnough() {
        let nearWhite = ColorContrast.RGB(red: 0.97, green: 0.97, blue: 0.95)
        let adjusted = ColorContrast.adjusted(nearWhite, toReach: 4.5, against: white)
        let ratio = ColorContrast.ratio(adjusted, white)
        #expect(ratio >= 4.5)
        #expect(ratio < 4.6)
        #expect(ColorContrast.relativeLuminance(adjusted) < ColorContrast.relativeLuminance(nearWhite))
    }

    @Test func darkTextOnDarkBackgroundLightensJustEnough() {
        let background = ColorContrast.RGB(red: 0.05, green: 0.07, blue: 0.09)
        let dimBlue = ColorContrast.RGB(red: 0.1, green: 0.15, blue: 0.3)
        let adjusted = ColorContrast.adjusted(dimBlue, toReach: 4.5, against: background)
        let ratio = ColorContrast.ratio(adjusted, background)
        #expect(ratio >= 4.5)
        #expect(ratio < 4.6)
        // The hue survives: blue stays the strongest component.
        #expect(adjusted.blue > adjusted.red)
        #expect(adjusted.blue > adjusted.green)
    }

    @Test func textCrossesToTheOtherSideWhenItsOwnSideCannotReachTheRatio() {
        // Near-black text on a dark gray that even black can't reach 4.5 against.
        let background = ColorContrast.RGB(red: 0.3, green: 0.3, blue: 0.3)
        #expect(ColorContrast.ratio(black, background) < 4.5)
        let nearBlack = ColorContrast.RGB(red: 0.25, green: 0.25, blue: 0.25)
        let adjusted = ColorContrast.adjusted(nearBlack, toReach: 4.5, against: background)
        #expect(ColorContrast.ratio(adjusted, background) >= 4.5)
        #expect(ColorContrast.relativeLuminance(adjusted) > ColorContrast.relativeLuminance(background))
    }

    @Test func unreachableRatioGivesTheMostContrastAvailable() {
        let background = ColorContrast.RGB(red: 0.46, green: 0.46, blue: 0.46)
        let adjusted = ColorContrast.adjusted(background, toReach: 21, against: background)
        let best = max(ColorContrast.ratio(black, background), ColorContrast.ratio(white, background))
        #expect(abs(ColorContrast.ratio(adjusted, background) - best) < 0.0001)
    }

    @MainActor
    @Test func renderedTextIsAdjustedButBlockElementsAreNot() throws {
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 12, rows: 4, scrollback: 20))
        view.nativeBackgroundColor = .white
        view.nativeForegroundColor = .black
        // Near-white text, a near-white full block, then dim mid-gray text, all on white.
        view.feed(text: "\u{1B}[38;2;250;250;250mA\u{2588}\u{1B}[2;38;2;120;120;120mB\u{1B}[0m")

        let unchanged = try renderFirstRow(view)
        #expect(contrast(attributes(at: 0, in: unchanged)[.foregroundColor], .white) < 1.1)

        view.minimumContrastRatio = 4.5
        let adjusted = try renderFirstRow(view)
        #expect(contrast(attributes(at: 0, in: adjusted)[.foregroundColor], .white) >= 4.5)
        #expect(contrast(attributes(at: 2, in: adjusted)[.foregroundColor], .white) >= 4.5)
        // Block elements are drawn in the color the program chose.
        let block = try #require(adjusted.blockElements.first)
        #expect(contrast(block.foregroundColor, .white) < 1.1)
    }

    @MainActor
    @Test(arguments: [false, true])
    func fontRenderedShapesKeepTheirOriginalColors(dim: Bool) throws {
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 16, rows: 4, scrollback: 20))
        view.nativeBackgroundColor = .white
        view.nativeForegroundColor = .black
        view.customBlockGlyphs = false
        // Alternate text and all four Powerline separators, a block, and a box
        // drawing character with the same style to check both run boundaries.
        let dimSequence = dim ? "\u{1B}[2m" : ""
        view.feed(text: "\u{1B}[38;2;250;250;250m\(dimSequence)A\u{2588}B\u{2500}C\u{E0B0}D\u{E0B2}E\u{E0B4}F\u{E0B6}G")
        let original = try renderFirstRow(view)

        view.minimumContrastRatio = 4.5
        let adjusted = try renderFirstRow(view)
        #expect(adjusted.blockElements.isEmpty)
        #expect(adjusted.boxDrawings.isEmpty)
        #expect(adjusted.powerlineGlyphs.isEmpty)
        for index in stride(from: 0, through: 12, by: 2) {
            #expect(contrast(attributes(at: index, in: adjusted)[.foregroundColor], .white) >= 4.5)
        }
        for index in stride(from: 1, through: 11, by: 2) {
            let originalColor = try #require(attributes(at: index, in: original)[.foregroundColor] as? NSColor)
            let adjustedColor = try #require(attributes(at: index, in: adjusted)[.foregroundColor] as? NSColor)
            #expect(adjustedColor == originalColor)
        }
    }

    @MainActor
    @Test func selectedFontRenderedShapeUsesSelectionColors() throws {
        let view = TerminalView(frame: .zero, font: nil, options: TerminalOptions(cols: 12, rows: 4, scrollback: 20))
        view.nativeBackgroundColor = .white
        view.nativeForegroundColor = .black
        view.customBlockGlyphs = false
        view.minimumContrastRatio = 4.5
        view.selectedTextForegroundColor = .red
        view.selectedTextBackgroundColor = .blue
        view.feed(text: "\u{1B}[38;2;250;250;250mA\u{2588}B")
        view.selection.startSelection(row: 0, col: 1)
        view.selection.dragExtend(bufferPosition: Position(col: 2, row: 0))

        let row = try renderFirstRow(view)
        let selected = attributes(at: 1, in: row)
        #expect((selected[.foregroundColor] as? NSColor) == view.selectedTextForegroundColor)
        #expect((selected[.selectionBackgroundColor] as? NSColor) == view.selectedTextBackgroundColor)
        #expect(contrast(attributes(at: 0, in: row)[.foregroundColor], .white) >= 4.5)
        #expect(contrast(attributes(at: 2, in: row)[.foregroundColor], .white) >= 4.5)
    }

    @MainActor
    private func renderFirstRow(_ view: TerminalView) throws -> ViewLineInfo {
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection),
                                 deferBidiTypesetting: false)
        }
        let row = try #require(snapshot.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        return view.textBuilder.buildAttributedString(row: row, absoluteRow: snapshot.firstRow, context: context)
    }

    private func attributes(at index: Int, in info: ViewLineInfo) -> [NSAttributedString.Key: Any] {
        let joined = NSMutableAttributedString()
        for segment in info.segments {
            joined.append(segment.attributedString)
        }
        return joined.attributes(at: index, effectiveRange: nil)
    }

    private func contrast(_ value: Any?, _ background: NSColor) -> Double {
        func components(_ color: NSColor) -> ColorContrast.RGB {
            let srgb = color.usingColorSpace(.sRGB)!
            return ColorContrast.RGB(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
        }
        guard let color = value as? NSColor else { return 0 }
        return ColorContrast.ratio(components(color), components(background))
    }
}
#endif
