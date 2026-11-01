#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit
import Testing
@testable import SwiftTerm

@Suite("Independent bright color policy")
@MainActor
struct BrightColorPolicyTests {
    private func makeView() -> TerminalView {
        TerminalView(frame: .zero, font: nil,
                     options: TerminalOptions(cols: 12, rows: 4, scrollback: 20))
    }

    private func snapshot(_ view: TerminalView) -> TerminalSnapshot {
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        return snapshot
    }

    @Test func defaultsRetainLegacyCollapse() {
        let view = makeView()
        #expect(view.useBrightColors)
        #expect(view.collapseBrightColorsToBase)
        view.useBrightColors = false
        view.withTerminal { terminal in
            for code in UInt8(8)...UInt8(255) {
                let color = view.mapColor(color: .ansi256(code: code), isFg: true,
                                          isBold: false, useBrightColors: false)
                #expect(color == NSColor.make(color: terminal.ansiColors[Int(code) - 8]))
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func allForegroundIndexesMatchLiveAndSnapshot(useBright: Bool, collapse: Bool) {
        let view = makeView()
        view.useBrightColors = useBright
        view.collapseBrightColorsToBase = collapse
        let frame = snapshot(view)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: frame)
        view.withTerminal { terminal in
            for bold in [false, true] {
                for code in UInt8(0)...UInt8(255) {
                    // Preserve the existing promotion boundary (indexes below 7).
                    let index = useBright
                        ? Int(code) + (code < 7 && bold ? 8 : 0)
                        : Int(code) - (collapse && code > 7 ? 8 : 0)
                    let live = view.mapColor(color: .ansi256(code: code), isFg: true,
                                             isBold: bold, useBrightColors: useBright)
                    let captured = SwiftTerm.mapColor(color: .ansi256(code: code), isFg: true,
                                                      isBold: bold, context: context)
                    #expect(live == NSColor.make(color: terminal.ansiColors[index]))
                    #expect(captured == live)
                }
            }
        }
    }

    @Test func preservingIndexesDoesNotChangeBackgrounds() {
        let view = makeView()
        view.useBrightColors = false
        view.collapseBrightColorsToBase = false
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot(view))
        view.withTerminal { terminal in
            for code in UInt8(0)...UInt8(255) {
                let expected = NSColor.make(color: terminal.ansiColors[Int(code)])
                #expect(view.mapColor(color: .ansi256(code: code), isFg: false, isBold: false) == expected)
                #expect(SwiftTerm.mapColor(color: .ansi256(code: code), isFg: false,
                                          isBold: false, context: context) == expected)
            }
        }
    }

    @Test func nonIndexedColorsIgnoreCollapsePolicy() {
        let view = makeView()
        view.nativeForegroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        view.nativeBackgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        view.useBrightColors = false
        let colors: [Attribute.Color] = [.defaultColor, .defaultInvertedColor,
                                        .trueColor(red: 11, green: 47, blue: 239)]
        let beforeContext = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot(view))
        view.collapseBrightColorsToBase = false
        let afterContext = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot(view))
        for color in colors {
            for isFg in [false, true] {
                let before = SwiftTerm.mapColor(color: color, isFg: isFg, isBold: false, context: beforeContext)
                let after = SwiftTerm.mapColor(color: color, isFg: isFg, isBold: false, context: afterContext)
                #expect(before == after)
                view.withTerminal { _ in
                    #expect(view.mapColor(color: color, isFg: isFg, isBold: false, useBrightColors: false) == after)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func changingCollapseInvalidatesColorsAndFonts(bold: Bool) throws {
        let view = makeView()
        view.useBrightColors = false
        view.feed(text: "\u{1b}[\(bold ? "1;" : "")38;5;8mX")
        let cell = try #require(view.withTerminal { $0.getCharData(col: 0, row: 0) })
        let before = try renderedAttributes(view)
        let beforeIdentity = view.textBuilder.attributeCacheContextID
        let oldFrameState = FrameViewState(view: view)
        let cachedLive = view.withTerminal { _ in view.getAttributes(cell.attribute, withUrl: false) }
        #expect((cachedLive?[.font] as? NSFont) == oldFrameState.fonts.bold)
        #expect((before[.font] as? NSFont) == oldFrameState.fonts.bold)

        view.collapseBrightColorsToBase = false
        let after = try renderedAttributes(view)
        let afterIdentity = view.textBuilder.attributeCacheContextID
        let frame = snapshot(view)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: frame)
        let live = view.withTerminal { _ in view.getAttributes(cell.attribute, withUrl: false) }
        #expect(beforeIdentity != afterIdentity)
        #expect((before[.foregroundColor] as? NSColor) != (after[.foregroundColor] as? NSColor))
        #expect((live?[.foregroundColor] as? NSColor) == (after[.foregroundColor] as? NSColor))
        let expectedFont = bold ? context.fonts.bold : context.fonts.normal
        #expect((after[.font] as? NSFont) == expectedFont)
        #expect((live?[.font] as? NSFont) == expectedFont)
        let row = try #require(frame.rows.first)
        let plain = try #require(view.textBuilder.plainRow(row: row, absoluteRow: frame.firstRow, context: context))
        let run = try #require(plain.runs.first)
        #expect(run.style.fontIndex == (bold ? 1 : 0))
        if case .color(let foreground) = run.style.foreground {
            #expect(foreground == (after[.foregroundColor] as? NSColor))
        } else {
            Issue.record("Indexed foreground should be a palette color")
        }
        // A captured frame keeps its policy even after the view changes.
        #expect(oldFrameState.collapseBrightColorsToBase)
        #expect(!context.collapseBrightColorsToBase)

        view.collapseBrightColorsToBase = true
        let restored = try renderedAttributes(view)
        #expect((restored[.foregroundColor] as? NSColor) == (before[.foregroundColor] as? NSColor))
        #expect((restored[.font] as? NSFont) == (before[.font] as? NSFont))
    }

    @Test func changingBoldPromotionInvalidatesCachedAttributes() throws {
        let view = makeView()
        view.collapseBrightColorsToBase = false
        view.feed(text: "\u{1b}[1;31mX")
        let before = try renderedAttributes(view)
        let identity = view.textBuilder.attributeCacheContextID
        view.useBrightColors = false
        let after = try renderedAttributes(view)
        #expect(view.textBuilder.attributeCacheContextID != identity)
        #expect((before[.foregroundColor] as? NSColor) != (after[.foregroundColor] as? NSColor))
        #expect((before[.font] as? NSFont) == (after[.font] as? NSFont))
    }

    private func renderedAttributes(_ view: TerminalView) throws -> [NSAttributedString.Key: Any] {
        let frame = snapshot(view)
        let row = try #require(frame.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: frame)
        let info = view.textBuilder.buildAttributedString(row: row, absoluteRow: frame.firstRow, context: context)
        let joined = NSMutableAttributedString()
        for segment in info.segments { joined.append(segment.attributedString) }
        return joined.attributes(at: 0, effectiveRange: nil)
    }
}
#endif
