//
//  TerminalMirrorSnapshot.swift
//  SwiftTerm
//
//  Bytes that make another terminal show what this one shows, so a terminal
//  can be mirrored to another device byte for byte.
//

extension Terminal {
    /// Bytes that, fed to a terminal of the same columns and rows in any state
    /// (fresh or used, with scrollback room for them), make it show what this
    /// one shows now. Call with ``terminalLock`` held.
    ///
    /// The bytes start with a full reset, then rebuild the normal screen with
    /// up to `scrollback` lines of history above it, the alternate screen,
    /// and the state that changes how later output lands. A terminal fed them
    /// and then every batch this one parses afterwards keeps matching it.
    ///
    /// What comes back, for each screen: every cell's text, wide characters,
    /// emoji, combining marks and grapheme clusters, width, colours (default,
    /// 16, 256 and RGB), bold, dim, italic, underline with its style and
    /// colour, blink, inverse, invisible, crossed out, OSC 8 links, erased
    /// cells with their background, blank cells, which lines soft-wrap,
    /// double-width and double-height lines, and each paragraph's BiDi state.
    /// Then the cursor, its visibility, style and blink, the pending wrap at
    /// the last column, the scroll region, left and right margins, tab stops,
    /// the saved cursor of each screen with what DECSC saves, kitty keyboard
    /// flags and their stack on each screen, which screen shows, and the
    /// modes: origin, autowrap, reverse wrap, insert, application cursor
    /// and keypad, reverse video, line feed, smooth scroll, 80/132 permission,
    /// bracketed paste, mouse tracking and encoding, shift capture, focus,
    /// alternate scroll, colour-scheme, visibility and size reports, kitty
    /// paste events, BiDi modes, and the private modes saved with XTSAVE.
    /// Also the window and icon titles, palette entries the program changed
    /// with OSC 4, the designated and invoked character sets, the current
    /// attribute and the link being printed. Synchronized output ends off.
    ///
    /// Halves of wide characters that REP or a rectangle operation left on
    /// their own come back too, where the cell next to them allows it.
    ///
    /// What doesn't come back: images (sixel and kitty graphics), OSC 133
    /// prompt marks, the title stack, the working directory and document
    /// (OSC 7 and 6), program status (OSC 7501), the foreground, background
    /// and cursor colours (OSC 10, 11 and 12, which hosts also set), the
    /// conformance level and 8-bit controls, xterm title modes, a background
    /// in the default-inverted colour (only DECIC and DECBI make one: it
    /// comes back as the default), a character set that DECRC left active
    /// apart from the invoked one, the link on a blank cell (half of a linked
    /// wide character that was written over), the soft-wrap flag of the
    /// oldest line sent (nothing above it to wrap from), and the user's
    /// scroll position. Nor do two kinds of cell that only odd writes make:
    /// half of a wide character cut off by DECFRA, REP or a scroll inside
    /// left and right margins when the cell beside it can't be rebuilt around
    /// it (it comes back blank), and a grapheme cluster built in an order
    /// that printing its scalars from the start wouldn't follow. On a one-row
    /// terminal a few rare repairs that need the row above are skipped.
    ///
    /// When the alternate screen shows and the terminal changed size since
    /// it opened, this first lays the normal screen out at the new size, as
    /// leaving the alternate screen would.
    ///
    /// The receiving terminal must have the options that decide character
    /// widths (`regionalIndicatorWidth`) set as this one does.
    public func mirrorSnapshot(scrollback: Int) -> [UInt8] {
        var writer = MirrorSnapshotWriter(terminal: self)
        writer.write(scrollback: max(0, scrollback))
        return writer.out
    }
}

/// One cell of a source line, as the writer sees it.
private struct MirrorCell {
    enum Kind {
        /// No text: an erased or never-written cell, or one that can't be
        /// rebuilt. It comes back blank, with its attribute.
        case blank
        /// Printable text: one scalar or a grapheme cluster.
        case text
        /// One narrow scalar that printing can't place (a control or a
        /// zero-width scalar on its own), placed with DECFRA instead.
        case framed
    }

    var kind: Kind
    /// 2 for a wide character, else 1.
    var width: Int
    var first: UInt32
    var last: UInt32
    /// A wide character whose second cell holds something else: printing
    /// it writes its tail there, and DECFRA then puts that cell back.
    var orphanHead = false
    /// A cluster whose first scalar can't start a print (a mark that DECFRA
    /// placed): DECFRA places it, and the rest prints onto it.
    var framedStart = false
}

/// Writes the bytes of a mirror snapshot.
///
/// It keeps a model of the receiving terminal (cursor, attribute, link, what
/// unwritten cells hold) and writes each line the way a program would, so
/// line wrapping, scrollback and the parser's own bookkeeping come out as on
/// the source. Two things need care:
///
/// - A soft-wrapped line exists only because a print overflowed the line
///   above. So a line followed by a wrapped one must end in the pending-wrap
///   state, and the next print starts the wrapped line.
/// - Printing joins a scalar to the cell before the cursor when Unicode says
///   they form one grapheme. Two cells the source holds apart are written so
///   the first is still blank when the second prints: the first goes later,
///   right to left, or by DECFRA, which places a cell without joining it.
struct MirrorSnapshotWriter {
    private let terminal: Terminal
    private let cols: Int
    private let rows: Int
    private let narrowRegionalIndicators: Bool
    private(set) var out: [UInt8] = []

    // The receiving terminal, as the bytes so far leave it.
    private var x = 0
    private var row = 0
    private var sgr = CharData.defaultAttr
    /// The packed key of the cell whose attribute `sgr` is, so a run of cells
    /// in one style costs one compare. Nil when `sgr` came from elsewhere.
    private var sgrKey: PackedAttributeKey? = nil
    private var link: String? = nil
    /// What the cells of the current row hold until written.
    private var fill = CharData.defaultAttr
    /// The BiDi state new paragraphs get, once known.
    private var bidi: BidiPresentationState? = nil

    // Work left for a row until the print that wraps to the next one: cells
    // to print right to left, then cells to place with DECFRA.
    private var prints: [Int] = []
    private var frames: [Int] = []
    private var carriedLine: BufferLine? = nil
    private var carriedPrints: [Int] = []
    private var carriedFrames: [Int] = []

    private var linkNames: [UInt16: String?] = [:]
    /// The column of the last wide character's second cell written on the
    /// current row, while the cursor is still right after it.
    private var receiverTail = -1

    init(terminal: Terminal) {
        self.terminal = terminal
        cols = terminal.cols
        rows = terminal.rows
        narrowRegionalIndicators = terminal.options.regionalIndicatorWidth == .narrow
    }

    mutating func write(scrollback: Int) {
        let alternate = terminal.isCurrentBufferAlternate
        if alternate {
            terminal.mirrorLayOutNormalBuffer()
        }
        let normal = terminal.normalBuffer
        let alt = terminal.altBuffer
        let history = max(0, min(scrollback, normal.yBase))
        out.reserveCapacity((history + rows) * (cols + 8) + 1024)

        // CAN ends anything the receiver's parser was in the middle of, and
        // RIS clears the normal screen and the scrollback. RIS from the
        // alternate screen carries its cursor over, so the cursor goes home.
        byte(0x18)
        esc(0x63)
        csi(final: 0x48)

        writeLines(normal, from: normal.yBase - history, count: history + rows)
        writeScreenState(normal, alternate: false)

        // The alternate screen. RIS leaves its content, scroll region and
        // tab stops as they were, so all of them are set. A program that left
        // with 47 rather than 1049 left content behind it, which comes back.
        let altHasContent = alternate || alt.lines.count > 0
        csi(private: true, 1047, final: 0x68)
        csi(final: 0x72)
        x = 0
        row = 0
        setAttribute(CharData.defaultAttr)
        csi(2, final: 0x4a)
        fill = CharData.defaultAttr
        if altHasContent {
            writeLines(alt, from: alt.yBase, count: rows)
        }
        writeScreenState(alt, alternate: true)
        if !alternate {
            // 47 leaves the screen as set here. 1047 would also clear it and
            // reset its region and margins, which the source may hold apart
            // from the defaults: a resize leaves margins as they were. Blank
            // rows show the same as none when a program comes back.
            csi(private: true, 47, final: 0x6c)
        }

        // Away from column 0: there a BiDi change would apply to the row's
        // paragraph too.
        cursorTo(row: 0, col: 1)
        writeSavedPrivateModes()
        writeBidi(terminal.currentBidiState, force: true)
        csi(private: true, 1243, final: terminal.bidiArrowKeySwap ? 0x68 : 0x6c)

        writeCursor()
        writeModes()
    }

    // MARK: Lines

    private mutating func writeLines(_ buffer: Buffer, from start: Int, count: Int) {
        let lines = buffer.lines
        let total = min(count, lines.count - start)
        guard total > 0, start >= 0 else { return }
        for k in 0..<total {
            let line = lines[start + k]
            let wrapsFromPrevious = k > 0 && line.isWrapped
            let next: BufferLine? = k + 1 < total ? lines[start + k + 1] : nil
            if k > 0 && !wrapsFromPrevious {
                newLine()
            }
            if !wrapsFromPrevious {
                writeBidi(line.bidiState, force: bidi == nil)
            }
            writeLine(line, wrapsFromPrevious: wrapsFromPrevious,
                      next: next.flatMap { $0.isWrapped ? $0 : nil })
        }
    }

    /// CR LF, keeping track of where it lands and what that row holds.
    private mutating func newLine() {
        byte(0x0d)
        byte(0x0a)
        x = 0
        if row < rows - 1 {
            row += 1
            fill = CharData.defaultAttr
        } else {
            // The row scrolled in, erased with the current background.
            fill = eraseAttribute(sgr)
        }
    }

    /// Writes one line. A line that wraps from the one before starts with
    /// the receiver in the pending-wrap state at the end of the row above.
    private mutating func writeLine(_ line: BufferLine, wrapsFromPrevious: Bool, next: BufferLine?) {
        let count = min(line.count, cols)
        let wrapsToNext = next != nil
        prints.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)

        var c = 0
        receiverTail = -1
        if wrapsFromPrevious {
            c = arriveByWrapping(line, count: count)
        }
        let end = wrapsToNext ? cols : contentEnd(line, count: count)
        // A cell that must go by DECFRA because the one before it would
        // otherwise join it.
        var forcedFrame = -1

        while c < end {
            if c == forcedFrame {
                frames.append(c)
                c += 1
                continue
            }
            if isSpacer(line, c, count: count) {
                // The second cell of a wide character whose first cell holds
                // something else: REP left it there by copying the one before
                // it, and REP puts it back.
                if receiverTail == c - 1 && x == c && sameCell(line, c - 1, c) {
                    var r = c + 1
                    while r < end && isSpacer(line, r, count: count) && sameCell(line, c, r) {
                        r += 1
                    }
                    csi(r - c, final: 0x62)
                    x = r
                    receiverTail = r - 1
                    c = r
                    continue
                }
            } else if placeTail(line, c, count: count) {
                c += 2
                continue
            }
            let cell = classify(line, c, count: count)
            switch cell.kind {
            case .blank:
                let attribute = blankAttribute(line, c, count: count)
                var r = c + 1
                while r < end, isBlank(line, r, count: count),
                      blankAttribute(line, r, count: count) == attribute {
                    r += 1
                }
                if r - 1 > c && r < end && isSpacer(line, r, count: count) {
                    // The last of the run may carry the second half of a wide
                    // character next to it: leave it to the next turn.
                    r -= 1
                }
                if wrapsToNext && r == cols {
                    // The last cell goes with the wrap.
                    if r - 1 > c {
                        blankRun(c, r - 1, attribute)
                    }
                    c = end
                } else {
                    blankRun(c, r, attribute)
                    c = r
                }
            case .framed:
                if wrapsToNext && c == cols - 1 {
                    c = end
                } else {
                    frames.append(c)
                    c += 1
                }
            case .text:
                let after = c + cell.width
                if cell.orphanHead {
                    frames.append(c + 1)
                }
                if after >= cols && wrapsToNext {
                    // The last cell: it may not join the first of the next line.
                    if let next, joinsNext(cell, nextLine: next) {
                        c = end
                        continue
                    }
                    moveTo(c)
                    printCell(line, c, cell)
                    c = end
                    continue
                }
                if after < count {
                    let following = classify(line, after, count: count)
                    if following.kind == .text, !following.framedStart, mayJoin(cell.last, following.first) {
                        if following.width == 1, canFrame(line, after, following) {
                            forcedFrame = after
                        } else {
                            prints.append(c)
                            c = after
                            continue
                        }
                    }
                }
                moveTo(c)
                printCell(line, c, cell)
                if cell.width == 2 {
                    receiverTail = c + 1
                }
                c = after
            }
        }

        if wrapsToNext {
            if x != cols, let next {
                endWithPlaceholder(line, count: count, nextLine: next)
            }
            carriedLine = line
            swap(&carriedPrints, &prints)
            swap(&carriedFrames, &frames)
        } else {
            for col in prints.reversed() {
                moveTo(col)
                printCell(line, col, classify(line, col, count: count))
            }
            for col in frames {
                frameCell(line, col, onRow: row)
            }
        }
        writeRenderMode(line)
    }

    /// The first print on a wrapped line: it makes the wrap. Returns the
    /// column to go on from.
    private mutating func arriveByWrapping(_ line: BufferLine, count: Int) -> Int {
        let first = classify(line, 0, count: count)
        var printable = first.kind == .text && first.width < cols
        if printable && (first.framedStart || keepsNarrow(line, 0, first)) {
            // DECFRA can't make the wrap, and neither can a print with
            // autowrap off.
            printable = false
        }
        if printable && first.width < count {
            let following = classify(line, first.width, count: count)
            if following.kind == .text, !following.framedStart, mayJoin(first.last, following.first) {
                // Leave the pair to the main loop, which knows how to part them.
                printable = false
            }
        }
        var resume = 0
        if printable {
            printCell(line, 0, first)
            wrapped()
            resume = first.width
        } else {
            byte(0x20)
            wrapped()
            // The placeholder goes again: the cell holds what a fresh one would.
            byte(0x0d)
            x = 0
            setBackground(fill.bg)
            csi(1, final: 0x58)
        }
        flushCarried()
        receiverTail = printable && first.width == 2 ? 1 : -1
        return resume
    }

    /// The print in progress has wrapped to a new row.
    private mutating func wrapped() {
        if row < rows - 1 {
            row += 1
            fill = CharData.defaultAttr
        } else {
            fill = eraseAttribute(sgr)
        }
    }

    /// Ends a line whose last cell isn't printed in the pending-wrap state:
    /// a space at the last column, then DECFRA puts back what belongs there.
    private mutating func endWithPlaceholder(_ line: BufferLine, count: Int, nextLine: BufferLine) {
        var last = cols - 1
        if cols >= 2, cols - 2 < count {
            let head = classify(line, cols - 2, count: count)
            if head.kind == .text && head.width == 2 {
                last = cols - 2
            }
        }
        moveTo(cols - 1)
        byte(0x20)
        x = cols
        let cell = classify(line, last, count: count)
        switch cell.kind {
        case .blank:
            setAttribute(blankAttribute(line, last, count: count))
            fillRectangle(0, top: row, left: cols - 1, bottom: row, right: cols - 1)
        case .framed:
            if joinsNext(cell, nextLine: nextLine) {
                fillRectangle(0, top: row, left: cols - 1, bottom: row, right: cols - 1)
                frames.append(last)
            } else {
                frameCell(line, last, onRow: row)
            }
        case .text:
            fillRectangle(0, top: row, left: cols - 1, bottom: row, right: cols - 1)
            prints.append(last)
            if cell.orphanHead {
                frames.append(last + 1)
            }
        }
    }

    /// Writes what the row above left for after the wrap: its prints right
    /// to left, then its DECFRA cells. Then the cursor goes back.
    private mutating func flushCarried() {
        guard let line = carriedLine else { return }
        carriedLine = nil
        defer {
            carriedPrints.removeAll(keepingCapacity: true)
            carriedFrames.removeAll(keepingCapacity: true)
        }
        guard rows >= 2, !(carriedPrints.isEmpty && carriedFrames.isEmpty) else { return }
        let count = min(line.count, cols)
        let here = (row: row, col: x)
        let above = row - 1
        for col in carriedPrints.reversed() {
            cursorTo(row: above, col: col)
            printCell(line, col, classify(line, col, count: count))
        }
        for col in carriedFrames {
            frameCell(line, col, onRow: above)
        }
        cursorTo(row: here.row, col: min(here.col, cols - 1))
    }

    private mutating func writeRenderMode(_ line: BufferLine) {
        switch line.renderMode {
        case .single:
            return
        case .doubleWidth:
            escHash(0x36)
        case .doubledTop:
            escHash(0x33)
        case .doubledDown:
            escHash(0x34)
        }
    }

    // MARK: Cells

    private func classify(_ line: BufferLine, _ c: Int, count: Int) -> MirrorCell {
        let blank = MirrorCell(kind: .blank, width: 1, first: 0, last: 0)
        guard c < count else { return blank }
        let packed = line.packedCell(at: c)
        switch packed.contentTag {
        case .backgroundPalette, .backgroundRGB:
            return blank
        case .codepoint:
            let value = packed.content
            guard value != 0 else { return blank }
            switch packed.widthState {
            case .narrow:
                if isPrintable(value) && width(of: value) == 1 {
                    return MirrorCell(kind: .text, width: 1, first: value, last: value)
                }
                return canFrame(value) && !packed.hasPayload
                    ? MirrorCell(kind: .framed, width: 1, first: value, last: value) : blank
            case .wide:
                guard isPrintable(value) && width(of: value) == 2 else { return blank }
                if hasTail(line, c, count: count) {
                    return MirrorCell(kind: .text, width: 2, first: value, last: value)
                }
                return canPlaceOver(line, c + 1, count: count)
                    ? MirrorCell(kind: .text, width: 2, first: value, last: value, orphanHead: true) : blank
            case .spacerTail, .spacerHead:
                return blank
            }
        case .grapheme:
            guard let scalars = line.cellArena.grapheme(for: packed.content),
                  let first = scalars.first, let last = scalars.last else {
                return blank
            }
            guard isPrintable(first), width(of: first) > 0 else {
                guard canFrame(first), !packed.hasPayload,
                      packed.widthState == .narrow || hasTail(line, c, count: count) else {
                    return blank
                }
                return MirrorCell(kind: .text, width: packed.widthState == .wide ? 2 : 1,
                                  first: first, last: last, framedStart: true)
            }
            switch packed.widthState {
            case .narrow:
                return MirrorCell(kind: .text, width: 1, first: first, last: last)
            case .wide:
                if hasTail(line, c, count: count) {
                    return MirrorCell(kind: .text, width: 2, first: first, last: last)
                }
                return canPlaceOver(line, c + 1, count: count)
                    ? MirrorCell(kind: .text, width: 2, first: first, last: last, orphanHead: true) : blank
            case .spacerTail, .spacerHead:
                return blank
            }
        }
    }

    private func hasTail(_ line: BufferLine, _ c: Int, count: Int) -> Bool {
        c + 1 < count && line.packedCell(at: c + 1).widthState == .spacerTail
    }

    /// A cell of no width: the second cell of a wide character.
    private func isSpacer(_ line: BufferLine, _ c: Int, count: Int) -> Bool {
        guard c < count else { return false }
        let state = line.packedCell(at: c).widthState
        return state == .spacerTail || state == .spacerHead
    }

    /// Whether DECFRA can put back the cell at `c` after something printed
    /// over it.
    private func canPlaceOver(_ line: BufferLine, _ c: Int, count: Int) -> Bool {
        guard c < count, !isSpacer(line, c, count: count) else { return false }
        let packed = line.packedCell(at: c)
        guard packed.widthState == .narrow else { return false }
        switch packed.contentTag {
        case .backgroundPalette, .backgroundRGB:
            return true
        case .codepoint:
            return packed.content == 0 || (!packed.hasPayload && canFrame(packed.content))
        case .grapheme:
            return false
        }
    }

    /// Whether two cells hold the same attribute and link.
    private func sameCell(_ line: BufferLine, _ a: Int, _ b: Int) -> Bool {
        let x = line.packedCell(at: a)
        let y = line.packedCell(at: b)
        return x.attributeKey == y.attributeKey && x.payloadCode == y.payloadCode
    }

    /// The second cell of a wide character whose first cell holds something
    /// else (here at `c`, which DECFRA can put back): a wide space printed at
    /// `c` writes it, in its attribute and link, then DECFRA restores `c`.
    private mutating func placeTail(_ line: BufferLine, _ c: Int, count: Int) -> Bool {
        guard c + 1 < count, isSpacer(line, c + 1, count: count),
              line.packedCell(at: c).widthState != .wide,
              canPlaceOver(line, c, count: count) else {
            return false
        }
        // The space may not join what is printed either side of it.
        let space: UInt32 = 0x3000
        if c + 2 < count {
            let following = classify(line, c + 2, count: count)
            if following.kind == .text && mayJoin(space, following.first) {
                return false
            }
        }
        if c > 0 {
            var left = c - 1
            if left > 0 && isSpacer(line, left, count: count) {
                left -= 1
            }
            let previous = classify(line, left, count: count)
            if previous.kind == .text && mayJoin(previous.last, space) {
                return false
            }
        }
        let tail = line.packedCell(at: c + 1)
        moveTo(c)
        setAttribute(line.cellArena.attribute(for: tail))
        setLink(linkName(tail.payloadCode))
        utf8(space)
        x = c + 2
        receiverTail = c + 1
        frames.append(c)
        return true
    }

    /// True for a cell that comes back blank: no text, or text that can't.
    private func isBlank(_ line: BufferLine, _ c: Int, count: Int) -> Bool {
        guard c < count else { return true }
        // The second cell of a wide character goes with it, or alone.
        if isSpacer(line, c, count: count) {
            return false
        }
        return classify(line, c, count: count).kind == .blank
    }

    private func blankAttribute(_ line: BufferLine, _ c: Int, count: Int) -> Attribute {
        guard c < count else { return fill }
        return representable(line.cellArena.attribute(for: line.packedCell(at: c)))
    }

    /// The column after the last cell the receiver doesn't already hold.
    private func contentEnd(_ line: BufferLine, count: Int) -> Int {
        var end = count
        while end > 0, isBlank(line, end - 1, count: count),
              blankAttribute(line, end - 1, count: count) == fill {
            end -= 1
        }
        return end
    }

    private func isPrintable(_ value: UInt32) -> Bool {
        value >= 0x20 && value != 0x7f && !(0x80..<0xa0).contains(value)
    }

    private func width(of value: UInt32) -> Int {
        if value < 0x7f {
            return value >= 0x20 ? 1 : -1
        }
        let width = UnicodeWidthData.columnWidth(value)
        if width == 2, narrowRegionalIndicators, UnicodeUtil.isRegionalIndicator(value) {
            return 1
        }
        return width
    }

    /// DECFRA takes the character as a parameter, which holds up to 65535.
    private func canFrame(_ value: UInt32) -> Bool {
        value > 0 && value <= 0xffff && !(0xd800...0xdfff).contains(value)
    }

    private func canFrame(_ line: BufferLine, _ c: Int, _ cell: MirrorCell) -> Bool {
        let packed = line.packedCell(at: c)
        return cell.first == cell.last && packed.contentTag == .codepoint &&
            packed.widthState == .narrow && !packed.hasPayload && canFrame(cell.first)
    }

    /// Whether printing `next` right after `previous` could join them into
    /// one grapheme, the way the receiver's print path decides it.
    private func mayJoin(_ previous: UInt32, _ next: UInt32) -> Bool {
        if previous < 0x80 && next < 0x80 {
            return false
        }
        if UnicodeUtil.isEmojiModifier(next) {
            return UnicodeUtil.isEmojiModifierBase(previous)
        }
        return UnicodeUtil.graphemeJoinNonEmojiModifier(
            previous: previous,
            previousProperties: UnicodeUtil.graphemeProperties(previous),
            incoming: next,
            incomingProperties: UnicodeUtil.graphemeProperties(next),
            incomingWidth: width(of: next)) != .breaks
    }

    /// Whether the first cell of the wrapped line after this one could join
    /// `cell`, the last of this line.
    private func joinsNext(_ cell: MirrorCell, nextLine: BufferLine) -> Bool {
        let first = classify(nextLine, 0, count: min(nextLine.count, cols))
        return first.kind == .text && !first.framedStart && mayJoin(cell.last, first.first)
    }

    /// Prints the text of the cell at `c`, with the cursor already there.
    private mutating func printCell(_ line: BufferLine, _ c: Int, _ cell: MirrorCell) {
        let packed = line.packedCell(at: c)
        let key = packed.attributeKey
        if key != sgrKey {
            setAttribute(line.cellArena.attribute(for: packed))
            sgrKey = key
        }
        setLink(linkName(packed.payloadCode))
        if packed.contentTag == .grapheme, let scalars = line.cellArena.grapheme(for: packed.content) {
            var rest = scalars[...]
            if cell.framedStart, let first = scalars.first {
                // DECFRA places the first scalar, then the rest joins it,
                // printed with the cursor right after it. At the last column
                // a space first makes the cursor stand past it.
                if c == cols - 1 {
                    byte(0x20)
                    x = cols
                }
                fillRectangle(Int(first), top: row, left: c, bottom: row, right: c)
                if c < cols - 1 {
                    moveTo(c + 1)
                }
                rest = scalars.dropFirst()
            }
            let keepNarrow = keepsNarrow(line, c, cell)
            if keepNarrow {
                if c < cols - 1 {
                    csi(private: true, 69, final: 0x68)
                    csi(1, c + 1, final: 0x73)
                }
                csi(private: true, 7, final: 0x6c)
            }
            for scalar in rest {
                utf8(scalar)
            }
            if keepNarrow {
                csi(private: true, 7, final: 0x68)
                if c < cols - 1 {
                    csi(1, cols, final: 0x73)
                    csi(private: true, 69, final: 0x6c)
                }
            }
        } else {
            utf8(packed.content)
        }
        x = c + cell.width
    }

    /// Printing widens a narrow cluster when a scalar joins it that needs
    /// the room, unless it sits at the right margin with autowrap off: the
    /// source kept this one narrow that way, and so must the print.
    private func keepsNarrow(_ line: BufferLine, _ c: Int, _ cell: MirrorCell) -> Bool {
        guard cell.width == 1, cell.kind == .text else { return false }
        let packed = line.packedCell(at: c)
        guard packed.contentTag == .grapheme,
              let scalars = line.cellArena.grapheme(for: packed.content) else {
            return false
        }
        return scalars.dropFirst().contains { scalar in
            scalar == 0xfe0f || width(of: scalar) > 0 || UnicodeUtil.isSpacingMarkWidth(scalar)
        }
    }

    /// Places a framed cell with DECFRA, without moving the cursor.
    private mutating func frameCell(_ line: BufferLine, _ c: Int, onRow target: Int) {
        let packed = line.packedCell(at: c)
        setAttribute(line.cellArena.attribute(for: packed))
        let character = packed.contentTag == .codepoint ? Int(packed.content) : 0
        fillRectangle(character, top: target, left: c, bottom: target, right: c)
    }

    /// Makes cells `start..<end` of the current row blank with `attribute`.
    private mutating func blankRun(_ start: Int, _ end: Int, _ attribute: Attribute) {
        guard attribute != fill else { return }
        if eraseAttribute(attribute) == attribute {
            setBackground(attribute.bg)
            moveTo(start)
            csi(end - start, final: 0x58)
        } else {
            setAttribute(attribute)
            fillRectangle(0, top: row, left: start, bottom: row, right: end - 1)
        }
    }

    // MARK: Screen state

    /// Scroll region, margins, tab stops, saved cursor and keyboard flags of
    /// the screen showing on the receiver now.
    private mutating func writeScreenState(_ buffer: Buffer, alternate: Bool) {
        // Fixes a wrap may still owe are done before anything moves.
        flushCarried()

        if buffer.scrollTop != 0 || buffer.scrollBottom != rows - 1 {
            csi(buffer.scrollTop + 1, buffer.scrollBottom + 1, final: 0x72)
            x = 0
            row = 0
        }
        if alternate || buffer.marginLeft != 0 || buffer.marginRight != cols - 1 {
            csi(private: true, 69, final: 0x68)
            csi(buffer.marginLeft + 1, buffer.marginRight + 1, final: 0x73)
            csi(private: true, 69, final: 0x6c)
        }

        csi(3, final: 0x67)
        let stops = buffer.tabStops
        for col in 0..<min(stops.count, cols) where stops[col] {
            moveTo(col)
            esc(0x48)
        }

        let isDefaultSave = buffer.savedX == 0 && buffer.savedY == 0 &&
            buffer.savedAttr == CharData.defaultAttr && buffer.savedCharset == nil &&
            !buffer.savedOriginMode && !buffer.savedMarginMode &&
            !buffer.savedWraparound && !buffer.savedReverseWraparound
        if alternate || !isDefaultSave {
            cursorTo(row: min(max(buffer.savedY, 0), rows - 1),
                     col: min(max(buffer.savedX, 0), cols - 1))
            setAttribute(buffer.savedAttr)
            let charset = buffer.savedCharset.flatMap(charsetCode)
            if let charset {
                designate(0, charset)
            }
            if buffer.savedOriginMode {
                csi(private: true, 6, final: 0x68)
            }
            if buffer.savedMarginMode {
                csi(private: true, 69, final: 0x68)
            }
            if buffer.savedReverseWraparound {
                csi(private: true, 45, final: 0x68)
            }
            if !buffer.savedWraparound {
                csi(private: true, 7, final: 0x6c)
            }
            esc(0x37)
            if charset != nil {
                designate(0, 0x42)
            }
            if buffer.savedOriginMode {
                csi(private: true, 6, final: 0x6c)
            }
            if buffer.savedMarginMode {
                csi(private: true, 69, final: 0x6c)
            }
            if buffer.savedReverseWraparound {
                csi(private: true, 45, final: 0x6c)
            }
            if !buffer.savedWraparound {
                csi(private: true, 7, final: 0x68)
            }
        }

        let keyboard = terminal.mirrorKeyboardMode(alternate: alternate)
        if !keyboard.flags.isEmpty || !keyboard.stack.isEmpty {
            // Set the bottom of the stack, push each one above it, then the
            // flags in force.
            let levels = keyboard.stack + [keyboard.flags]
            csiKitty(0x3d, levels[0].rawValue, mode: 1)
            for level in levels.dropFirst() {
                csiKitty(0x3e, level.rawValue, mode: nil)
            }
        }
    }

    /// Private modes saved with XTSAVE: each is set to its saved value and
    /// saved again. Their values now come after.
    private mutating func writeSavedPrivateModes() {
        let saved = terminal.mirrorSavedPrivateModes
        guard !saved.isEmpty else { return }
        for mode in saved.keys.sorted() {
            csi(private: true, mode, final: saved[mode]! ? 0x68 : 0x6c)
            csi(private: true, mode, final: 0x73)
        }
        // Saving synchronized output on means turning it on for a moment.
        if saved[SpecialDECPrivateMode.synchronizedOutput.rawValue] == true {
            csi(private: true, SpecialDECPrivateMode.synchronizedOutput.rawValue, final: 0x6c)
        }
    }

    /// Sets the BiDi state new paragraphs get. At column 0 of a new paragraph
    /// it also applies to that row.
    private mutating func writeBidi(_ state: BidiPresentationState, force: Bool) {
        let previous = force ? nil : bidi
        if previous?.supportMode != state.supportMode {
            csi(8, final: state.supportMode == .implicit ? 0x68 : 0x6c)
        }
        if previous?.autodetectDirection != state.autodetectDirection {
            csi(private: true, 2501, final: state.autodetectDirection ? 0x68 : 0x6c)
        }
        if previous?.fallbackDirection != state.fallbackDirection {
            // SPD: CSI 0 SP S for left to right, CSI 3 SP S for right to left.
            csiStart()
            decimal(state.fallbackDirection == .rightToLeft ? 3 : 0)
            byte(0x20)
            byte(0x53)
        }
        if previous?.boxMirroring != state.boxMirroring {
            csi(private: true, 2500, final: state.boxMirroring ? 0x68 : 0x6c)
        }
        bidi = state
    }

    /// The cursor, including the pending wrap at the last column, which only
    /// a print can make.
    private mutating func writeCursor() {
        let buffer = terminal.buffer
        let y = min(max(buffer.y, 0), rows - 1)
        let cursorX = min(max(buffer.x, 0), cols)
        guard cursorX == cols else {
            cursorTo(row: y, col: cursorX)
            return
        }
        if makePendingWrap(onRow: y, of: buffer) {
            return
        }
        // That row's last cell would join the one before it if printed again.
        // Make the pending wrap on the nearest row where it can be, then VPA,
        // which moves the cursor up or down and leaves the column alone.
        for distance in 1..<max(rows, 1) {
            for other in [y - distance, y + distance] where other >= 0 && other < rows {
                if makePendingWrap(onRow: other, of: buffer) {
                    csi(y + 1, final: 0x64)
                    row = y
                    return
                }
            }
        }
        cursorTo(row: y, col: cols - 1)
    }

    /// Writes the last cell of screen row `target` again by printing it, which
    /// leaves the cursor past the last column. False, having written nothing,
    /// when that print would join the cell to the one before it.
    private mutating func makePendingWrap(onRow target: Int, of buffer: Buffer) -> Bool {
        let index = buffer.yBase + target
        guard index >= 0, index < buffer.lines.count else { return false }
        let line = buffer.lines[index]
        let count = min(line.count, cols)
        var last = cols - 1
        if cols >= 2, cols - 2 < count {
            let head = classify(line, cols - 2, count: count)
            if head.kind == .text && head.width == 2 {
                last = cols - 2
            }
        }
        if last == cols - 1 && isSpacer(line, last, count: count) {
            // The second half of a wide character on its own: REP copies the
            // one before it, if that is the same.
            guard cols >= 2, isSpacer(line, cols - 2, count: count) || hasTail(line, cols - 3, count: count),
                  sameCell(line, cols - 2, cols - 1) else {
                return false
            }
            cursorTo(row: target, col: cols - 1)
            csi(1, final: 0x62)
            x = cols
            return true
        }
        let cell = classify(line, last, count: count)
        switch cell.kind {
        case .text:
            if last > 0 {
                var left = last - 1
                if left > 0, line.packedCell(at: left).widthState == .spacerTail {
                    left -= 1
                }
                let previous = classify(line, left, count: count)
                if previous.kind == .text && mayJoin(previous.last, cell.first) {
                    return false
                }
            }
            cursorTo(row: target, col: last)
            printCell(line, last, cell)
        case .blank, .framed:
            // A space makes the wrap, then DECFRA puts back what was there.
            cursorTo(row: target, col: cols - 1)
            byte(0x20)
            x = cols
            if cell.kind == .blank {
                setAttribute(blankAttribute(line, last, count: count))
                fillRectangle(0, top: target, left: cols - 1, bottom: target, right: cols - 1)
            } else {
                frameCell(line, last, onRow: target)
            }
        }
        return true
    }

    /// Modes, titles, palette, character sets and the attribute and link in
    /// use. Nothing here moves the cursor or prints.
    private mutating func writeModes() {
        let t = terminal
        func mode(_ number: Int, _ on: Bool) {
            csi(private: true, number, final: on ? 0x68 : 0x6c)
        }
        if t.originMode { mode(6, true) }
        if t.marginMode { mode(69, true) }
        if t.insertMode { csi(4, final: 0x68) }
        if t.reverseWraparound {
            mode(7, true)
            mode(45, true)
        } else {
            mode(45, false)
        }
        if !t.wraparound { mode(7, false) }
        if t.applicationCursor { mode(1, true) }
        if t.applicationKeypad { esc(0x3d) }
        mode(25, !t.cursorHidden)
        if t.cursorBlink { mode(12, true) }
        csiStart()
        decimal(t.options.cursorStyle.decscusrParameter)
        byte(0x20)
        byte(0x71)
        if t.reverseColors { mode(5, true) }
        mode(4, t.smoothScroll)
        if t.allow80To132 { mode(40, true) }
        csi(20, final: t.lineFeedMode ? 0x68 : 0x6c)

        switch t.mouseMode {
        case .off: break
        case .x10: mode(9, true)
        case .vt200: mode(1000, true)
        case .buttonEventTracking: mode(1002, true)
        case .anyEvent: mode(1003, true)
        }
        switch t.mirrorMouseProtocol {
        case .x10: mode(1006, false)
        case .utf8: mode(1005, true)
        case .sgr: mode(1006, true)
        case .urxvt: mode(1015, true)
        case .sgrPixel: mode(1016, true)
        }
        if t.mouseShiftCapture {
            csiStart()
            byte(0x3e)
            decimal(1)
            byte(0x73)
        }
        mode(1004, t.sendFocus)
        if !t.alternateScrollMode { mode(1007, false) }
        // Set either way: restoring XTSAVE's modes above may have changed them.
        mode(SpecialDECPrivateMode.bracketedPaste.rawValue, t.bracketedPasteMode)
        mode(SpecialDECPrivateMode.colorSchemeReports.rawValue, t.colorSchemeUpdatesEnabled)
        mode(SpecialDECPrivateMode.visibilityReports.rawValue, t.visibilityReportsEnabled)
        mode(SpecialDECPrivateMode.inBandSizeReports.rawValue, t.inBandSizeReportsEnabled)
        mode(SpecialDECPrivateMode.kittyPasteEvents.rawValue, t.kittyPasteEventsEnabled)

        // OSC 104 puts the receiver's own palette back, then the entries the
        // program changed go over it.
        osc(104, text: nil)
        for index in 0..<min(t.ansiColors.count, t.defaultAnsiColors.count)
            where t.ansiColors[index] != t.defaultAnsiColors[index] {
            osc(4, text: "\(index);\(t.ansiColors[index].formatAsXcolor())")
        }
        osc(2, text: t.terminalTitle)
        osc(1, text: t.iconTitle)

        let charsets = t.mirrorCharsets
        for (index, table) in charsets.designated.enumerated() where index < 4 {
            guard let table else { continue }
            if let code = charsetCode(table) {
                designate(index, code)
            }
        }
        switch t.gLevel {
        case 0: break
        case 1: byte(0x0e)
        case 2: esc(0x6e)
        case 3: esc(0x6f)
        default: break
        }

        setAttribute(t.currentAttribute)
        setLink(t.mirrorActiveHyperlink)
    }

    // MARK: Attributes and links

    /// What the receiver can hold: SGR has no default-inverted colour, and
    /// the underline flag and style always go together.
    private func representable(_ attribute: Attribute) -> Attribute {
        func plain(_ color: Attribute.Color) -> Attribute.Color {
            color == .defaultInvertedColor ? .defaultColor : color
        }
        var style = attribute.style
        var underline = attribute.underlineStyle
        if style.contains(.underline) && underline == .none {
            underline = .single
        } else if !style.contains(.underline) && underline != .none {
            style.insert(.underline)
        }
        var underlineColor = attribute.underlineColor
        if underlineColor == .defaultColor || underlineColor == .defaultInvertedColor {
            underlineColor = nil
        }
        return Attribute(fg: plain(attribute.fg), bg: plain(attribute.bg), style: style,
                         underlineStyle: underline, underlineColor: underlineColor)
    }

    /// The cell that ECH and a scroll leave behind under `attribute`.
    private func eraseAttribute(_ attribute: Attribute) -> Attribute {
        Attribute(fg: .defaultColor, bg: attribute.bg, style: .none)
    }

    private mutating func setBackground(_ background: Attribute.Color) {
        guard sgr.bg != background else { return }
        setAttribute(Attribute(fg: sgr.fg, bg: background, style: sgr.style,
                               underlineStyle: sgr.underlineStyle,
                               underlineColor: sgr.underlineColor))
    }

    private mutating func setAttribute(_ attribute: Attribute) {
        let next = representable(attribute)
        sgrKey = nil
        guard next != sgr else { return }
        writeSGR(from: sgr, to: next)
        sgr = next
    }

    /// SGR from one attribute to the next, naming only what changes.
    private mutating func writeSGR(from old: Attribute, to new: Attribute) {
        if new == CharData.defaultAttr {
            csiStart()
            byte(0x6d)
            return
        }
        sgrCount = 0
        let was = old.style
        let now = new.style
        if (was.contains(.bold) && !now.contains(.bold)) || (was.contains(.dim) && !now.contains(.dim)) {
            sgrParameter(22)
            if now.contains(.bold) { sgrParameter(1) }
            if now.contains(.dim) { sgrParameter(2) }
        } else {
            if now.contains(.bold) && !was.contains(.bold) { sgrParameter(1) }
            if now.contains(.dim) && !was.contains(.dim) { sgrParameter(2) }
        }
        sgrToggle(.italic, was, now, 3, 23)
        sgrToggle(.blink, was, now, 5, 25)
        sgrToggle(.inverse, was, now, 7, 27)
        sgrToggle(.invisible, was, now, 8, 28)
        sgrToggle(.crossedOut, was, now, 9, 29)
        if new.underlineStyle != old.underlineStyle {
            switch new.underlineStyle {
            case .none: sgrParameter(24)
            case .single: sgrParameter(4)
            default:
                // 4:n, the colon form the parser reads as an underline style.
                sgrParameter(4)
                byte(0x3a)
                decimal(Int(new.underlineStyle.rawValue))
            }
        }
        if new.fg != old.fg { sgrColor(new.fg, base: 30, extended: 38) }
        if new.bg != old.bg { sgrColor(new.bg, base: 40, extended: 48) }
        if new.underlineColor != old.underlineColor {
            sgrColor(new.underlineColor, base: 0, extended: 58)
        }
        if sgrCount > 0 {
            byte(0x6d)
        }
    }

    private var sgrCount = 0

    /// Starts one SGR parameter group of `size` values. The parser drops a
    /// sequence of more than 24 parameters, so a long change takes two.
    private mutating func sgrGroup(_ size: Int) {
        if sgrCount + size > 16 {
            byte(0x6d)
            sgrCount = 0
        }
        if sgrCount == 0 {
            csiStart()
        } else {
            byte(0x3b)
        }
        sgrCount += size
    }

    private mutating func sgrParameter(_ value: Int) {
        sgrGroup(1)
        decimal(value)
    }

    private mutating func sgrToggle(_ flag: CharacterStyle, _ was: CharacterStyle, _ now: CharacterStyle,
                                    _ on: Int, _ off: Int) {
        let isOn = now.contains(flag)
        if isOn != was.contains(flag) {
            sgrParameter(isOn ? on : off)
        }
    }

    private mutating func sgrColor(_ color: Attribute.Color?, base: Int, extended: Int) {
        switch color {
        case nil, .defaultColor?, .defaultInvertedColor?:
            sgrParameter(extended + 1)
        case .ansi256(let code)? where base > 0 && code < 8:
            sgrParameter(base + Int(code))
        case .ansi256(let code)? where base > 0 && code < 16:
            sgrParameter(base + 60 + Int(code) - 8)
        case .ansi256(let code)?:
            sgrGroup(3)
            decimal(extended)
            byte(0x3b)
            byte(0x35)
            byte(0x3b)
            decimal(Int(code))
        case .trueColor(let red, let green, let blue)?:
            sgrGroup(5)
            decimal(extended)
            byte(0x3b)
            byte(0x32)
            byte(0x3b)
            decimal(Int(red))
            byte(0x3b)
            decimal(Int(green))
            byte(0x3b)
            decimal(Int(blue))
        }
    }

    private mutating func linkName(_ code: UInt16) -> String? {
        guard code != 0 else { return nil }
        if let cached = linkNames[code] {
            return cached
        }
#if SWIFTTERM_EMBEDDED
        let name = TinyAtom.stored(code: code).target
#else
        let name = TinyAtom.stored(code: code).target as? String
#endif
        linkNames.updateValue(name, forKey: code)
        return name
    }

    private mutating func setLink(_ name: String?) {
        guard name != link else { return }
        // OSC 8 keeps everything after "8;" as the link, so it goes back as
        // it came. A lone ";" ends the link.
        osc(8, text: name ?? ";")
        link = name
    }

    // MARK: Character sets

    private func charsetCode(_ table: [UInt8: String]) -> UInt8? {
        if table.isEmpty {
            return 0x42
        }
        return CharSets.all.first(where: { $0.value == table })?.key
    }

    private mutating func designate(_ set: Int, _ code: UInt8) {
        esc2([0x28, 0x29, 0x2a, 0x2b][set], code)
    }

    // MARK: Bytes

    private mutating func moveTo(_ col: Int) {
        guard col != x else { return }
        if col > x && x < cols {
            csi(col - x, final: 0x43)
        } else {
            csi(col + 1, final: 0x47)
        }
        x = col
    }

    private mutating func cursorTo(row target: Int, col: Int) {
        csi(target + 1, col + 1, final: 0x48)
        row = target
        x = col
    }

    /// DECFRA: fills the rectangle with `character` in the current attribute,
    /// leaving the cursor where it is. Character 0 makes blank cells.
    private mutating func fillRectangle(_ character: Int, top: Int, left: Int, bottom: Int, right: Int) {
        csiStart()
        decimal(character)
        byte(0x3b)
        decimal(top + 1)
        byte(0x3b)
        decimal(left + 1)
        byte(0x3b)
        decimal(bottom + 1)
        byte(0x3b)
        decimal(right + 1)
        byte(0x24)
        byte(0x78)
    }

    private mutating func csiKitty(_ prefix: UInt8, _ flags: Int, mode: Int?) {
        csiStart()
        byte(prefix)
        decimal(flags)
        if let mode {
            byte(0x3b)
            decimal(mode)
        }
        byte(0x75)
    }

    private mutating func osc(_ code: Int, text: String?) {
        byte(0x1b)
        byte(0x5d)
        decimal(code)
        if let text {
            byte(0x3b)
            out.append(contentsOf: text.utf8)
        }
        byte(0x1b)
        byte(0x5c)
    }

    @inline(__always)
    private mutating func byte(_ value: UInt8) {
        out.append(value)
    }

    private mutating func esc(_ code: UInt8) {
        byte(0x1b)
        byte(code)
    }

    private mutating func esc2(_ intermediate: UInt8, _ code: UInt8) {
        byte(0x1b)
        byte(intermediate)
        byte(code)
    }

    private mutating func escHash(_ code: UInt8) {
        esc2(0x23, code)
    }

    private mutating func csiStart() {
        byte(0x1b)
        byte(0x5b)
    }

    private mutating func csi(final: UInt8) {
        csiStart()
        byte(final)
    }

    private mutating func csi(private isPrivate: Bool = false, _ value: Int, final: UInt8) {
        csiStart()
        if isPrivate {
            byte(0x3f)
        }
        decimal(value)
        byte(final)
    }

    private mutating func csi(_ first: Int, _ second: Int, final: UInt8) {
        csiStart()
        decimal(first)
        byte(0x3b)
        decimal(second)
        byte(final)
    }

    private mutating func decimal(_ value: Int) {
        let value = max(value, 0)
        var divisor = 1
        while divisor <= value / 10 {
            divisor *= 10
        }
        while divisor > 0 {
            out.append(0x30 + UInt8(value / divisor % 10))
            divisor /= 10
        }
    }

    @inline(__always)
    private mutating func utf8(_ value: UInt32) {
        if value < 0x80 {
            out.append(UInt8(value))
        } else if value < 0x800 {
            out.append(0xc0 | UInt8(value >> 6))
            out.append(0x80 | UInt8(value & 0x3f))
        } else if value < 0x10000 {
            out.append(0xe0 | UInt8(value >> 12))
            out.append(0x80 | UInt8((value >> 6) & 0x3f))
            out.append(0x80 | UInt8(value & 0x3f))
        } else {
            out.append(0xf0 | UInt8(value >> 18))
            out.append(0x80 | UInt8((value >> 12) & 0x3f))
            out.append(0x80 | UInt8((value >> 6) & 0x3f))
            out.append(0x80 | UInt8(value & 0x3f))
        }
    }
}
