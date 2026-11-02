/// Finds the screen rows whose line changed after the last
/// `clearUpdateRange()`.
///
/// The print and scroll paths do not add their rows to the refresh range.
/// Each change to a line changes its `generation`, and a scroll puts other
/// lines in the screen rows. This class keeps the identity and the
/// generation of each screen row, and compares them when a host asks for
/// the update range. The comparison costs one pass over the screen rows for
/// each frame, not one call for each printed run or scroll.
///
/// The Apple `TerminalSnapshot` uses the same test to reuse its row copies.
final class LineChangeTracker {
    struct Row {
        // A strong reference: the address of the identity cannot go to a
        // different line while this row keeps it.
        let identity: BufferLine.RenderIdentity
        let generation: UInt64
    }

    /// One entry for each row of the live screen (`yBase + y`), nil when
    /// the buffer has no line there. The rows are the same rows that
    /// `updateRange` marks: relative to `yBase`, not to the viewport.
    private var rows: [Row?] = []
    /// The `yBase` of the buffer when `rows` was recorded.
    private var yBase = 0

    private static func row(_ buffer: Buffer, _ index: Int) -> Row? {
        let lines = buffer.lines
        guard index >= 0 && index < lines.count else { return nil }
        let line = lines[index]
        return Row(identity: line.renderIdentity, generation: line.generation)
    }

    private static func same(_ a: Row?, _ b: Row?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return a.identity === b.identity && a.generation == b.generation
        default:
            return false
        }
    }

    /// Records the current lines of the screen as the clean state.
    func record(_ buffer: Buffer, rows count: Int) {
        rows.removeAll(keepingCapacity: true)
        rows.reserveCapacity(count)
        let top = buffer.yBase
        for y in 0..<max(0, count) {
            rows.append(Self.row(buffer, top + y))
        }
        yBase = top
    }

    /// Returns the first and last screen rows that show a different line,
    /// or a changed line, since `record`. After a resize, all rows changed.
    func changedScreenRows(_ buffer: Buffer, rows count: Int) -> (startY: Int, endY: Int)? {
        guard count > 0 else { return nil }
        guard rows.count == count else { return (0, count - 1) }
        let top = buffer.yBase
        var first = Int.max
        var last = -1
        for y in 0..<count where !Self.same(rows[y], Self.row(buffer, top + y)) {
            if first == Int.max {
                first = y
            }
            last = y
        }
        return last == -1 ? nil : (first, last)
    }

    /// Returns the first and last buffer rows (`yBase + y`) of the screen
    /// whose line is different, or changed, at that buffer row since
    /// `record`. A row that was not on the screen at `record` counts as
    /// changed. Lines that a scroll moves to a different buffer row also
    /// count as changed: this occurs in a scroll region, and when a full
    /// scrollback drops its first line.
    func changedBufferRows(_ buffer: Buffer, rows count: Int) -> (startY: Int, endY: Int)? {
        guard count > 0 else { return nil }
        let top = buffer.yBase
        guard rows.count == count else { return (top, top + count - 1) }
        var first = Int.max
        var last = -1
        for y in 0..<count {
            let index = top + y
            let recorded = index - yBase
            let changed = recorded < 0 || recorded >= count ||
                !Self.same(rows[recorded], Self.row(buffer, index))
            if changed {
                if first == Int.max {
                    first = index
                }
                last = index
            }
        }
        return last == -1 ? nil : (first, last)
    }
}
