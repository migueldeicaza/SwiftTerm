//
//  ExternalRenderOwner.swift
//  SwiftTerm
//
//  Owns the snapshot of a `TerminalRenderView` and works out which rows a
//  frame must repaint. Main thread only: external frames are small (one
//  viewport), so there is no render thread.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

@MainActor
final class ExternalRenderOwner {
    enum Damage: Equatable {
        case none
        /// Screen rows (0 is the top row) to repaint.
        case rows(IndexSet)
        case all
    }

    struct Prepared {
        var damage: Damage
        var cursor: SnapshotCursor?
        var rows: Int
        var columns: Int
    }

    private struct Signature: Equatable {
        var topLine: Int
        var columns: Int
        var rows: Int
        var alternate: Bool
        var cellDimension: CGSize
        var bounds: CGSize
    }

    let snapshot = TerminalSnapshot()
    private var blank: BufferLine?
    private var revisions: [UInt64] = []
    private var signature: Signature?
    private var cursorRow: Int?
    private var cursorKey: CursorKey?
    /// Kitty placements are not tied to rows; any change repaints the frame.
    private var kittyKey: (generation: UInt64, placements: [KittyGraphicsRenderPlacement])?
    private(set) var hasSnapshot = false

    private struct CursorKey: Equatable {
        var row: Int
        var column: Int
        var hidden: Bool
        var style: CursorStyle
    }

    /// Asks the source for the current frame and refreshes the snapshot.
    func prepare (source: TerminalExternalFrameSource, viewState: FrameViewState) -> Prepared? {
        var prepared: Prepared?
        source.withFrame { frame, store, lookup in
            let blankLine: BufferLine
            // Compare arenas, not stores: a new store can reuse an old address.
            if let blank, blank.cellArena === store.arena, blank.count == max(1, frame.columns) {
                blankLine = blank
            } else {
                blankLine = store.makeLine(columns: frame.columns)
                blank = blankLine
            }
            snapshot.refresh(external: frame, store: store, line: lookup, blank: blankLine,
                             viewState: viewState)
            let newSignature = Signature(topLine: frame.topLine, columns: frame.columns, rows: frame.rows,
                                         alternate: frame.isAlternateBuffer,
                                         cellDimension: viewState.cellDimension,
                                         bounds: viewState.viewBounds.size)
            let newRevisions = snapshot.rows.map(\.revision)
            let kitty = snapshot.kitty.renderSnapshot
            let kittyChanged = kittyKey.map {
                $0.generation != kitty.storageGeneration || $0.placements != kitty.placements
            } ?? !kitty.placements.isEmpty
            kittyKey = (kitty.storageGeneration, kitty.placements)
            var damage: Damage
            if !hasSnapshot || signature != newSignature || snapshot.appearanceChanged ||
                revisions.count != newRevisions.count || kittyChanged {
                damage = .all
            } else {
                var changed = IndexSet()
                for index in 0..<newRevisions.count where newRevisions[index] != revisions[index] {
                    changed.insert(index)
                }
                damage = changed.isEmpty ? .none : .rows(changed)
            }
            // The caret is a separate view; a moved cursor only repaints the
            // rows when the cell under it changes, which the revisions cover.
            let newCursorKey = snapshot.cursor.map {
                CursorKey(row: $0.screenRow, column: $0.visualCol, hidden: $0.hidden, style: frame.cursorStyle)
            }
            let cursorMoved = newCursorKey != cursorKey
            if case .none = damage, cursorMoved {
                damage = .rows(IndexSet())
            }
            cursorKey = newCursorKey
            signature = newSignature
            revisions = newRevisions
            hasSnapshot = true
            prepared = Prepared(damage: damage, cursor: snapshot.cursor,
                                rows: frame.rows, columns: frame.columns)
        }
        return prepared
    }

    func withSnapshotForDrawing (viewState: FrameViewState,
                                 _ body: (TerminalSnapshot, SnapshotRenderContext) -> Void) {
        guard hasSnapshot else { return }
        let context = snapshot.renderContext ??
            SnapshotRenderContext(viewState: viewState, snapshot: snapshot)
        body(snapshot, context)
    }

    /// The bidi layout of a screen row in the last frame, if it has one.
    func layout (screenRow: Int) -> BidiRowLayout? {
        guard hasSnapshot, screenRow >= 0, screenRow < snapshot.rows.count else { return nil }
        return snapshot.rows[screenRow].bidiLayout
    }

    /// Forgets the previous frame, so that the next one repaints everything.
    func invalidate () {
        signature = nil
    }
}

#endif
#endif // !SWIFTTERM_EMBEDDED
