/// Current scrollback viewport. All row numbers are buffer-relative.
public struct TerminalViewportState: Equatable, Sendable {
    public let topRow: Int
    public let maximumTopRow: Int
    public let isAlternateScreen: Bool
}

/// A selected interval on one visible row. The last column is excluded.
public struct TerminalSelectionSpan: Equatable, Sendable {
    public let row: Int
    public let startColumn: Int
    public let endColumn: Int
}

public struct TerminalSelectionState: Equatable, Sendable {
    public let viewport: TerminalViewportState
    public let active: Bool
    public let spans: [TerminalSelectionSpan]
    public let start: Position
    public let end: Position
}

extension Terminal {
    private func viewportStateLocked() -> TerminalViewportState {
        TerminalViewportState(topRow: displayBuffer.yDisp,
            maximumTopRow: max(0, displayBuffer.lines.count - displayBuffer.rows),
            isAlternateScreen: isDisplayBufferAlternate)
    }

    public func viewportState() -> TerminalViewportState {
        terminalLock.withLock { viewportStateLocked() }
    }

    /// Positive values scroll down. Absolute values identify a buffer row.
    public func scrollViewport(_ value: Int, absolute: Bool = false) {
        terminalLock.withLock {
            let state = viewportStateLocked()
            let target: Int
            if absolute {
                target = value
            } else {
                let sum = state.topRow.addingReportingOverflow(value)
                target = sum.overflow ? (value < 0 ? Int.min : Int.max) : sum.partialValue
            }
            let top = max(0, min(target, state.maximumTopRow))
            userScrolling = top < state.maximumTopRow
            if top != state.topRow {
                setViewYDisp(top)
                refresh(startRow: 0, endRow: rows)
            }
        }
    }

    /// Feed-owner selection checks run once per batch, outside the parser.
    public func feedPreservingSelection(_ bytes: ArraySlice<UInt8>, selection: SelectionService) {
        terminalLock.withLock {
            let previous = selection.captureSelectedContent()
            feed(buffer: bytes)
            if let previous { selection.clearIfSelectedContentChanged(from: previous) }
        }
    }

    /// Pointer coordinates identify visible cells. Character ranges include
    /// both the anchor cell and the target cell, including wide continuations.
    /// Actions: begin=0, extend=1, clear=2, all=3.
    /// Begin modes: character=0, word=1, row=2, Shift extension=3.
    @discardableResult
    public func updateSelection(_ selection: SelectionService, action: UInt32,
                                column: Int = 0, row: Int = 0, mode: UInt32 = 0) -> Bool {
        terminalLock.withLock {
            guard selection.terminal === self, action <= 3, mode <= 3 else { return false }
            selection.exclusiveEnd = true
            if action == 2 { selection.selectNone(); return true }
            if action == 3 { selection.selectAll(); return true }
            guard column >= 0, column < cols, row >= 0, row < rows else { return false }
            let position = Position(col: column, row: row + displayBuffer.yDisp)
            guard position.row < displayBuffer.lines.count else { return false }
            selection.updatePointerSelection(position, begin: action == 0, mode: mode)
            return true
        }
    }

    public func selectionState(_ selection: SelectionService) -> TerminalSelectionState {
        terminalLock.withLock {
            let viewport = viewportStateLocked()
            var spans: [TerminalSelectionSpan] = []
            if selection.active {
                for row in 0..<rows {
                    if let range = selection.selectedColumnsRange(row: row + viewport.topRow, cols: cols) {
                        spans.append(TerminalSelectionSpan(row: row,
                            startColumn: range.lowerBound, endColumn: range.upperBound))
                    }
                }
            }
            return TerminalSelectionState(viewport: viewport,
                active: selection.active && selection.hasSelectionRange, spans: spans,
                start: selection.start, end: selection.end)
        }
    }

    public func selectionText(_ selection: SelectionService) -> String {
        terminalLock.withLock { selection.active ? selection.getSelectedText() : "" }
    }
}
