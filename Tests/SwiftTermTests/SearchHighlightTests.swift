//
//  SearchHighlightTests.swift
//  SwiftTermTests
//
//  "Highlight all matches": the view option that paints all matches of the
//  search pattern on the visible rows. The ranges are computed when a frame
//  is prepared, so these tests go through the snapshot and the frame.
//

#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct SearchHighlightTests {
    static let matchColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    private func drain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    /// The view takes its size from the frame; use `cols(_:)` for the width.
    private func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200),
                                font: nil,
                                options: TerminalOptions(cols: 40, rows: 10, scrollback: 50))
        view.frameDriver.invalidate()
        view.highlightsAllSearchMatches = true
        view.searchMatchBackgroundColor = Self.matchColor
        removeTimeLimit(view)
        return view
    }

    /// These tests are about the ranges and the pixels. With the default
    /// limit, a slow moment in a parallel run makes a search late and the
    /// test then sees no highlights.
    private func removeTimeLimit(_ view: TerminalView) {
        view.withTerminal { _ in view.search.visibleMatchTimeLimit = 60_000_000_000 }
    }

    private func makeDrivenView() -> (TerminalView, ManualTickSource, FrameDriver) {
        let view = makeView()
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source)
        driver.onTick = { [weak view] in view?.frameTick() }
        view.frameDriver = driver
        return (view, source, driver)
    }

    @discardableResult
    private func refresh(_ snapshot: TerminalSnapshot, from view: TerminalView) -> TerminalSnapshot.RefreshResult {
        view.withTerminal { terminal in
            snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                             selection: SnapshotSelectionState(selection: view.selection),
                             search: view.search)
        }
    }

    private func cols(_ view: TerminalView) -> Int {
        view.withTerminal { $0.cols }
    }

    private func translatedRows(_ view: TerminalView) -> Int {
        view.withTerminal { _ in view.search.testingVisibleRowsTranslated }
    }

    private func attributes(_ snapshot: TerminalSnapshot, view: TerminalView, row: Int,
                            column: Int) -> [NSAttributedString.Key: Any] {
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        let line = SnapshotTextBuilder().buildAttributedString(
            row: snapshot.rows[row], absoluteRow: snapshot.firstRow + row, context: context)
        // The test rows hold only ASCII: one UTF-16 unit for each column.
        for segment in line.segments
            where column >= segment.column && column - segment.column < segment.attributedString.length {
            return segment.attributedString.attributes(at: column - segment.column, effectiveRange: nil)
        }
        Issue.record("no segment at column \(column)")
        return [:]
    }

    private func sameColor(_ value: Any?, _ expected: NSColor) -> Bool {
        guard let actual = (value as? NSColor)?.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else { return false }
        return abs(actual.redComponent - expected.redComponent) < 0.001
            && abs(actual.greenComponent - expected.greenComponent) < 0.001
            && abs(actual.blueComponent - expected.blueComponent) < 0.001
            && abs(actual.alphaComponent - expected.alphaComponent) < 0.001
    }

    // MARK: - Snapshot

    @Test func theSnapshotHoldsTheMatchesOfTheVisibleRows() {
        let view = makeView()
        view.feed(text: "foo bar foo\r\nbaz foo")
        let snapshot = TerminalSnapshot()

        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows.allSatisfy { $0.isEmpty }, "no pattern, no highlight")

        #expect(view.findNext("foo", scrollToResult: false))
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows.count == view.withTerminal { $0.rows })
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])
        #expect(snapshot.searchMatchRows[1] == [4..<7])
        #expect(snapshot.searchMatchChangedRows == 0...1)

        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchChangedRows == nil, "the same matches are not a change")
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])
    }

    @Test func theOptionIsOffByDefaultAndNoSearchRuns() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        removeTimeLimit(view)
        #expect(!view.highlightsAllSearchMatches)
        view.feed(text: "foo bar foo")
        #expect(view.findNext("foo", scrollToResult: false))
        let snapshot = TerminalSnapshot()
        let before = translatedRows(view)

        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows.allSatisfy { $0.isEmpty })
        #expect(translatedRows(view) == before)

        view.highlightsAllSearchMatches = true
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])

        view.highlightsAllSearchMatches = false
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows.allSatisfy { $0.isEmpty })
        #expect(snapshot.searchMatchChangedRows == 0...0)
    }

    @Test func theSearchRunsOnlyWhenItsInputsChange() {
        let view = makeView()
        view.feed(text: "foo bar foo")
        view.findNext("foo", scrollToResult: false)
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        let first = translatedRows(view)
        #expect(first > 0)

        refresh(snapshot, from: view)
        #expect(translatedRows(view) == first, "no change, no search")

        view.feed(text: "\r\nmore foo")
        refresh(snapshot, from: view)
        #expect(translatedRows(view) > first)
        #expect(snapshot.searchMatchRows[1] == [5..<8], "new output is highlighted")

        // Content changed with no call to the view: the row copy sees it.
        let afterFeed = translatedRows(view)
        view.withTerminal { $0.feed(text: "\r\nfoo") }
        refresh(snapshot, from: view)
        #expect(translatedRows(view) > afterFeed)
        #expect(snapshot.searchMatchRows[2] == [0..<3])
    }

    /// Each batch of output moves the search generation. When no visible row
    /// changed, the matches are the same and no search runs.
    @Test func outputThatChangesNoVisibleRowStartsNoSearch() {
        let view = makeView()
        view.feed(text: "foo bar foo")
        view.findNext("foo", scrollToResult: false)
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        let first = translatedRows(view)

        view.withTerminal { _ in view.search.invalidate() }
        refresh(snapshot, from: view)
        #expect(translatedRows(view) == first)
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])
    }

    /// A logical line that starts above the visible rows: its hidden rows can
    /// change a visible match, so the generation starts a search.
    @Test func aLineThatCrossesTheTopEdgeFollowsTheGeneration() {
        let view = makeView()
        let (cols, rows) = view.withTerminal { ($0.cols, $0.rows) }
        view.feed(text: String(repeating: "x", count: cols) + "foo"
                  + String(repeating: "\r\n", count: rows - 1))
        view.findNext("foo", scrollToResult: false)
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        #expect(view.withTerminal { $0.displayBuffer.lines[snapshot.firstRow].isWrapped })
        #expect(snapshot.searchMatchRows[0] == [0..<3])
        let first = translatedRows(view)

        view.withTerminal { _ in view.search.invalidate() }
        refresh(snapshot, from: view)
        #expect(translatedRows(view) > first)
    }

    /// The find bar's paths. A find with no bar on screen changes no
    /// highlight pattern. The bar's own highlights go away with the bar, and
    /// the host's highlights then show again.
    @Test func theFindBarKeepsTheHighlightsOfTheHost() {
        let view = makeView()
        view.feed(text: "foo bar foo")
        let snapshot = TerminalSnapshot()

        #expect(view.find("foo", options: SearchOptions(), next: true, highlights: nil))
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows.allSatisfy { $0.isEmpty })
        #expect(view.selection.active)

        // The host highlights "foo". Find Next for "bar" with no bar on
        // screen selects "bar"; the highlights stay on "foo".
        #expect(view.findNext("foo", scrollToResult: false))
        #expect(view.find("bar", options: SearchOptions(), next: true, highlights: nil))
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])

        // The bar highlights "bar", then hides.
        #expect(view.find("bar", options: SearchOptions(), next: true, highlights: .findBar))
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows[0] == [4..<7])
        view.clearSearchHighlights(owner: .findBar)
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])

        // An empty term in the bar.
        view.clearSearch(keepingHostHighlights: true)
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])

        view.clearSearchHighlights()
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows.allSatisfy { $0.isEmpty })
    }

    /// A search past its time limit shows no highlights, and no search
    /// starts again before the retry time.
    @Test func aSlowSearchShowsNoHighlightsAndWaits() {
        let view = makeView()
        view.feed(text: "foo bar foo")
        view.findNext("foo", scrollToResult: false)
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])

        view.withTerminal { _ in view.search.visibleMatchTimeLimit = 0 }
        view.feed(text: "\r\nfoo")
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows.allSatisfy { $0.isEmpty })
        #expect(snapshot.searchMatchChangedRows == 0...0)

        // In time again, but before the retry time: no search.
        view.withTerminal { _ in view.search.visibleMatchTimeLimit = 10_000_000_000 }
        let before = translatedRows(view)
        view.feed(text: "\r\nfoo")
        refresh(snapshot, from: view)
        #expect(translatedRows(view) == before)
        #expect(snapshot.searchMatchRows.allSatisfy { $0.isEmpty })
    }

    /// The retry wait doubles after each late search for the same pattern,
    /// to a maximum. A different pattern, or a search in time, sets it back.
    @Test func thePatternThatIsAlwaysSlowWaitsLonger() {
        let view = makeView()
        view.feed(text: "foo bar foo")
        view.findNext("foo", scrollToResult: false)
        view.withTerminal { _ in view.search.visibleMatchTimeLimit = 0 }
        let snapshot = TerminalSnapshot()
        func lateSearchDelay() -> UInt64? {
            snapshot.searchRetryTime = 0
            refresh(snapshot, from: view)
            return snapshot.takeSearchRetryDelay()
        }
        #expect(lateSearchDelay() == 500_000_000)
        #expect(lateSearchDelay() == 1_000_000_000)
        #expect(lateSearchDelay() == 2_000_000_000)
        #expect(lateSearchDelay() == 3_000_000_000)
        #expect(lateSearchDelay() == 3_000_000_000)

        // A different pattern does not wait, and starts at the first value.
        view.findNext("bar", scrollToResult: false)
        refresh(snapshot, from: view)
        #expect(snapshot.takeSearchRetryDelay() == 500_000_000)
        #expect(lateSearchDelay() == 1_000_000_000)

        // A search in time sets the wait back.
        removeTimeLimit(view)
        #expect(lateSearchDelay() == nil)
        #expect(snapshot.searchMatchRows[0] == [4..<7])
        view.withTerminal { _ in view.search.visibleMatchTimeLimit = 0 }
        view.feed(text: "\r\nbar")
        refresh(snapshot, from: view)
        #expect(snapshot.takeSearchRetryDelay() == 500_000_000)
    }

    @Test func aFrozenFrameDoesNoSearch() {
        let view = makeView()
        view.feed(text: "foo bar foo")
        view.findNext("foo", scrollToResult: false)
        let snapshot = TerminalSnapshot()
        view.feed(text: "\u{1b}[?2026h")
        let before = translatedRows(view)

        #expect(refresh(snapshot, from: view) == .frozen)
        #expect(translatedRows(view) == before)

        view.feed(text: "\u{1b}[?2026l")
        #expect(refresh(snapshot, from: view) == .refreshed)
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])
    }

    @Test func clearSearchHighlightsKeepsTheSelection() {
        let view = makeView()
        view.feed(text: "foo bar foo")
        view.findNext("foo", scrollToResult: false)
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        #expect(!snapshot.searchMatchRows[0].isEmpty)

        view.clearSearchHighlights()
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows.allSatisfy { $0.isEmpty })
        #expect(view.getSelection() == "foo")

        // The next find continues from the current match and shows them again.
        #expect(view.findNext("foo", scrollToResult: false))
        #expect(view.withTerminal { _ in view.selection.start } == Position(col: 8, row: 0))
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows[0] == [0..<3, 8..<11])

        view.clearSearch()
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows.allSatisfy { $0.isEmpty })
        #expect(!view.withTerminal { _ in view.selection.active })
    }

    @Test func aResizeGivesTheRangesOfTheNewLayout() {
        let view = makeView()
        view.feed(text: "needle\r\n" + String(repeating: "x", count: 17) + "needle")
        view.findNext("needle", scrollToResult: false)
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        #expect(snapshot.searchMatchRows[0] == [0..<6])
        #expect(snapshot.searchMatchRows[1] == [17..<23])

        view.resize(cols: 20, rows: 10)
        refresh(snapshot, from: view)
        #expect(snapshot.cols == 20)
        // The ranges are those of a new search of the new layout, and no
        // range of the old layout stays.
        let expected = view.withTerminal { terminal in
            SearchService(terminal: terminal).visibleMatches(
                term: "needle", options: SearchOptions(), firstRow: terminal.displayBuffer.yDisp,
                rowCount: terminal.rows)
        }
        #expect(snapshot.searchMatchRows == expected)
        #expect(snapshot.searchMatchRows[0] == [0..<6])
        #expect(snapshot.searchMatchRows.joined().allSatisfy { $0.upperBound <= 20 })
    }

    // MARK: - Attributes

    @Test func matchCellsGetTheMatchColors() {
        let view = makeView()
        view.feed(text: "foo bar foo")
        view.findNext("foo", scrollToResult: false)
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)

        // The current match is the selection, and the selection has priority.
        let current = attributes(snapshot, view: view, row: 0, column: 0)
        #expect(sameColor(current[.selectionBackgroundColor], view.selectedTextBackgroundColor))

        let match = attributes(snapshot, view: view, row: 0, column: 9)
        #expect(sameColor(match[.selectionBackgroundColor], Self.matchColor))
        #expect(sameColor(match[.foregroundColor], .black), "the default match text color is black")

        let plain = attributes(snapshot, view: view, row: 0, column: 5)
        #expect(plain[.selectionBackgroundColor] == nil)

        view.searchMatchForegroundColor = nil
        let kept = attributes(snapshot, view: view, row: 0, column: 9)
        #expect(sameColor(kept[.selectionBackgroundColor], Self.matchColor))
        #expect(sameColor(kept[.foregroundColor], plain[.foregroundColor] as! NSColor))

        view.searchMatchForegroundColor = .blue
        #expect(sameColor(attributes(snapshot, view: view, row: 0, column: 9)[.foregroundColor], .blue))
    }

    @Test func thePlainRowPathGetsTheSameColors() throws {
        let view = makeView()
        view.feed(text: "foo bar foo")
        view.findNext("foo", scrollToResult: false)
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)

        let row = try #require(SnapshotTextBuilder().plainRow(
            row: snapshot.rows[0], absoluteRow: snapshot.firstRow, context: context))
        let highlighted = row.runs.filter { $0.style.selectionBackground != nil }
        #expect(highlighted.map { $0.start..<$0.end } == [0..<3, 8..<11])
        #expect(sameColor(highlighted[0].style.selectionBackground, view.selectedTextBackgroundColor))
        #expect(sameColor(highlighted[1].style.selectionBackground, Self.matchColor))
    }

    @Test func aTranslucentBackgroundCompositesTheMatchColor() {
        let view = makeView()
        view.nativeBackgroundColor = .black
        view.backgroundOpacity = 0.4
        view.translucentCellBackgrounds = true
        view.searchMatchBackgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), style: .empty,
                                            ansiColors: view.withTerminal { $0.ansiColors }, cols: 40, rows: 25)
        // As the selection fill: 0.5 white over 0.4 black.
        let fill = context.searchMatchFillColor!.usingColorSpace(.sRGB)!
        #expect(abs(fill.alphaComponent - 0.7) < 0.001)
        #expect(abs(fill.redComponent - 0.5 / 0.7) < 0.001)
    }

    // MARK: - Frames

    /// A match on rows 1 and 2. Output then changes only row 2 and the match
    /// goes away. Row 1 has no new content, but its highlight must go, so the
    /// Core Graphics region has rows 1 and 2 (and the row below, as for all
    /// row regions), not the full view. The change notification still reports
    /// only the row with new content.
    @Test func aMatchThatGoesAwayRedrawsItsOtherRow() async throws {
        let (view, source, driver) = makeDrivenView()
        defer { driver.invalidate() }
        view.notifyUpdateChanges = true

        // Row 0 holds the current match, which keeps the selection off the
        // rows under test.
        let cols = cols(view)
        view.feed(text: "needle\r\n" + String(repeating: "x", count: cols - 3) + "needle")
        #expect(view.findNext("needle", scrollToResult: false))
        await drain(); source.tick(); await drain()
        var shown = view.renderOwner.inspection().searchMatchRows
        #expect(shown[1] == [(cols - 3)..<cols])
        #expect(shown[2] == [0..<3])

        view.feed(text: "\rzzz")
        await drain()
        let prepared = try #require(view.prepareFrame(viewState: FrameViewState(view: view)))
        let cellHeight = view.cellDimension.height
        #expect(prepared.region == CGRect(x: 0, y: view.frame.height - 4 * cellHeight,
                                          width: view.bounds.width, height: 3 * cellHeight))
        #expect(prepared.mainEffects.rangeChanged == FrameChangedRange(start: 2, end: 2))

        shown = view.renderOwner.inspection().searchMatchRows
        #expect(shown[1] == [])
        #expect(shown[2] == [])
        #expect(view.renderOwner.inspection().selectionActive, "the current match is not changed")
    }

    @Test func findAndClearReachTheFrame() async throws {
        let (view, source, driver) = makeDrivenView()
        defer { driver.invalidate() }
        view.feed(text: "foo bar foo")
        await drain(); source.tick(); await drain()

        // No explicit markDirty: the find alone must wake the driver.
        view.findNext("foo", scrollToResult: false)
        await drain(); source.tick(); await drain()
        #expect(view.renderOwner.inspection().searchMatchRows[0] == [0..<3, 8..<11])

        view.clearSearchHighlights()
        await drain()
        // Only row 0 had highlights: the region is that row and the row below.
        let prepared = try #require(view.prepareFrame(viewState: FrameViewState(view: view)))
        let cellHeight = view.cellDimension.height
        #expect(prepared.region == CGRect(x: 0, y: view.frame.height - 2 * cellHeight,
                                          width: view.bounds.width, height: 2 * cellHeight))
        #expect(view.renderOwner.inspection().searchMatchRows.allSatisfy { $0.isEmpty })

        view.findNext("foo", scrollToResult: false)
        await drain(); source.tick(); await drain()
        view.highlightsAllSearchMatches = false
        await drain(); source.tick(); await drain()
        #expect(view.renderOwner.inspection().searchMatchRows.allSatisfy { $0.isEmpty })
    }

    /// A late search on a screen that then gets no output: the frame asks
    /// for one more frame after the retry time, and that frame shows the
    /// highlights.
    @Test func aSlowSearchIsTriedAgainOnAnIdleScreen() async throws {
        let (view, source, driver) = makeDrivenView()
        defer { driver.invalidate() }
        view.feed(text: "foo bar foo")
        view.withTerminal { _ in view.search.visibleMatchTimeLimit = 0 }
        view.findNext("foo", scrollToResult: false)
        await drain(); source.tick(); await drain()
        #expect(view.renderOwner.inspection().searchMatchRows.allSatisfy { $0.isEmpty })

        // The search is in time again, but no search starts before the
        // retry time.
        removeTimeLimit(view)
        view.frameDriver.markDirty()
        await drain(); source.tick(); await drain()
        #expect(view.renderOwner.inspection().searchMatchRows.allSatisfy { $0.isEmpty }, "before the retry time")

        // No call from the test makes the view dirty from here: only the
        // frame that the view asked for after the delay.
        try await Task.sleep(nanoseconds: TerminalSnapshot.searchRetryInterval + 200_000_000)
        await drain(); source.tick(); await drain()
        #expect(view.renderOwner.inspection().searchMatchRows[0] == [0..<3, 8..<11])
    }

    // MARK: - Pixels

    /// "a", spaces, "b" on each row: the center of the view is a space that
    /// the regex matches, so the pixel is the match color with no glyph ink.
    private func makePixelView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        view.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        view.highlightsAllSearchMatches = true
        view.searchMatchBackgroundColor = Self.matchColor
        removeTimeLimit(view)
        let cols = view.withTerminal { $0.cols }
        let row = "a" + String(repeating: " ", count: cols - 2) + "b"
        view.feed(text: Array(repeating: row, count: 10).joined(separator: "\r\n"))
        return view
    }

    private func coreGraphicsCenterPixel(_ view: TerminalView) -> [UInt8] {
        let width = 120
        let height = 120
        if let state = view.captureFrameViewState() {
            _ = view.prepareFrame(viewState: state)
        }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            if let background = view.layer?.backgroundColor {
                context.setFillColor(background)
                context.fill(bounds)
            }
            context.draw(rep.cgImage!, in: bounds)
        }
        let offset = (60 * width + 60) * 4
        return Array(pixels[offset..<(offset + 4)])
    }

    @Test func coreGraphicsPaintsTheMatchColor() {
        let view = makePixelView()
        let before = coreGraphicsCenterPixel(view)
        #expect(before[0] < 20, "no pattern: the default background")

        #expect(view.findNext(" +", options: SearchOptions(regex: true), scrollToResult: false))
        let highlighted = coreGraphicsCenterPixel(view)
        #expect(highlighted[0] > 230 && highlighted[1] < 40 && highlighted[2] < 40, "\(highlighted)")

        view.clearSearch()
        #expect(coreGraphicsCenterPixel(view) == before)
    }

#if canImport(MetalKit)
    private func metalCenterPixel(_ view: TerminalView) -> [UInt8]? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = device
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = view.bounds.size
        guard let renderer = try? MetalTerminalRenderer(target: target) else { return nil }
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        guard view.renderSnapshotForMetal(renderer: renderer, target: target),
              let texture = renderer.lastRenderedTexture,
              texture.width > 0, texture.height > 0 else { return nil }
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        let offset = (texture.height / 2) * bytesPerRow + (texture.width / 2) * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    /// BGRA.
    @Test(.enabled(if: MetalRowCacheTests.metalIsUsable)) func metalPaintsTheMatchColor() throws {
        let view = makePixelView()
        let before = try #require(metalCenterPixel(view))
        #expect(before[2] < 20)

        #expect(view.findNext(" +", options: SearchOptions(regex: true), scrollToResult: false))
        let highlighted = try #require(metalCenterPixel(view))
        #expect(highlighted[2] > 230 && highlighted[1] < 40 && highlighted[0] < 40, "\(highlighted)")
    }
#endif
}

#if canImport(MetalKit)
import Metal
import MetalKit
#endif
#endif
