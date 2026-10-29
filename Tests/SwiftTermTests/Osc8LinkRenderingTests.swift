#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite("OSC 8 link rendering")
struct Osc8LinkRenderingTests {
    private func refresh(_ snapshot: TerminalSnapshot, from view: TerminalView) {
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
    }

    private func attributes(of character: Character, row: TerminalSnapshot.Row,
                            absoluteRow: Int, context: SnapshotRenderContext,
                            builder: SnapshotTextBuilder) throws -> [NSAttributedString.Key: Any] {
        let text = builder.buildAttributedString(row: row, absoluteRow: absoluteRow, context: context)
        for segment in text.segments {
            let index = (segment.attributedString.string as NSString).range(of: String(character)).location
            if index != NSNotFound {
                return segment.attributedString.attributes(at: index, effectiveRange: nil)
            }
        }
        Issue.record("The rendered row does not contain the test character.")
        return [:]
    }

    @Test(arguments: [LinkHighlightMode.always, .alwaysWithModifier])
    func disablingExistingLinksUpdatesShapedAndPlainRows(_ mode: LinkHighlightMode) throws {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 12, rows: 4))
        view.frameDriver.invalidate()
        view.linkHighlightMode = mode
        view.commandActive = true
        view.feed(text: "\u{1b}]8;;https://example.test\u{7}L\u{1b}]8;;\u{7} \u{1b}[4mU\u{1b}[0m")
        let snapshot = TerminalSnapshot()
        let builder = SnapshotTextBuilder()
        var enabledStyle: SnapshotStyle?

        for enabled in [true, false, true] {
            view.enableOsc8Hyperlinks = enabled
            refresh(snapshot, from: view)
            #expect(snapshot.style.enableOsc8Hyperlinks == enabled)
            if enabled {
                enabledStyle = snapshot.style
            } else {
                let previous = try #require(enabledStyle)
                #expect(!snapshot.style.hasSameValue(as: previous))
                #expect(snapshot.appearanceChanged)
            }
            let row = try #require(snapshot.rows.first)
            let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
            let link = try attributes(of: "L", row: row, absoluteRow: snapshot.firstRow,
                                      context: context, builder: builder)
            let underlined = try attributes(of: "U", row: row, absoluteRow: snapshot.firstRow,
                                            context: context, builder: builder)
            #expect((link[.underlineStyle] != nil) == enabled)
            #expect(underlined[.underlineStyle] != nil)

            let plain = try #require(builder.plainRow(row: row, absoluteRow: snapshot.firstRow,
                                                      context: context))
            let linkRun = try #require(plain.runs.first(where: { $0.start <= 0 && $0.end > 0 }))
            let underlineRun = try #require(plain.runs.first(where: { $0.start <= 2 && $0.end > 2 }))
            #expect((linkRun.style.underline != nil) == enabled)
            #expect(underlineRun.style.underline != nil)
        }
    }

    @Test(arguments: [LinkHighlightMode.hover, .hoverWithModifier])
    func disablingOsc8KeepsImplicitLinkHighlights(_ mode: LinkHighlightMode) throws {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 24, rows: 4))
        view.frameDriver.invalidate()
        view.feed(text: "https://example.test")
        view.enableOsc8Hyperlinks = false
        view.linkHighlightMode = mode
        view.commandActive = true
        view.linkHighlightRange = [.init(row: 0, range: 0..<20)]
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        let row = try #require(snapshot.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        let builder = SnapshotTextBuilder()
        let link = try attributes(of: "h", row: row, absoluteRow: snapshot.firstRow,
                                  context: context, builder: builder)
        #expect(link[.underlineStyle] != nil)
        let plain = try #require(builder.plainRow(row: row, absoluteRow: snapshot.firstRow,
                                                  context: context))
        #expect(plain.runs.first?.style.underline != nil)
    }

    @Test(arguments: [LinkHighlightMode.hover, .hoverWithModifier])
    func directTerminalChangesCheckExistingHoverHighlights(_ mode: LinkHighlightMode) throws {
        for label in ["label", "https://example.test"] {
            let view = TerminalView(frame: .zero, font: nil,
                                    options: TerminalOptions(cols: 32, rows: 4))
            view.frameDriver.invalidate()
            view.linkHighlightMode = mode
            view.commandActive = true
            view.feed(text: "\u{1b}]8;;https://target.test\u{7}\(label)\u{1b}]8;;\u{7}")
            let match = try #require(view.withTerminal {
                $0.linkMatch(at: .buffer(Position(col: 0, row: 0)), mode: .explicitAndImplicit)
            })
            #expect(match.isExplicit)
            view.linkHighlightRange = match.rowRanges
            let snapshot = TerminalSnapshot()
            let builder = SnapshotTextBuilder()
            let character = try #require(label.first)
            refresh(snapshot, from: view)
            let beforeRow = try #require(snapshot.rows.first)
            let beforeContext = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
            let before = try attributes(of: character, row: beforeRow,
                                        absoluteRow: snapshot.firstRow, context: beforeContext, builder: builder)
            #expect(before[.underlineStyle] != nil)

            view.withTerminal { $0.enableOsc8Hyperlinks = false }
            #expect(view.linkHighlightRange == match.rowRanges)
            refresh(snapshot, from: view)
            let isImplicit = label.hasPrefix("https://")
            #expect(snapshot.style.linkHighlightRange == (isImplicit ? match.rowRanges : nil))
            let row = try #require(snapshot.rows.first)
            let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
            let after = try attributes(of: character, row: row,
                                       absoluteRow: snapshot.firstRow, context: context, builder: builder)
            #expect((after[.underlineStyle] != nil) == isImplicit)
            let plain = try #require(builder.plainRow(row: row, absoluteRow: snapshot.firstRow,
                                                      context: context))
            #expect((plain.runs.first?.style.underline != nil) == isImplicit)
        }
    }

#if canImport(MetalKit) && DEBUG
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable),
          arguments: [LinkHighlightMode.always, .alwaysWithModifier])
    func disablingExistingLinksInvalidatesMetalRows(_ highlightMode: LinkHighlightMode) async throws {
        for mode in [MetalBufferingMode.perRowPersistent, .perFrameAggregated] {
            let harness = try #require(MetalPlainTextTests.Harness())
            harness.view.metalBufferingMode = mode
            harness.view.linkHighlightMode = highlightMode
            harness.view.commandActive = true
            harness.view.feed(text: "\u{1b}]8;;https://example.test\u{7}a link\u{1b}]8;;\u{7}")
            for side in [harness.plain, harness.shaped] {
                _ = try #require(await harness.frame(side))
                let enabled = try #require(await harness.frame(side))
                let original = try #require(side.renderer.lastDrawData)
                let originalDecorations = original.frame?.decorationCells.count
                    ?? original.rows.reduce(0) { $0 + $1.decorationCount }
                #expect(originalDecorations > 0)
                harness.view.enableOsc8Hyperlinks = false
                let disabled = try #require(await harness.frame(side))
                let updated = try #require(side.renderer.lastDrawData)
                let updatedDecorations = updated.frame?.decorationCells.count
                    ?? updated.rows.reduce(0) { $0 + $1.decorationCount }
                #expect(updatedDecorations == 0)
                #expect(side.renderer.debugRowCacheCounts.rebuilt > 0)
                #expect(enabled.pixels != disabled.pixels)
                harness.view.enableOsc8Hyperlinks = true
                let restored = try #require(await harness.frame(side))
                #expect(restored.pixels == enabled.pixels)
            }
        }
    }
#endif
}
#endif
