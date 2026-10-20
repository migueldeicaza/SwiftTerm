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
}
#endif
