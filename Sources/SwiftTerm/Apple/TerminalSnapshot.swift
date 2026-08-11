//
//  TerminalSnapshot.swift
//  SwiftTerm
//
//  Immutable renderer input copied while Terminal.terminalLock is held.
//

#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation
import CoreGraphics

final class SnapshotImage: TerminalImage {
    let image: TTImage
    let pixelWidth: Int
    let pixelHeight: Int
    var col: Int
    let kittyIsKitty: Bool
    let kittyImageId: UInt32?
    let kittyImageNumber: UInt32?
    let kittyPlacementId: UInt32?
    let kittyZIndex: Int
    let kittyCol: Int
    let kittyRow: Int
    let kittyCols: Int
    let kittyRows: Int
    let kittyPixelOffsetX: Int
    let kittyPixelOffsetY: Int

    init (_ source: TerminalView.AppleImage) {
        image = source.image
        pixelWidth = source.pixelWidth
        pixelHeight = source.pixelHeight
        col = source.col
        kittyIsKitty = source.kittyIsKitty
        kittyImageId = source.kittyImageId
        kittyImageNumber = source.kittyImageNumber
        kittyPlacementId = source.kittyPlacementId
        kittyZIndex = source.kittyZIndex
        kittyCol = source.kittyCol
        kittyRow = source.kittyRow
        kittyCols = source.kittyCols
        kittyRows = source.kittyRows
        kittyPixelOffsetX = source.kittyPixelOffsetX
        kittyPixelOffsetY = source.kittyPixelOffsetY
    }

    func hasSameValue (as other: SnapshotImage) -> Bool {
        image === other.image &&
            pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight &&
            col == other.col && kittyIsKitty == other.kittyIsKitty &&
            kittyImageId == other.kittyImageId && kittyImageNumber == other.kittyImageNumber &&
            kittyPlacementId == other.kittyPlacementId && kittyZIndex == other.kittyZIndex &&
            kittyCol == other.kittyCol && kittyRow == other.kittyRow &&
            kittyCols == other.kittyCols && kittyRows == other.kittyRows &&
            kittyPixelOffsetX == other.kittyPixelOffsetX &&
            kittyPixelOffsetY == other.kittyPixelOffsetY
    }
}

struct SnapshotStyle {
    var selectionActive: Bool
    var selectionStart: Position
    var selectionEnd: Position
    var linkHighlightRange: [Terminal.LinkMatch.RowRange]?
    var linkHighlightMode: LinkHighlightMode
    var commandActive: Bool
    var textBlinkVisible: Bool

    static let empty = SnapshotStyle(selectionActive: false,
                                     selectionStart: Position(col: 0, row: 0),
                                     selectionEnd: Position(col: 0, row: 0),
                                     linkHighlightRange: nil,
                                     linkHighlightMode: .hover,
                                     commandActive: false,
                                     textBlinkVisible: true)

    func hasSameValue (as other: SnapshotStyle) -> Bool {
        selectionActive == other.selectionActive &&
            selectionStart == other.selectionStart && selectionEnd == other.selectionEnd &&
            linkHighlightRange == other.linkHighlightRange &&
            linkHighlightMode.tag == other.linkHighlightMode.tag &&
            commandActive == other.commandActive && textBlinkVisible == other.textBlinkVisible
    }
}

private extension LinkHighlightMode {
    var tag: Int {
        switch self {
        case .hover: return 0
        case .hoverWithModifier: return 1
        case .always: return 2
        case .alwaysWithModifier: return 3
        }
    }
}

struct SnapshotKitty {
    var placementsByKey: [KittyPlacementKey: KittyPlacementRecord] = [:]
    var imagesById: [UInt32: KittyGraphicsImage] = [:]
    var virtualPlacementsByImageId: [UInt32: [KittyPlacementRecord]] = [:]
}

struct CaretRenderData {
    let charData: CharData
    let character: Character
    let attributes: [NSAttributedString.Key: Any]
    let cursorColor: TTColor
    let textColor: TTColor
    let textBlinkVisible: Bool
    let customBlockGlyphs: Bool
    let normalFont: TTFont
}

struct SnapshotCursor {
    var absoluteRow: Int
    var screenRow: Int
    var logicalCol: Int
    var visualCol: Int
    var columnWidth: Int
    var renderMode: BufferLine.RenderLineMode
    var hidden: Bool
    var renderData: CaretRenderData

    var charData: CharData { renderData.charData }
    var character: Character { renderData.character }
}

final class TerminalSnapshot {
    enum RefreshResult: Equatable {
        case refreshed
        case frozen
    }

    final class Row {
        let line: BufferLine
        // Strong reference on purpose: comparing identities of a deallocated
        // line is an ABA hazard (a new BufferLine at the same address with a
        // coincidentally equal generation would false-match). Holding the
        // source keeps the address pinned while this row can still match it.
        var sourceLine: BufferLine?
        var sourceGeneration: UInt64
        var bidiParagraphRevision: Int
        var bidiLayout: BidiRowLayout?
        var needsDirectionOverride: Bool
        var resolvedCharacters: [Int: Character]
        var images: [SnapshotImage]
        var revision: UInt64

        init (source: BufferLine, borrowing: Bool = false) {
            line = borrowing ? source : BufferLine(cols: source.count)
            sourceLine = nil
            sourceGeneration = UInt64.max
            bidiParagraphRevision = Int.min
            bidiLayout = nil
            needsDirectionOverride = false
            resolvedCharacters = [:]
            images = []
            revision = 0
        }

        func character (at column: Int, cell: CharData) -> Character {
            if cell.code == 0 {
                return " "
            }
            if let resolved = resolvedCharacters[column] {
                return resolved
            }
            guard let scalar = UnicodeScalar(UInt32(bitPattern: cell.code)) else {
                return "\u{fffd}"
            }
            return Character(scalar)
        }
    }

    private(set) var rows: [Row] = []
    private var rowPool: [Row] = []
    private var previousStyle: SnapshotStyle?
    private var previousAnsiColors: [Color] = []
    private var previousBidiHostPolicy: BidiHostPolicy?
    private var previousBidiFont: ObjectIdentifier?

    var firstRow = 0
    var yDisp = 0
    var yBase = 0
    var x = 0
    var y = 0
    var cols = 0
    var rowCount = 0
    var linesCount = 0
    var linesTop = 0
    var totalLinesTrimmed = 0
    var hasAnyImages = false
    var isAltBuffer = false
    var cursorHidden = false
    var cursorStyle: CursorStyle = .blinkBlock
    var maximumBidiParagraphRows = 1
    var cursor: SnapshotCursor?
    var style: SnapshotStyle = .empty
    var kitty = SnapshotKitty()
    var ansiColors: [Color] = []
    var cgRegion: CGRect?
    var rangeChanged: (start: Int, end: Int)?

#if DEBUG
    private(set) var rowsCopied = 0
    private(set) var rowsSkipped = 0
#endif

    func row (atAbsolute absoluteRow: Int) -> Row? {
        let index = absoluteRow - firstRow
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    @discardableResult
    func refresh (terminal: Terminal, view: TerminalView) -> RefreshResult {
        terminal.terminalLock.preconditionLocked()
        guard !terminal.synchronizedOutputActive else {
            return .frozen
        }

#if DEBUG
        rowsCopied = 0
        rowsSkipped = 0
#endif

        let buffer = terminal.displayBuffer
        let selection = view.selection
        let newStyle = SnapshotStyle(
            selectionActive: selection?.active == true,
            selectionStart: selection?.start ?? Position(col: 0, row: 0),
            selectionEnd: selection?.end ?? Position(col: 0, row: 0),
            linkHighlightRange: view.linkHighlightRange,
            linkHighlightMode: view.linkHighlightMode,
            commandActive: view.commandActive,
            textBlinkVisible: view.textBlinkVisible)
        let styleChanged = previousStyle?.hasSameValue(as: newStyle) != true ||
            previousAnsiColors != terminal.ansiColors
        let bidiFont = ObjectIdentifier(view.fontSet.normal)
        let bidiInputsChanged = previousBidiHostPolicy != view.bidiHostPolicy ||
            previousBidiFont != bidiFont

        firstRow = buffer.yDisp
        yDisp = buffer.yDisp
        yBase = buffer.yBase
        x = buffer.x
        y = buffer.y
        cols = buffer.cols
        rowCount = buffer.rows
        linesCount = buffer.lines.count
        linesTop = buffer.linesTop
        totalLinesTrimmed = buffer.totalLinesTrimmed
        hasAnyImages = buffer.hasAnyImages
        isAltBuffer = terminal.isCurrentBufferAlternate
        cursorHidden = terminal.cursorHidden
        cursorStyle = terminal.options.cursorStyle
        maximumBidiParagraphRows = terminal.options.maximumBidiParagraphRows
        style = newStyle
        ansiColors = terminal.ansiColors

        let visibleCount = max(0, min(buffer.rows, buffer.lines.count - firstRow))
        while rows.count > visibleCount {
            rowPool.append(rows.removeLast())
        }
        while rows.count < visibleCount {
            let source = buffer.lines[firstRow + rows.count]
            rows.append(rowPool.popLast() ?? Row(source: source))
        }

        for index in 0..<visibleCount {
            let absoluteRow = firstRow + index
            let source = buffer.lines[absoluteRow]
            let destination = rows[index]
            let contentChanged = destination.sourceLine !== source ||
                destination.sourceGeneration != source.generation
            let bidiRevision = TerminalBidi.layoutRevision(
                row: absoluteRow, buffer: buffer,
                maximumRows: maximumBidiParagraphRows)
            let bidiChanged = contentChanged || bidiInputsChanged ||
                destination.bidiParagraphRevision != bidiRevision

            if contentChanged {
                destination.line.copyForSnapshot(from: source)
                destination.sourceLine = source
                destination.sourceGeneration = source.generation
                destination.resolvedCharacters.removeAll(keepingCapacity: true)
                var col = 0
                let limit = min(cols, source.count)
                while col < limit {
                    let cell = source[col]
                    if cell.code > CharData.maxRune {
                        destination.resolvedCharacters[col] = terminal.getCharacter(for: cell)
                    }
                    col += max(1, Int(cell.width))
                }
#if DEBUG
                rowsCopied += 1
#endif
            } else {
#if DEBUG
                rowsSkipped += 1
#endif
            }

            if bidiChanged {
                destination.bidiParagraphRevision = bidiRevision
                destination.bidiLayout = TerminalBidi.layout(
                    row: absoluteRow, buffer: buffer, cols: cols,
                    terminal: terminal, font: view.fontSet.normal,
                    hostPolicy: view.bidiHostPolicy)
                destination.needsDirectionOverride = destination.bidiLayout != nil ||
                    TerminalBidi.mayNeedBidi(line: source, cols: cols, terminal: terminal)
            }

            let newImages = (source.images ?? []).compactMap { image in
                (image as? TerminalView.AppleImage).map(SnapshotImage.init)
            }
            let imagesChanged = newImages.count != destination.images.count ||
                zip(newImages, destination.images).contains { !$0.hasSameValue(as: $1) }
            if imagesChanged {
                destination.images = newImages
            }
            if contentChanged || bidiChanged || styleChanged || imagesChanged {
                destination.revision &+= 1
            }
        }

        let state = terminal.kittyGraphicsState
        var virtual: [UInt32: [KittyPlacementRecord]] = [:]
        for record in state.placementsByKey.values
            where record.isVirtual && record.isAlternateBuffer == isAltBuffer {
            virtual[record.imageId, default: []].append(record)
        }
        kitty = SnapshotKitty(placementsByKey: state.placementsByKey,
                              imagesById: state.imagesById,
                              virtualPlacementsByImageId: virtual)

        let absoluteCursorRow = buffer.yBase + buffer.y
        if absoluteCursorRow >= 0, absoluteCursorRow < buffer.lines.count,
           buffer.lines[absoluteCursorRow].count > 0 {
            let cursorLine = buffer.lines[absoluteCursorRow]
            let cursorCol = max(0, min(buffer.x, cursorLine.count - 1))
            let charData = cursorLine[cursorCol]
            let character = charData.code == 0 ? " " : terminal.getCharacter(for: charData)
            let cursorColor = view.effectiveCaretColor
            let textColor = view.effectiveCaretTextColor
            let attributes = view.getAttributedValue(charData.attribute,
                                                     usingFg: cursorColor,
                                                     andBg: textColor) ?? [:]
            var visualCol = cursorCol
            if let layout = row(atAbsolute: absoluteCursorRow)?.bidiLayout,
               cursorCol < layout.logicalToVisualCol.count {
                visualCol = layout.logicalToVisualCol[cursorCol]
            }
            cursor = SnapshotCursor(
                absoluteRow: absoluteCursorRow,
                screenRow: absoluteCursorRow - buffer.yDisp,
                logicalCol: cursorCol,
                visualCol: visualCol,
                columnWidth: max(1, Int(charData.width)),
                renderMode: cursorLine.renderMode,
                hidden: terminal.cursorHidden,
                renderData: CaretRenderData(charData: charData,
                                            character: character,
                                            attributes: attributes,
                                            cursorColor: cursorColor,
                                            textColor: textColor,
                                            textBlinkVisible: newStyle.textBlinkVisible,
                                            customBlockGlyphs: view.customBlockGlyphs,
                                            normalFont: view.fontSet.normal))
        } else {
            cursor = nil
        }

        previousStyle = newStyle
        previousAnsiColors = terminal.ansiColors
        previousBidiHostPolicy = view.bidiHostPolicy
        previousBidiFont = bidiFont
        return .refreshed
    }
}
#endif
