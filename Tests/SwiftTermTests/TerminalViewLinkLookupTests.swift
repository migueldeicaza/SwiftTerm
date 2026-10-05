#if os(macOS) || os(iOS) || os(visionOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Testing
@testable import SwiftTerm

@Suite(.serialized)
@MainActor
struct TerminalViewLinkLookupTests {
    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
    }

    private func feed(_ text: String, to view: TerminalView) {
        view.withTerminal { $0.feed(text: text) }
    }

    private func point(_ view: TerminalView, col: Int, bufferRow: Int = 0) -> CGPoint {
        let size = view.cellSize
        #if os(macOS)
        let screenRow = view.withTerminal { bufferRow - $0.displayBuffer.yDisp }
        return CGPoint(x: (CGFloat(col) + 0.5) * size.width,
                       y: view.frame.height - (CGFloat(screenRow) + 0.5) * size.height)
        #else
        return CGPoint(x: (CGFloat(col) + 0.5) * size.width,
                       y: (CGFloat(bufferRow) + 0.5) * size.height)
        #endif
    }

    @Test func explicitLinkReturnsURLAndParameters() throws {
        let view = makeView()
        let url = "https://example.com/path;part?x=1;two"
        feed("\u{1b}]8;id=record:foo=bar;\(url)\u{07}label\u{1b}]8;;\u{07}", to: view)

        let match = try #require(view.link(at: point(view, col: 2)))
        #expect(match.link == url)
        #expect(match.params == ["id": "record", "foo": "bar"])
        #expect(view.link(at: point(view, col: 5)) == nil)
    }

    @Test func bothCellsOfWideCharacterReturnLinkMetadata() throws {
        let view = makeView()
        feed("\u{1b}]8;id=wide;https://wide.example\u{07}界\u{1b}]8;;\u{07}", to: view)

        for col in 0...1 {
            let match = try #require(view.link(at: point(view, col: col)))
            #expect(match.link == "https://wide.example")
            #expect(match.params == ["id": "wide"])
        }
        #expect(view.link(at: point(view, col: 2)) == nil)
    }

    @Test func implicitLookupRequiresItsModeAndReturnsEmptyParameters() throws {
        let view = makeView()
        feed("https://example.com tail", to: view)
        let location = point(view, col: 5)

        #expect(view.link(at: location) == nil)
        let match = try #require(view.link(at: location, mode: .explicitAndImplicit))
        #expect(match.link == "https://example.com")
        #expect(match.params.isEmpty)
        #expect(view.link(at: point(view, col: 19), mode: .explicitAndImplicit) == nil)
        #expect(view.link(at: point(view, col: 0, bufferRow: 1), mode: .explicitAndImplicit) == nil)
    }

    @Test func explicitLinkTakesPrecedenceAndDoesNotDependOnViewSettings() throws {
        let view = makeView()
        feed("\u{1b}]8;id=explicit;https://target.example\u{07}https://label.example\u{1b}]8;;\u{07}", to: view)
        view.linkReporting = .none
        view.commandActive = false

        for highlight in [LinkHighlightMode.hover, .hoverWithModifier, .always, .alwaysWithModifier] {
            view.linkHighlightMode = highlight
            let match = try #require(view.link(at: point(view, col: 8), mode: .explicitAndImplicit))
            #expect(match.link == "https://target.example")
            #expect(match.params == ["id": "explicit"])
            #expect(view.linkHighlightRange == nil)
        }
    }

    @Test func gridPositionUsesCurrentCellMetrics() {
        let view = makeView()
        for size in [CGFloat(12), CGFloat(22)] {
            #if os(macOS)
            view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            #else
            view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            #endif
            #expect(view.cellSize.width > 0)
            #expect(view.cellSize.height > 0)
            #expect(view.cellSize == view.cellDimension)
            #expect(view.gridPosition(at: point(view, col: 3, bufferRow: 2)) == Position(col: 3, row: 2))
        }
    }

    @Test func lookupUsesScrolledDisplayBuffer() throws {
        let view = makeView()
        let rows = view.withTerminal { $0.rows }
        feed("\u{1b}]8;id=old;https://old.example\u{07}old\u{1b}]8;;\u{07}\r\n"
             + String(repeating: "next\r\n", count: rows + 2), to: view)
        #expect(view.withTerminal { $0.displayBuffer.yDisp } > 0)
        #if os(macOS)
        view.scrollTo(row: 0, notifyAccessibility: false)
        #else
        view.contentOffset = .zero
        #endif

        let match = try #require(view.link(at: point(view, col: 1)))
        #expect(match.link == "https://old.example")
        #expect(match.params == ["id": "old"])
        #expect(view.gridPosition(at: point(view, col: 1)) == Position(col: 1, row: 0))
    }

    @Test func lookupUsesAlternateBuffer() throws {
        let view = makeView()
        feed("\u{1b}]8;id=normal;https://normal.example\u{07}normal\u{1b}]8;;\u{07}", to: view)
        feed("\u{1b}[?1049h\u{1b}[H\u{1b}]8;id=alternate;https://alternate.example\u{07}alternate\u{1b}]8;;\u{07}", to: view)

        let alternate = try #require(view.link(at: point(view, col: 1)))
        #expect(alternate.link == "https://alternate.example")
        #expect(alternate.params == ["id": "alternate"])
        feed("\u{1b}[?1049l", to: view)
        let normal = try #require(view.link(at: point(view, col: 1)))
        #expect(normal.link == "https://normal.example")
        #expect(normal.params == ["id": "normal"])
    }

    @Test func bidiVisualCellReturnsLogicalCellMetadata() throws {
        let view = makeView()
        feed("\u{1b}]8;id=rtl;https://rtl.example\u{07}שלום\u{1b}]8;;\u{07}", to: view)
        let visualCol = try view.withTerminal { terminal in
            let layout = try #require(TerminalBidi.layout(
                row: 0, buffer: terminal.displayBuffer, cols: terminal.cols,
                terminal: terminal, font: view.fontSet.normal, hostPolicy: view.bidiHostPolicy))
            return layout.logicalToVisualCol[0]
        }
        #expect(visualCol != 0)
        let location = point(view, col: visualCol)
        #expect(view.gridPosition(at: location) == Position(col: 0, row: 0))
        let match = try #require(view.link(at: location))
        #expect(match.link == "https://rtl.example")
        #expect(match.params == ["id": "rtl"])
    }

    @Test func parameterValuesKeepEqualsSignsAndDropEmptyValues() throws {
        let view = makeView()
        feed("\u{1b}]8;id=YWJj==:k=a=b:=empty:e=;https://equals.example\u{07}label\u{1b}]8;;\u{07}", to: view)

        let match = try #require(view.link(at: point(view, col: 1)))
        #expect(match.link == "https://equals.example")
        #expect(match.params == ["id": "YWJj==", "k": "a=b"])

        // OSC 8 treats an empty id as no id.
        feed("\r\n\u{1b}]8;id=;https://empty.example\u{07}label\u{1b}]8;;\u{07}", to: view)
        let empty = try #require(view.link(at: point(view, col: 1, bufferRow: 1)))
        #expect(empty.link == "https://empty.example")
        #expect(empty.params.isEmpty)
    }

    #if os(macOS)
    /// Reads `cellSize` from `didAddSubview`. The view adds its scroller
    /// before it sets up its font.
    private final class EarlyCellSizeView: TerminalView {
        var sizes: [CGSize] = []
        override func didAddSubview(_ subview: NSView) {
            super.didAddSubview(subview)
            sizes.append(cellSize)
        }
    }

    @Test func cellSizeIsZeroBeforeSetup() throws {
        let view = EarlyCellSizeView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let first = try #require(view.sizes.first)
        #expect(first == .zero)
        #expect(view.cellSize.width > 0)
    }
    #endif

    @Test func pointsOutsideGridReturnNil() throws {
        let view = makeView()
        let (rows, cols) = view.withTerminal { ($0.rows, $0.cols) }
        feed("\u{1b}[\(rows);1H\u{1b}]8;id=edge;https://edge.example\u{07}edge\u{1b}]8;;\u{07}", to: view)
        let lastRow = point(view, col: 0, bufferRow: rows - 1)
        #expect(view.link(at: lastRow)?.link == "https://edge.example")
        #expect(view.gridPosition(at: lastRow) == Position(col: 0, row: rows - 1))

        let size = view.cellSize
        #if os(macOS)
        let belowGrid = CGPoint(x: size.width / 2, y: -3 * size.height)
        let aboveGrid = CGPoint(x: size.width / 2, y: view.frame.height + 3 * size.height)
        #else
        let belowGrid = CGPoint(x: size.width / 2, y: CGFloat(rows + 3) * size.height)
        let aboveGrid = CGPoint(x: size.width / 2, y: -3 * size.height)
        #endif
        let rightOfGrid = CGPoint(x: (CGFloat(cols) + 0.5) * size.width, y: lastRow.y)
        let locations = [belowGrid, aboveGrid, rightOfGrid,
                         CGPoint(x: -100, y: -100), CGPoint(x: 10000, y: 10000),
                         CGPoint(x: 1e300, y: lastRow.y), CGPoint(x: CGFloat.nan, y: lastRow.y),
                         CGPoint(x: 0, y: CGFloat.infinity)]
        for location in locations {
            #expect(view.gridPosition(at: location) == nil)
            #expect(view.link(at: location, mode: .explicitAndImplicit) == nil)
        }
    }
}
#endif
