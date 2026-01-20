#if canImport(AppKit)
import AppKit
import CoreText
import Testing
@testable import SwiftTerm

@MainActor
final class LineLayoutCacheTests {
    private func makeView(cols: Int = 40, rows: Int = 10) -> TerminalView {
        let width = CGFloat(cols) * 8
        let height = CGFloat(rows) * 16
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.resize(cols: cols, rows: rows)
        return view
    }

    private func makeBitmapContext(for view: TerminalView) -> CGContext? {
        CGContext(data: nil,
                  width: Int(view.bounds.width),
                  height: Int(view.bounds.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func withBitmapContext(for view: TerminalView,
                                   perform body: (CGContext) -> Void) {
        guard let context = makeBitmapContext(for: view) else {
            Issue.record("Failed to create CGContext for rendering test")
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }
        body(context)
    }

    private func installCachedLine(
        in view: TerminalView,
        viewportRow: Int = 0,
        text: String = "cache",
        bufferRowOverride: Int? = nil
    ) -> (line: BufferLine, bufferRow: Int, viewportRow: Int) {
        let displayBuffer = view.terminal.displayBuffer
        let bufferRow = bufferRowOverride ?? (displayBuffer.yDisp + viewportRow)
        let cells = text.map { TerminalTestHarness.BufferCell($0) }
        let line = TerminalTestHarness.makeBufferLine(columns: view.terminal.cols, cells: cells)
        displayBuffer.lines[bufferRow] = line
        _ = view.cachedLineInfo(bufferRow: bufferRow, line: line, cols: displayBuffer.cols)
        return (line, bufferRow, viewportRow)
    }

    @Test func testCachedLineInfoStoresEntriesPerLine() {
        let view = makeView()
        let (line, bufferRow, _) = installCachedLine(in: view)
        let key = bufferRow

        guard let entry = view.lineLayoutCache[key] else {
            Issue.record("Expected cached entry for BufferLine after rendering")
            return
        }
        #expect(entry.generation == view.lineLayoutCacheGeneration)

        let info = view.cachedLineInfo(bufferRow: bufferRow, line: line, cols: view.terminal.displayBuffer.cols)
        #expect(info.segments.count == entry.lineInfo.segments.count)
        #expect(view.lineLayoutCache.count == 1)
    }

    @Test func testViewportInvalidationAccountsForScrollbackOffset() {
        let view = makeView(rows: 20)
        view.terminal.displayBuffer.yDisp = 5
        let (_, bufferRow, viewportRow) = installCachedLine(in: view, viewportRow: 2, text: "scroll")
        let key = bufferRow
        #expect(view.lineLayoutCache[key] != nil)

        view.invalidateViewportLineCache(range: viewportRow...viewportRow, buffer: view.terminal.displayBuffer)
        #expect(view.lineLayoutCache[key] == nil)
    }

    @Test func testSelectionChangeInvalidatesCachedRows() {
        let view = makeView(rows: 8)
        let (_, bufferRow, _) = installCachedLine(in: view, text: "select")
        let key = bufferRow
        let start = Position(col: 0, row: bufferRow)
        let end = Position(col: 3, row: bufferRow)
        view.selection?.setSelection(start: start, end: end)

        view.invalidateSelectionLineCache()
        #expect(view.lineLayoutCache[key] == nil)
    }

    @Test func testSelectionChangeInvalidatesMultipleRows() {
        let view = makeView(rows: 8)
        let first = installCachedLine(in: view, viewportRow: 0, text: "r0")
        let second = installCachedLine(in: view, viewportRow: 1, text: "r1")
        let firstKey = first.bufferRow
        let secondKey = second.bufferRow
        view.selection?.setSelection(start: Position(col: 0, row: first.bufferRow),
                                     end: Position(col: 0, row: second.bufferRow))

        view.selectionChanged(source: view.terminal)

        #expect(view.lineLayoutCache[firstKey] == nil)
        #expect(view.lineLayoutCache[secondKey] == nil)
    }

    @Test func testSelectionChangeHandlesReversedRows() {
        let view = makeView(rows: 8)
        let first = installCachedLine(in: view, viewportRow: 0, text: "r0")
        let second = installCachedLine(in: view, viewportRow: 1, text: "r1")
        let firstKey = first.bufferRow
        let secondKey = second.bufferRow
        view.selection?.setSelection(start: Position(col: 0, row: second.bufferRow),
                                     end: Position(col: 0, row: first.bufferRow))

        view.selectionChanged(source: view.terminal)

        #expect(view.lineLayoutCache[firstKey] == nil)
        #expect(view.lineLayoutCache[secondKey] == nil)
    }

    @Test func testSelectionChangeNoopWhenSelectionInactive() {
        let view = makeView(rows: 6)
        let (_, bufferRow, _) = installCachedLine(in: view, text: "inactive")
        let key = bufferRow
        view.selection?.active = false

        view.selectionChanged(source: view.terminal)

        #expect(view.lineLayoutCache[key] != nil)
    }

    @Test func testSelectionChangeInvalidatesPreviousSelectionRange() {
        let view = makeView(rows: 8)
        let first = installCachedLine(in: view, viewportRow: 0, text: "r0")
        let second = installCachedLine(in: view, viewportRow: 1, text: "r1")
        let firstKey = first.bufferRow
        let secondKey = second.bufferRow

        view.selection?.setSelection(start: Position(col: 0, row: first.bufferRow),
                                     end: Position(col: 0, row: first.bufferRow))
        view.selectionChanged(source: view.terminal)
        #expect(view.lineLayoutCache[firstKey] == nil)
        #expect(view.lineLayoutCache[secondKey] != nil)

        _ = view.cachedLineInfo(bufferRow: first.bufferRow, line: first.line, cols: view.terminal.displayBuffer.cols)
        _ = view.cachedLineInfo(bufferRow: second.bufferRow, line: second.line, cols: view.terminal.displayBuffer.cols)
        #expect(view.lineLayoutCache[firstKey] != nil)
        #expect(view.lineLayoutCache[secondKey] != nil)

        view.selection?.setSelection(start: Position(col: 0, row: second.bufferRow),
                                     end: Position(col: 0, row: second.bufferRow))
        view.selectionChanged(source: view.terminal)

        #expect(view.lineLayoutCache[firstKey] == nil)
        #expect(view.lineLayoutCache[secondKey] == nil)
    }

    @Test func testSelectionClearingInvalidatesPreviousSelectionRange() {
        let view = makeView(rows: 8)
        let (line, bufferRow, _) = installCachedLine(in: view, text: "sel")
        let key = bufferRow

        view.selection?.setSelection(start: Position(col: 0, row: bufferRow),
                                     end: Position(col: 0, row: bufferRow))
        view.selectionChanged(source: view.terminal)
        #expect(view.lineLayoutCache[key] == nil)

        _ = view.cachedLineInfo(bufferRow: bufferRow, line: line, cols: view.terminal.displayBuffer.cols)
        #expect(view.lineLayoutCache[key] != nil)

        view.selectNone()
        view.selectionChanged(source: view.terminal)

        #expect(view.lineLayoutCache[key] == nil)
    }

    @Test func testResetLineLayoutCacheClearsEntriesAndBumpsGeneration() {
        let view = makeView(rows: 6)
        let (_, bufferRow, _) = installCachedLine(in: view, text: "reset")
        let key = bufferRow
        let previousGeneration = view.lineLayoutCacheGeneration

        view.resetLineLayoutCache()

        #expect(view.lineLayoutCache[key] == nil)
        #expect(view.lineLayoutCache.isEmpty)
        #expect(view.lineLayoutCacheGeneration != previousGeneration)
    }

    @Test func testStaleGenerationTriggersCacheMiss() {
        let view = makeView(rows: 4)
        let (line, bufferRow, _) = installCachedLine(in: view, text: "fresh")
        let key = bufferRow
        #expect(view.lineLayoutCache[key] != nil)

        view.resetLineLayoutCache()
        let staleInfo = ViewLineInfo(segments: [], images: nil, kittyPlaceholders: [])
        let staleGeneration = view.lineLayoutCacheGeneration &- 1
        view.lineLayoutCache[key] = LineCacheEntry(generation: staleGeneration, lineInfo: staleInfo, ctLines: [])

        let info = view.cachedLineInfo(bufferRow: bufferRow, line: line, cols: view.terminal.displayBuffer.cols)
        #expect(!info.segments.isEmpty)
        #expect(view.lineLayoutCache[key]?.generation == view.lineLayoutCacheGeneration)
    }

    @Test func testUpdateDisplayInvalidatesViewportAndScrollInvariantLines() {
        let view = makeView(rows: 5)
        for i in 0..<20 {
            view.terminal.feed(text: "row\(i)\r\n")
        }
        let displayBuffer = view.terminal.displayBuffer
        let visibleBaseRow = displayBuffer.yDisp
        #expect(visibleBaseRow > 0)

        let (_, visibleBufferRow, _) = installCachedLine(in: view, viewportRow: 0, text: "visible")
        let visibleKey = visibleBufferRow

        let offscreenRow = max(0, visibleBaseRow - 1)
        #expect(offscreenRow < visibleBaseRow)
        let (_, offscreenBufferRow, _) = installCachedLine(in: view, viewportRow: 0, text: "offscreen", bufferRowOverride: offscreenRow)
        let offscreenKey = offscreenBufferRow

        view.terminal.refreshStart = 0
        view.terminal.refreshEnd = 0
        view.terminal.scrollInvariantRefreshStart = offscreenRow
        view.terminal.scrollInvariantRefreshEnd = offscreenRow

        view.updateDisplay(notifyAccessibility: false)

        #expect(view.lineLayoutCache[visibleKey] == nil)
        #expect(view.lineLayoutCache[offscreenKey] == nil)
    }

    @Test func testUpdateDisplayInvalidatesViewportWhenScrollInvariantNil() {
        let view = makeView(rows: 6)
        let (_, bufferRow, _) = installCachedLine(in: view, viewportRow: 0, text: "dirty")
        let key = bufferRow

        view.terminal.refreshStart = 0
        view.terminal.refreshEnd = 0

        view.updateDisplay(notifyAccessibility: false)

        #expect(view.lineLayoutCache[key] == nil)
    }

    @Test func testViewportInvalidationIgnoresOutOfBoundsRange() {
        let view = makeView(rows: 6)
        let (_, bufferRow, viewportRow) = installCachedLine(in: view, viewportRow: 0, text: "stable")
        let key = bufferRow
        let buffer = view.terminal.displayBuffer

        view.invalidateViewportLineCache(range: (viewportRow + 100)...(viewportRow + 101), buffer: buffer)

        #expect(view.lineLayoutCache[key] != nil)
    }

    @Test func testViewportInvalidationClampsNegativeRange() {
        let view = makeView(rows: 6)
        let (_, bufferRow, viewportRow) = installCachedLine(in: view, viewportRow: 0, text: "neg")
        let key = bufferRow
        view.invalidateViewportLineCache(range: -3...viewportRow, buffer: view.terminal.displayBuffer)
        #expect(view.lineLayoutCache[key] == nil)
    }

    @Test func testSelectionChangedDelegateClearsCache() {
        let view = makeView(rows: 6)
        let (_, bufferRow, _) = installCachedLine(in: view, text: "delegate")
        let key = bufferRow
        let start = Position(col: 0, row: bufferRow)
        let end = Position(col: 2, row: bufferRow)
        view.selection?.setSelection(start: start, end: end)

        view.selectionChanged(source: view.terminal)

        #expect(view.lineLayoutCache[key] == nil)
    }

    @Test func testBufferActivatedDelegateResetsCache() {
        let view = makeView(rows: 6)
        let (_, bufferRow, _) = installCachedLine(in: view, text: "buffer")
        let key = bufferRow
        #expect(view.lineLayoutCache[key] != nil)

        view.bufferActivated(source: view.terminal)

        #expect(view.lineLayoutCache.isEmpty)
    }

    @Test func testProcessSizeChangeResetsCache() {
        let view = makeView(rows: 6)
        let (_, bufferRow, _) = installCachedLine(in: view, text: "resize")
        let key = bufferRow
        let originalSize = view.bounds.size
        let newSize = CGSize(width: originalSize.width, height: originalSize.height + view.cellDimension.height)

        _ = view.processSizeChange(newSize: newSize)

        #expect(view.lineLayoutCache[key] == nil)
        #expect(view.lineLayoutCache.isEmpty)
    }

    @Test func testColorsChangedResetsCache() {
        let view = makeView(rows: 4)
        let (_, bufferRow, _) = installCachedLine(in: view, text: "colors")
        let key = bufferRow
        #expect(view.lineLayoutCache[key] != nil)

        view.colorsChanged()

        #expect(view.lineLayoutCache.isEmpty)
    }

    @Test func testMultiLineBufferInvalidationRemovesAllRows() {
        let view = makeView(rows: 8)
        let first = installCachedLine(in: view, viewportRow: 0, text: "row0")
        let second = installCachedLine(in: view, viewportRow: 1, text: "row1")

        view.invalidateLineLayoutCache(bufferRows: first.bufferRow...second.bufferRow)

        #expect(view.lineLayoutCache[first.bufferRow] == nil)
        #expect(view.lineLayoutCache[second.bufferRow] == nil)
    }

    @Test func testInvalidateLineLayoutCacheClampsRequestedRange() {
        let view = makeView(rows: 6)
        let first = installCachedLine(in: view, viewportRow: 0, text: "row0")
        let second = installCachedLine(in: view, viewportRow: 1, text: "row1")

        view.invalidateLineLayoutCache(bufferRows: (first.bufferRow - 10)...(second.bufferRow + 10))

        #expect(view.lineLayoutCache.isEmpty)
    }

    @Test func testInvalidateLineLayoutCacheNoopWhenCacheIsEmpty() {
        let view = makeView(rows: 4)
        view.lineLayoutCache.removeAll()

        view.invalidateLineLayoutCache(bufferRows: -5...5)

        #expect(view.lineLayoutCache.isEmpty)
    }

    @Test func testInvalidateLineLayoutCacheHandlesEmptyBuffer() {
        let view = makeView(rows: 4)
        let (_, bufferRow, _) = installCachedLine(in: view, text: "rows")
        let key = bufferRow
        view.terminal.displayBuffer.lines.count = 0

        view.invalidateLineLayoutCache(bufferRows: bufferRow...bufferRow)

        #expect(view.lineLayoutCache[key] == nil)
    }

    @Test func testLineLayoutCacheMetricsCaptureViewportInvalidationRanges() {
        let view = makeView(rows: 4)
        let (_, _, viewportRow) = installCachedLine(in: view, viewportRow: 0, text: "metrics")
        let buffer = view.terminal.displayBuffer

        view.invalidateViewportLineCache(range: viewportRow...viewportRow, buffer: buffer)
        let snapshot = view.lineLayoutCacheMetricsSnapshot()
        #expect(snapshot.viewportInvalidations == 1)
        let expectedRow = buffer.yDisp + viewportRow
        #expect(snapshot.lastViewportRange == expectedRow...expectedRow)
    }

    @Test func testLineLayoutCacheMetricsCaptureSelectionInvalidations() {
        let view = makeView(rows: 4)
        let (_, bufferRow, _) = installCachedLine(in: view, viewportRow: 0, text: "selMetrics")
        view.selection?.setSelection(start: Position(col: 0, row: bufferRow),
                                     end: Position(col: 0, row: bufferRow))

        view.invalidateSelectionLineCache()
        let snapshot = view.lineLayoutCacheMetricsSnapshot()
        #expect(snapshot.selectionInvalidations == 1)
        #expect(snapshot.lastSelectionRange == bufferRow...bufferRow)
    }

    @Test func testLineLayoutCacheMetricsReportHitRate() {
        let view = makeView(rows: 4)
        let (line, bufferRow, _) = installCachedLine(in: view, viewportRow: 0, text: "rate")

        view.resetLineLayoutCacheStats()
        view.resetLineLayoutCache()
        _ = view.cachedLineInfo(bufferRow: bufferRow, line: line, cols: view.terminal.displayBuffer.cols)
        _ = view.cachedLineInfo(bufferRow: bufferRow, line: line, cols: view.terminal.displayBuffer.cols)

        let snapshot = view.lineLayoutCacheMetricsSnapshot()
        #expect(snapshot.misses == 1)
        #expect(snapshot.hits == 1)
        guard let hitRate = snapshot.hitRate else {
            Issue.record("Expected hit rate to be available after lookups")
            return
        }
        #expect(hitRate == 0.5)
    }

    @Test func testSteadyStateRenderingMaintainsHighCacheHitRate() {
        let view = makeView(cols: 80, rows: 24)
        for i in 0..<240 {
            view.terminal.feed(text: "render\(i)\r\n")
        }
        let dirtyRect = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height)
        view.resetLineLayoutCache()
        view.resetLineLayoutCacheStats()

        withBitmapContext(for: view) { context in
            let iterations = 30
            for _ in 0..<iterations {
                view.drawTerminalContents(dirtyRect: dirtyRect,
                                          context: context,
                                          bufferOffset: view.terminal.displayBuffer.yDisp)
            }
        }

        let snapshot = view.lineLayoutCacheMetricsSnapshot()
        guard let hitRate = snapshot.hitRate else {
            Issue.record("Expected hit rate after repeated rendering")
            return
        }
        #expect(hitRate > 0.9)
        #expect(snapshot.hits > snapshot.misses * 5)
    }

    @Test func testCachedLineInfoPrecomputesCTLinesForSegments() {
        let view = makeView(rows: 4)
        let (line, bufferRow, _) = installCachedLine(in: view, text: "ctline")

        let info = view.cachedLineInfo(bufferRow: bufferRow, line: line, cols: view.terminal.displayBuffer.cols)

        guard let entry = view.cachedLineLayoutEntry(bufferRow: bufferRow) else {
            Issue.record("Expected cached entry with CTLines")
            return
        }
        #expect(entry.ctLines.count == info.segments.count)
        for (index, ctline) in entry.ctLines.enumerated() {
            let glyphCount = CTLineGetGlyphCount(ctline)
            let segment = info.segments[index]
            #expect(glyphCount > 0 || segment.attributedString.length == 0)
        }
    }

#if DEBUG
    @Test func testCachedLineInfoRecordsHitsAndMisses() {
        let view = makeView(rows: 4)
        view.resetLineLayoutCacheStats()
        let displayBuffer = view.terminal.displayBuffer
        let line = TerminalTestHarness.makeBufferLine(columns: view.terminal.cols, cells: "stats".map { TerminalTestHarness.BufferCell($0) })
        let bufferRow = displayBuffer.yDisp
        displayBuffer.lines[bufferRow] = line

        view.lineLayoutCache.removeAll()
        var stats = view.lineLayoutCacheStats()
        #expect(stats.hits == 0)
        #expect(stats.misses == 0)

        _ = view.cachedLineInfo(bufferRow: bufferRow, line: line, cols: displayBuffer.cols)
        stats = view.lineLayoutCacheStats()
        #expect(stats.misses == 1)
        #expect(stats.hits == 0)

        _ = view.cachedLineInfo(bufferRow: bufferRow, line: line, cols: displayBuffer.cols)
        stats = view.lineLayoutCacheStats()
        #expect(stats.misses == 1)
        #expect(stats.hits == 1)
    }

    @Test func testDrawTerminalContentsReportsCacheHitsOnSecondPass() {
        let view = makeView(rows: 4)
        view.resetLineLayoutCache()
        view.resetLineLayoutCacheStats()
        let displayBuffer = view.terminal.displayBuffer
        let line = TerminalTestHarness.makeBufferLine(columns: view.terminal.cols, cells: "draw".map { TerminalTestHarness.BufferCell($0) })
        displayBuffer.lines[displayBuffer.yDisp] = line
        let dirtyRect = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.cellDimension.height)

        withBitmapContext(for: view) { context in
            view.drawTerminalContents(dirtyRect: dirtyRect, context: context, bufferOffset: view.terminal.displayBuffer.yDisp)
            var stats = view.lineLayoutCacheStats()
            #expect(stats.misses == 1)
            #expect(stats.hits == 0)

            view.drawTerminalContents(dirtyRect: dirtyRect, context: context, bufferOffset: view.terminal.displayBuffer.yDisp)
            stats = view.lineLayoutCacheStats()
            #expect(stats.misses == 1)
            #expect(stats.hits >= 1)
        }
    }
#endif
    @Test func testInvalidateLineLayoutCacheIgnoresNonOverlappingRange() {
        let view = makeView(rows: 6)
        let (_, bufferRow, _) = installCachedLine(in: view, text: "stay")
        let key = bufferRow
        let high = bufferRow + 200
        view.invalidateLineLayoutCache(bufferRows: high...high + 5)

        #expect(view.lineLayoutCache[key] != nil)
    }

}
#endif
