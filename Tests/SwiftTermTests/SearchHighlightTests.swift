//
//  SearchHighlightTests.swift
//  SwiftTermTests
//
//  `highlightAllSearchMatches` paints every match of the active search in the
//  search match colors while the current match stays the selection. These
//  tests go through the paths the renderers use: the frame capture, the
//  snapshot style, and both `SnapshotTextBuilder` row builders.
//

#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit
import Testing
#if canImport(MetalKit)
import Metal
import MetalKit
#endif
@testable import SwiftTerm

@Suite("Search match highlights")
@MainActor
struct SearchHighlightTests {
    private func makeView(text: String = "foo bar foo baz foo") -> TerminalView {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: 20, rows: 4, scrollback: 20))
        view.feed(text: text)
        return view
    }

    private func snapshot(_ view: TerminalView) -> TerminalSnapshot {
        let snapshot = TerminalSnapshot()
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        return snapshot
    }

    /// The fill the attributed-string path gives each column of the first row.
    private func fills(_ view: TerminalView) throws -> [NSColor?] {
        let frame = snapshot(view)
        let row = try #require(frame.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: frame)
        let info = view.textBuilder.buildAttributedString(row: row, absoluteRow: frame.firstRow, context: context)
        let joined = NSMutableAttributedString()
        for segment in info.segments { joined.append(segment.attributedString) }
        return (0..<joined.length).map {
            joined.attribute(.selectionBackgroundColor, at: $0, effectiveRange: nil) as? NSColor
        }
    }

    /// The fill the plain (Metal fast) path gives each column of the first row.
    private func plainFills(_ view: TerminalView) throws -> [NSColor?] {
        let frame = snapshot(view)
        let row = try #require(frame.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: frame)
        let plain = try #require(view.textBuilder.plainRow(row: row, absoluteRow: frame.firstRow, context: context))
        var fills: [NSColor?] = Array(repeating: nil, count: context.cols)
        for run in plain.runs {
            for col in run.start..<run.end { fills[col] = run.style.selectionBackground }
        }
        return fills
    }

    @Test func highlightsAreOffByDefault() throws {
        let view = makeView()
        #expect(!view.highlightAllSearchMatches)
        #expect(view.findNext("foo"))
        #expect(view.searchHighlights == .none)
        let fills = try fills(view)
        // The current match is the selection and nothing else is painted.
        #expect(fills[0] == view.selectedTextBackgroundColor)
        #expect(fills[8] == nil)
        #expect(fills[16] == nil)
    }

    @Test func everyMatchIsPaintedAndTheCurrentOneIsTheSelection() throws {
        let view = makeView()
        view.highlightAllSearchMatches = true
        #expect(view.findNext("foo"))
        #expect(view.searchHighlights.ranges(forRow: 0) == [0..<3, 8..<11, 16..<19])

        for fills in try [fills(view), plainFills(view)] {
            #expect(fills[0] == view.selectedTextBackgroundColor)
            #expect(fills[2] == view.selectedTextBackgroundColor)
            #expect(fills[3] == nil)
            #expect(fills[8] == view.searchMatchBackgroundColor)
            #expect(fills[10] == view.searchMatchBackgroundColor)
            #expect(fills[11] == nil)
            #expect(fills[16] == view.searchMatchBackgroundColor)
        }

        // Stepping moves the selection; the other matches keep the match fill.
        #expect(view.findNext("foo"))
        let stepped = try fills(view)
        #expect(stepped[0] == view.searchMatchBackgroundColor)
        #expect(stepped[8] == view.selectedTextBackgroundColor)
        #expect(stepped[16] == view.searchMatchBackgroundColor)
    }

    @Test func matchTextTakesTheSearchMatchForeground() throws {
        let view = makeView()
        view.highlightAllSearchMatches = true
        view.searchMatchForegroundColor = NSColor(srgbRed: 0.2, green: 0.1, blue: 0.9, alpha: 1)
        view.selectedTextForegroundColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)
        #expect(view.findNext("foo"))
        let frame = snapshot(view)
        let row = try #require(frame.rows.first)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: frame)
        let info = view.textBuilder.buildAttributedString(row: row, absoluteRow: frame.firstRow, context: context)
        let joined = NSMutableAttributedString()
        for segment in info.segments { joined.append(segment.attributedString) }
        func rgb(_ color: NSColor?) -> [Int] {
            let c = try! #require(color?.usingColorSpace(.sRGB))
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        #expect(rgb(joined.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor)
                == rgb(view.searchMatchForegroundColor))
        #expect(rgb(joined.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
                == rgb(view.selectedTextForegroundColor))
    }

    @Test func clearSearchRemovesTheHighlights() throws {
        let view = makeView()
        view.highlightAllSearchMatches = true
        #expect(view.findNext("foo"))
        view.clearSearch()
        #expect(view.searchHighlights == .none)
        #expect(try fills(view).allSatisfy { $0 == nil })
    }

    @Test func aTermWithoutMatchesHighlightsNothing() throws {
        let view = makeView()
        view.highlightAllSearchMatches = true
        #expect(view.findNext("foo"))
        #expect(!view.findNext("nothing here"))
        #expect(view.searchHighlights == .none)
    }

    /// Turning the option on after a search highlights that search; off
    /// removes the highlights without touching the selection.
    @Test func togglingTheOptionFollowsTheLastSearch() throws {
        let view = makeView()
        #expect(view.findPrevious("foo", options: SearchOptions(caseSensitive: true)))
        view.highlightAllSearchMatches = true
        #expect(view.searchHighlights.ranges(forRow: 0) == [0..<3, 8..<11, 16..<19])
        view.highlightAllSearchMatches = false
        #expect(view.searchHighlights == .none)
        #expect(view.selection.active)
    }

    @Test func aWrappedMatchIsPaintedOnBothRows() throws {
        // Row 0 is full and ends in "ab"; "cd" wraps onto row 1.
        let view = makeView(text: String(repeating: "x", count: 18) + "abcd")
        view.highlightAllSearchMatches = true
        #expect(view.findNext("abcd"))
        #expect(view.searchHighlights.ranges(forRow: 0) == [18..<20])
        #expect(view.searchHighlights.ranges(forRow: 1) == [0..<2])
    }

    /// New output arrived after the search; the host recounts, and the new
    /// match is highlighted with the others.
    @Test func recountingAfterOutputRefreshesTheHighlights() throws {
        let view = makeView()
        view.highlightAllSearchMatches = true
        #expect(view.findNext("foo"))
        view.feed(text: "\r\nfoo")
        #expect(view.searchHighlights.ranges(forRow: 1) == nil)
        #expect(view.searchMatchSummary("foo").total == 4)
        #expect(view.searchHighlights.ranges(forRow: 1) == [0..<3])
    }

    @Test func matchPositionsListEveryMatchAndTheBufferLength() throws {
        let view = makeView()
        let positions = view.searchMatchPositions("foo")
        #expect(positions.matches == [SearchMatchPosition(row: 0, col: 0, length: 3),
                                      SearchMatchPosition(row: 0, col: 8, length: 3),
                                      SearchMatchPosition(row: 0, col: 16, length: 3)])
        // The buffer holds its rows before any scrollback accrues.
        #expect(positions.lines == 4)
        #expect(view.searchMatchPositions("foo", limit: 2).matches.count == 2)
        #expect(view.searchMatchPositions("").matches.isEmpty)
    }

    /// A changed highlight set changes the snapshot style, which is what makes
    /// the frame repaint every visible row.
    @Test func highlightChangesAreAStyleChange() throws {
        let view = makeView()
        view.highlightAllSearchMatches = true
        let before = snapshot(view)
        #expect(view.findNext("foo"))
        let after = snapshot(view)
        #expect(!before.style.hasSameValue(as: after.style))
        #expect(after.style.searchHighlights == view.searchHighlights)
    }

    /// The marks beside the scroller: a fraction per match of the buffer's
    /// length, the current one named; gone with the highlights.
    @Test func scrollerMarksFollowTheMatches() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 64),
                                font: nil, options: TerminalOptions(cols: 20, rows: 4, scrollback: 100))
        view.highlightAllSearchMatches = true
        // 11 lines: "foo" on rows 0, 5 and 10, so the marks sit at 0, 1/2 and 1.
        view.feed(text: (0..<11).map { $0 % 5 == 0 ? "foo" : "bar" }.joined(separator: "\r\n"))
        #expect(view.searchMarkFractions.matches.isEmpty)
        #expect(view.findPrevious("foo"))
        let marks = view.searchMarkFractions
        #expect(marks.matches == [0, 0.5, 1])
        #expect(marks.current == 1)
        let strip = try #require(view.subviews.first {
            $0.identifier?.rawValue == "SwiftTermSearchMarkStrip" })
        #expect(!strip.isHidden)
        #expect(view.findPrevious("foo"))
        #expect(view.searchMarkFractions.current == 0.5)
        view.clearSearch()
        #expect(view.searchMarkFractions.matches.isEmpty)
        #expect(strip.isHidden)
    }
}

/// The pixels the renderers paint: the second match's cell in the match
/// fill, the current match's in the selection fill, the text between in the
/// default background.
@Suite("Search match highlight pixels")
@MainActor
struct SearchHighlightPixelTests {
    static let matchFill = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
    static let selectionFill = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)

    private func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        view.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        view.searchMatchBackgroundColor = Self.matchFill
        view.selectedTextBackgroundColor = Self.selectionFill
        view.highlightAllSearchMatches = true
        // Spaces match, so every highlighted cell is a bare fill with no glyph over it.
        view.feed(text: "..  ..  ..")
        #expect(view.findNext("  "))
        return view
    }

    /// The center of row 0's cell `col`, in the view's flipped bitmap.
    private func sample(col: Int, view: TerminalView) -> (x: Int, y: Int) {
        (Int((CGFloat(col) + 0.5) * view.cellDimension.width), Int(view.cellDimension.height / 2))
    }

    private func rgb(_ pixel: [UInt8], bgra: Bool) -> [Int] {
        bgra ? [Int(pixel[2]), Int(pixel[1]), Int(pixel[0])] : [Int(pixel[0]), Int(pixel[1]), Int(pixel[2])]
    }

    private func expectFills(_ pixelAt: (Int, Int) -> [UInt8], bgra: Bool, view: TerminalView) {
        func near(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 8 } }
        let current = sample(col: 2, view: view)
        let other = sample(col: 6, view: view)
        let text = sample(col: 4, view: view)
        #expect(near(rgb(pixelAt(current.x, current.y), bgra: bgra), [0, 255, 255]))
        #expect(near(rgb(pixelAt(other.x, other.y), bgra: bgra), [255, 255, 0]))
        #expect(rgb(pixelAt(text.x, text.y), bgra: bgra).max()! < 200, "'.' cell is not a fill")
    }

    @Test func coreGraphicsPaintsEveryMatch() {
        let view = makeView()
        let width = 240, height = 120
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
        expectFills({ x, y in Array(pixels[((y * width + x) * 4)..<((y * width + x) * 4 + 4)]) },
                    bgra: false, view: view)
    }

#if canImport(MetalKit)
    /// The background quads the Metal renderer encodes for row 0: one in the
    /// selection fill over the current match, one in the match fill over the
    /// other, none over the text between.
    @Test func metalEncodesEveryMatchFill() throws {
        let view = makeView()
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let target = TerminalMetalLayerView(frame: view.bounds)
        target.renderDevice = device
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = view.bounds.size
        guard let renderer = try? MetalTerminalRenderer(target: target) else { return }
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesDrawData = true
        guard view.renderSnapshotForMetal(renderer: renderer, target: target),
              let drawData = renderer.lastDrawData, let row = drawData.rows.first else { return }
        var fills: [(x: Float, width: Float, rgb: [Int])] = []
        if let buffer = row.backgroundBuffer {
            let cells = buffer.contents().bindMemory(to: ColorCell.self, capacity: row.backgroundCount)
            for i in 0..<row.backgroundCount {
                let cell = cells[i]
                fills.append((cell.position.x, cell.size.x,
                              [cell.color.x, cell.color.y, cell.color.z].map { Int(($0 * 255).rounded()) }))
            }
        }
        // Quads are in pixels at the frame's rendering scale.
        let cellWidth = Float(view.cellDimension.width * view.metalRenderingScaleFactor())
        func fill(atColumn col: Int) -> [Int]? {
            let x = (Float(col) + 0.5) * cellWidth
            return fills.first { $0.x <= x && x < $0.x + $0.width }?.rgb
        }
        #expect(fill(atColumn: 2) == [0, 255, 255])
        #expect(fill(atColumn: 6) == [255, 255, 0])
        #expect(fill(atColumn: 4) == nil)
    }
#endif
}
#endif
