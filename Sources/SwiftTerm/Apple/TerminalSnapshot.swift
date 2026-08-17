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

/// The selection values captured while `TerminalLock` is held.
///
/// `SelectionService` is mutable terminal state. It must not be read while the
/// main actor captures view geometry because the parser can adjust it at the
/// same time. The render owner creates this value inside its terminal-lock
/// transaction and gives only the value to the snapshot.
struct SnapshotSelectionState: Sendable {
    let active: Bool
    let start: Position
    let end: Position

    static let empty = SnapshotSelectionState(
        active: false,
        start: Position(col: 0, row: 0),
        end: Position(col: 0, row: 0))

    init (selection: SelectionService?) {
        selection?.terminal.terminalLock.preconditionLocked()
        active = selection?.active == true
        start = selection?.start ?? Position(col: 0, row: 0)
        end = selection?.end ?? Position(col: 0, row: 0)
    }

    private init (active: Bool, start: Position, end: Position) {
        self.active = active
        self.start = start
        self.end = end
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
    let code: Int32
    let width: Int8
    let cellAttribute: Attribute
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

    var character: Character { renderData.character }
}

final class TerminalSnapshot {
    enum RefreshResult: Equatable {
        case refreshed
        case frozen
    }

    final class Row {
        let line: BufferLine
        /// Retains only the source's immutable identity token. This prevents
        /// ABA address reuse without carrying the mutable terminal line into
        /// the render owner.
        private var sourceIdentityToken: BufferLine.RenderIdentity?
        var sourceIdentity: ObjectIdentifier? {
            sourceIdentityToken.map { ObjectIdentifier($0) }
        }
        var sourceGeneration: UInt64
        var bidiParagraphRevision: Int
        var bidiLayout: BidiRowLayout?
        var needsDirectionOverride: Bool
        var resolvedCharacters: [Int: Character]
        var images: [SnapshotImage]
        var revision: UInt64

        init (source: BufferLine, borrowing: Bool = false,
              snapshotArena: CellArena? = nil) {
            if borrowing {
                line = source
            } else {
                let arena = snapshotArena ?? source.cellArena.snapshotCopy()
                line = BufferLine(cols: source.count, arena: arena)
            }
            sourceIdentityToken = nil
            sourceGeneration = UInt64.max
            bidiParagraphRevision = Int.min
            bidiLayout = nil
            needsDirectionOverride = false
            resolvedCharacters = [:]
            images = []
            revision = 0
        }

        func recordSource(_ source: BufferLine) {
            sourceIdentityToken = source.renderIdentity
            sourceGeneration = source.generation
        }

        func character (at column: Int, cell: PackedCellView) -> Character {
            let code = cell.code
            if code == 0 {
                return " "
            }
            if let resolved = resolvedCharacters[column] {
                return resolved
            }
            guard let scalar = UnicodeScalar(UInt32(bitPattern: code)) else {
                return "\u{fffd}"
            }
            return Character(scalar)
        }
    }

    private(set) var rows: [Row] = []
    private var rowPool: [Row] = []
    /// Bidi paragraphs gathered during `refresh` whose typesetting has not run
    /// yet. Completed by `completePendingBidi()` after the terminal lock is
    /// released — the CoreText work is about 70 % of a refresh on RTL-bearing
    /// paragraphs and needs no terminal state. See Docs/ninth-batch.md.
    private var pendingBidi: [(rowIndex: Int, absoluteRow: Int,
                               deferred: TerminalBidi.DeferredParagraph)] = []

    /// A private decoder copy for packed snapshot cells. It is replaced only
    /// while `refresh` owns the snapshot and the terminal lock is held.
    private var cellArenaSnapshot: CellArena?

    private struct NativeColorCache {
        let appearance: FrameAppearance
        let ansiColors: [Color]
        let nativeColors: SnapshotNativeColors
    }
    private var nativeColorCache: NativeColorCache?

#if DEBUG
    private(set) var nativeColorRebuildCount = 0
#endif

    /// Materializes platform colors once for each appearance or palette.
    /// This method is called only while the render owner has exclusive access
    /// to this snapshot.
    func nativeColors (for appearance: FrameAppearance) -> SnapshotNativeColors {
        if let nativeColorCache,
           nativeColorCache.appearance == appearance,
           nativeColorCache.ansiColors == ansiColors {
            return nativeColorCache.nativeColors
        }

        let result = SnapshotNativeColors(
            effectiveForegroundColor: appearance.effectiveForegroundColor.nativeColor,
            effectiveBackgroundColor: appearance.effectiveBackgroundColor.nativeColor,
            selectedTextBackgroundColor: appearance.selectedTextBackgroundColor.nativeColor,
            selectedTextForegroundColor: appearance.selectedTextForegroundColor.nativeColor,
            caretColor: appearance.caretColor.nativeColor,
            caretTextColor: appearance.caretTextColor.nativeColor,
            ansiColors: ansiColors.map(TTColor.make(color:)))
        nativeColorCache = NativeColorCache(
            appearance: appearance, ansiColors: ansiColors, nativeColors: result)
#if DEBUG
        nativeColorRebuildCount += 1
#endif
        return result
    }

    /// Finishes the bidi paragraphs gathered by the last `refresh`.
    ///
    /// Must be called after the terminal lock is released and before the frame
    /// is drawn. Touches no terminal state: the paragraph cells were captured
    /// under the lock and each row's own copy is in `Row.line`.
    func completePendingBidi () {
        guard !pendingBidi.isEmpty else { return }
        TerminalBidi.finish(pendingBidi.map { $0.deferred })
        for entry in pendingBidi {
            guard entry.rowIndex < rows.count else { continue }
            let destination = rows[entry.rowIndex]
            let layout = TerminalBidi.rowLayout(entry.deferred, row: entry.absoluteRow)
            destination.bidiLayout = layout
            destination.needsDirectionOverride = layout != nil ||
                TerminalBidi.mayNeedBidi(line: destination.line, cols: cols)
        }
        // The cursor's visual column is the one thing `refresh` derives from a
        // row layout while still holding the lock. Correct it here if the
        // cursor's row was one of the deferred ones.
        if var moved = cursor,
           pendingBidi.contains(where: { $0.absoluteRow == moved.absoluteRow }) {
            if let layout = row(atAbsolute: moved.absoluteRow)?.bidiLayout,
               moved.logicalCol < layout.logicalToVisualCol.count {
                moved.visualCol = layout.logicalToVisualCol[moved.logicalCol]
            } else {
                moved.visualCol = moved.logicalCol
            }
            cursor = moved
        }
        pendingBidi.removeAll(keepingCapacity: true)
    }

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
    /// The context that goes with this snapshot's contents, built by `refresh`
    /// from the view state it was handed. Nil until the first refresh.
    private(set) var renderContext: SnapshotRenderContext?

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
    /// - Parameter deferBidiTypesetting: when true, the CoreText half of the
    ///   bidi paragraph layout is left for `completePendingBidi()`. Only pass
    ///   true from a caller that releases the terminal lock and calls it before
    ///   the frame is drawn; everyone else gets the fully resolved snapshot.
    func refresh (terminal: Terminal, viewState: FrameViewState,
                  selection: SnapshotSelectionState,
                  deferBidiTypesetting: Bool = false) -> RefreshResult {
        terminal.terminalLock.preconditionLocked()
        guard !terminal.synchronizedOutputActive else {
            return .frozen
        }

        // This interval is the target of io-gaps.md G2: everything it covers
        // runs with the terminal lock held, and the plan moves the derived
        // work (bidi, kitty virtual map, cursor presentation) out of it. The
        // signpost is what proves that landed.
        let refreshInterval = Profiling.begin(.frameRefresh)
        defer { refreshInterval.end("rows=%d", rows.count) }

        // A frame that was frozen or abandoned must not leave work that would
        // be applied to different rows next time.
        pendingBidi.removeAll(keepingCapacity: true)

#if DEBUG
        rowsCopied = 0
        rowsSkipped = 0
#endif

        let buffer = terminal.displayBuffer
        let sourceArena = buffer.cellArena
        if cellArenaSnapshot?.synchronizeSnapshotPrefix(from: sourceArena) != true {
            cellArenaSnapshot = sourceArena.snapshotCopy()
        }
        let snapshotArena = cellArenaSnapshot!
        let newStyle = SnapshotStyle(
            selectionActive: selection.active,
            selectionStart: selection.start,
            selectionEnd: selection.end,
            linkHighlightRange: viewState.linkHighlightRange,
            linkHighlightMode: viewState.linkHighlightMode,
            commandActive: viewState.commandActive,
            textBlinkVisible: viewState.textBlinkVisible)
        let styleChanged = previousStyle?.hasSameValue(as: newStyle) != true ||
            previousAnsiColors != terminal.ansiColors
        let bidiFont = ObjectIdentifier(viewState.fonts.normal)
        let bidiInputsChanged = previousBidiHostPolicy != viewState.bidiHostPolicy ||
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
            rows.append(rowPool.popLast() ?? Row(source: source,
                                                  snapshotArena: snapshotArena))
        }

        for index in 0..<visibleCount {
            let absoluteRow = firstRow + index
            let source = buffer.lines[absoluteRow]
            let destination = rows[index]
            let contentChanged = destination.sourceIdentity !=
                ObjectIdentifier(source.renderIdentity) ||
                destination.sourceGeneration != source.generation
            let bidiRevision = TerminalBidi.layoutRevision(
                row: absoluteRow, buffer: buffer,
                maximumRows: maximumBidiParagraphRows)
            let bidiChanged = contentChanged || bidiInputsChanged ||
                destination.bidiParagraphRevision != bidiRevision

            if contentChanged {
                destination.line.copyForSnapshot(from: source, arena: snapshotArena)
                destination.recordSource(source)
                destination.resolvedCharacters.removeAll(keepingCapacity: true)
                var col = 0
                let limit = min(cols, source.count)
                while col < limit {
                    let cell = source.packedView(at: col)
                    if !cell.isSimpleRune {
                        destination.resolvedCharacters[col] = cell.getCharacter()
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
                // Rows of one paragraph share a job. Without this the cell
                // extraction — O(paragraph) — would run once per visible row
                // instead of once per paragraph, which is what the old code
                // got for free by seeding the paragraph cache on the first row.
                let shared = pendingBidi.first {
                    $0.deferred.firstRow <= absoluteRow &&
                    absoluteRow <= $0.deferred.lastRow
                }?.deferred
                if let shared {
                    pendingBidi.append((rowIndex: index, absoluteRow: absoluteRow,
                                        deferred: shared))
                } else {
                    switch TerminalBidi.collectLayout(
                        row: absoluteRow, buffer: buffer, cols: cols,
                        terminal: terminal, font: viewState.fonts.normal,
                        hostPolicy: viewState.bidiHostPolicy) {
                    case .resolved(let layout):
                        destination.bidiLayout = layout
                        destination.needsDirectionOverride = layout != nil ||
                            TerminalBidi.mayNeedBidi(line: source, cols: cols)
                    case .pending(let deferred):
                        // Finished in `completePendingBidi()` once the lock is
                        // released. `destination.line` already holds this
                        // frame's copy, so the follow-up needs no live state.
                        pendingBidi.append((rowIndex: index, absoluteRow: absoluteRow,
                                            deferred: deferred))
                    }
                }
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

        // Built here rather than by the caller: the caret's attributes need it,
        // and everything it reads — style, palette, cols — is final by this
        // point. One context per refresh, reused by whoever draws the frame.
        let context = SnapshotRenderContext(viewState: viewState, snapshot: self)
        renderContext = context

        let absoluteCursorRow = buffer.yBase + buffer.y
        if absoluteCursorRow >= 0, absoluteCursorRow < buffer.lines.count,
           buffer.lines[absoluteCursorRow].count > 0 {
            let cursorLine = buffer.lines[absoluteCursorRow]
            let cursorCol = max(0, min(buffer.x, cursorLine.count - 1))
            let cell = cursorLine.packedView(at: cursorCol)
            let character = cell.code == 0 ? " " : cell.getCharacter()
            let cursorColor = context.caretColor
            let textColor = context.caretTextColor
            let attributes = attributedValue(for: cell.attribute,
                                             usingFg: cursorColor,
                                             andBg: textColor,
                                             context: context)
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
                columnWidth: max(1, Int(cell.width)),
                renderMode: cursorLine.renderMode,
                hidden: terminal.cursorHidden,
                renderData: CaretRenderData(code: cell.code,
                                            width: cell.width,
                                            cellAttribute: cell.attribute,
                                            character: character,
                                            attributes: attributes,
                                            cursorColor: cursorColor,
                                            textColor: textColor,
                                            textBlinkVisible: newStyle.textBlinkVisible,
                                            customBlockGlyphs: viewState.customBlockGlyphs,
                                            normalFont: viewState.fonts.normal))
        } else {
            cursor = nil
        }

        if !deferBidiTypesetting {
            completePendingBidi()
        }

        previousStyle = newStyle
        previousAnsiColors = terminal.ansiColors
        previousBidiHostPolicy = viewState.bidiHostPolicy
        previousBidiFont = bidiFont
        return .refreshed
    }
}
#endif
