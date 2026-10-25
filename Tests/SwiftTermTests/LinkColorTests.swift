//
//  LinkColorTests.swift
//  SwiftTermTests
//
//  Covers `TerminalView.linkColor`: the attributes built for link cells, and
//  that changing the color reaches the next frame through the attribute cache.
//

import Foundation
import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit

@Suite("LinkColor")
@MainActor
struct LinkColorTests {
    /// "a", an OSC 8 link "L", then "b", all in ANSI red. `.always` draws
    /// every OSC 8 cell as a link without a hover.
    private func makeView() -> TerminalView {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 12, rows: 4, scrollback: 20))
        view.linkHighlightMode = .always
        view.feed(text: "\u{1b}[31ma\u{1b}]8;;https://example.test\u{07}L\u{1b}]8;;\u{07}b")
        return view
    }

    /// Renders the first row with the view's own builder and returns the
    /// attributes of the cell holding `character`.
    private func attributes(of character: Character, in view: TerminalView)
        throws -> [NSAttributedString.Key: Any]
    {
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        let row = try #require(snapshot.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view),
                                            snapshot: snapshot)
        let rendered = view.textBuilder.buildAttributedString(
            row: row, absoluteRow: snapshot.firstRow, context: context)
        for segment in rendered.segments {
            let text = segment.attributedString.string as NSString
            let index = text.range(of: String(character)).location
            if index != NSNotFound {
                return segment.attributedString.attributes(at: index, effectiveRange: nil)
            }
        }
        Issue.record("no rendered cell holds \(character)")
        return [:]
    }

    private func components(_ value: Any?) -> [Int]? {
        guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return nil }
        return [color.redComponent, color.greenComponent,
                color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    private let blue = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)
    private let green = NSColor(srgbRed: 0.2, green: 0.8, blue: 0.3, alpha: 1)

    /// With no link color, a link keeps its cell's foreground color and is
    /// underlined in it.
    @Test func nilLinkColorKeepsTheCellForeground() throws {
        let view = makeView()
        #expect(view.linkColor == nil)

        let plain = try attributes(of: "a", in: view)
        let link = try attributes(of: "L", in: view)
        #expect(link[.underlineStyle] != nil)
        #expect(components(link[.foregroundColor]) == components(plain[.foregroundColor]))
        #expect(components(link[.underlineColor]) == components(plain[.foregroundColor]))
    }

    /// A link color replaces the link's text and underline color, and leaves
    /// the cells around it alone.
    @Test func linkColorAppliesToLinkCellsOnly() throws {
        let view = makeView()
        let before = try attributes(of: "b", in: view)

        view.linkColor = blue
        let link = try attributes(of: "L", in: view)
        let after = try attributes(of: "b", in: view)

        #expect(components(link[.foregroundColor]) == components(blue))
        #expect(components(link[.underlineColor]) == components(blue))
        #expect(components(after[.foregroundColor]) == components(before[.foregroundColor]))
        #expect(after[.underlineStyle] == nil)
    }

    /// Changing the color after a frame was built must not serve the cached
    /// attributes of the old one.
    @Test func changingLinkColorInvalidatesCachedAttributes() throws {
        let view = makeView()
        view.linkColor = blue
        let first = try attributes(of: "L", in: view)
        let firstIdentity = view.textBuilder.attributeCacheContextID
        #expect(components(first[.foregroundColor]) == components(blue))

        view.linkColor = green
        let second = try attributes(of: "L", in: view)
        #expect(view.textBuilder.attributeCacheContextID != firstIdentity)
        #expect(components(second[.foregroundColor]) == components(green))
        #expect(components(second[.underlineColor]) == components(green))

        view.linkColor = nil
        let restored = try attributes(of: "L", in: view)
        let plain = try attributes(of: "a", in: view)
        #expect(components(restored[.foregroundColor]) == components(plain[.foregroundColor]))
    }

    @Test func underlineOverridePreservesTextAndOtherDecorations() throws {
        let view = makeView()
        view.feed(text: "\r\u{1b}[31;4;9ma\u{1b}]8;;https://example.test\u{07}L\u{1b}]8;;\u{07}b")
        let beforeLink = try attributes(of: "L", in: view)
        let beforePlain = try attributes(of: "a", in: view)
        #expect(view.linkUnderlineColor == nil)

        view.linkUnderlineColor = green
        let link = try attributes(of: "L", in: view)
        let plain = try attributes(of: "a", in: view)
        #expect(components(link[.underlineColor]) == components(green))
        #expect(components(link[.foregroundColor]) == components(beforeLink[.foregroundColor]))
        #expect(components(link[.strikethroughColor]) == components(beforeLink[.strikethroughColor]))
        #expect(components(plain[.underlineColor]) == components(beforePlain[.underlineColor]))
        #expect(components(plain[.strikethroughColor]) == components(beforePlain[.strikethroughColor]))
    }

    @Test func underlineOverrideWinsOverLinkColorAndInvalidatesCaches() throws {
        let view = makeView()
        view.linkColor = blue
        let original = try attributes(of: "L", in: view)
        let originalIdentity = view.textBuilder.attributeCacheContextID
        let appearance = view.frameCaptureCache.appearance(for: view)
        let snapshot = TerminalSnapshot()
        _ = snapshot.nativeColors(for: appearance)

        view.linkUnderlineColor = green
        let override = try attributes(of: "L", in: view)
        #expect(view.textBuilder.attributeCacheContextID != originalIdentity)
        #expect(components(override[.foregroundColor]) == components(blue))
        #expect(components(override[.underlineColor]) == components(green))
        let updatedAppearance = view.frameCaptureCache.appearance(for: view)
        #expect(updatedAppearance != appearance)
        #expect(components(snapshot.nativeColors(for: updatedAppearance).linkUnderlineColor) == components(green))

        view.linkUnderlineColor = blue
        let updated = try attributes(of: "L", in: view)
        #expect(components(updated[.underlineColor]) == components(blue))

        view.linkUnderlineColor = nil
        let restored = try attributes(of: "L", in: view)
        #expect(components(restored[.foregroundColor]) == components(original[.foregroundColor]))
        #expect(components(restored[.underlineColor]) == components(original[.underlineColor]))
        #expect(view.textBuilder.attributeCacheContextID == originalIdentity)
    }

    @Test func underlineOverrideResolvesDynamicColorForViewAppearance() throws {
        let view = makeView()
        view.linkUnderlineColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .green : .blue
        }
        view.appearance = NSAppearance(named: .aqua)
        let light = try attributes(of: "L", in: view)
        let lightIdentity = view.textBuilder.attributeCacheContextID
        view.appearance = NSAppearance(named: .darkAqua)
        let dark = try attributes(of: "L", in: view)
        #expect(components(light[.underlineColor]) == components(NSColor.blue))
        #expect(components(dark[.underlineColor]) == components(NSColor.green))
        #expect(view.textBuilder.attributeCacheContextID != lightIdentity)
    }

    @Test func implicitLinkAndMetalPlainRowUseUnderlineOverride() throws {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 24, rows: 4))
        view.feed(text: "https://example.test")
        view.linkHighlightMode = .hover
        view.linkHighlightRange = [.init(row: 0, range: 0..<20)]
        view.linkUnderlineColor = green
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        let row = try #require(snapshot.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        let shaped = try attributes(of: "h", in: view)
        let plain = try #require(view.textBuilder.plainRow(row: row, absoluteRow: snapshot.firstRow,
                                                         context: context))
        let run = try #require(plain.runs.first)
        guard case .color(let underlineColor) = run.style.underline?.color else {
            Issue.record("the Metal plain row must carry the host underline color")
            return
        }
        #expect(components(underlineColor) == components(green))
        #expect(components(underlineColor) == components(shaped[.underlineColor]))
        #expect(components(shaped[.foregroundColor]) != components(green))
    }

    @Test func selectionOverridesLinkUnderlineColor() throws {
        let view = makeView()
        view.linkColor = blue
        view.linkUnderlineColor = green
        view.selectedTextForegroundColor = .red
        view.selection.startSelection(row: 0, col: 1)
        view.selection.dragExtend(bufferPosition: Position(col: 2, row: 0))
        let selected = try attributes(of: "L", in: view)
        #expect(components(selected[.foregroundColor]) == components(NSColor.red))
        #expect(components(selected[.underlineColor]) == components(NSColor.red))
    }

}
#endif
