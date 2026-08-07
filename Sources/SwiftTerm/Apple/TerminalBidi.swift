//
//  TerminalBidi.swift
//  SwiftTerm
//
//  Cell-level bidirectional text support (Arabic/Hebrew) for the terminal view,
//  following the "implicit BiDi" model recommended by the terminal-wg BiDi
//  specification (the model used by mlterm): the buffer stays in logical order,
//  and at render time each row is given a visual permutation of its cells plus
//  per-cell display substitutions (Arabic contextual forms, mirrored brackets).
//
//  Ordering is delegated to CoreText's UAX #9 implementation: a "probe" line is
//  built with exactly one UTF-16 unit per cell, where Arabic letters are replaced
//  by U+0621 (non-joining, Bidi_Class AL) so that no ligatures or contextual
//  shaping can merge glyphs, guaranteeing a 1:1 glyph-to-cell mapping. The visual
//  order of cells is then recovered from the glyph positions of the CTLine.
//
#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation
import CoreText
import CoreGraphics

/// A cell in visual order, produced by `TerminalBidi.layout`.
struct BidiCell {
    /// The buffer (logical) column this cell came from.
    let logicalCol: Int
    /// Number of columns the cell occupies.
    let width: Int
    /// When non-nil, render this instead of the buffer character
    /// (contextually shaped Arabic form, lam-alef ligature, or mirrored bracket).
    let display: Character?
}

/// The visual layout of one terminal row after BiDi processing.
struct BidiRowLayout {
    /// Cells in visual (left-to-right screen) order.
    let visualCells: [BidiCell]
    /// Maps a logical column to the visual column where it is displayed.
    let logicalToVisualCol: [Int]
    /// Maps a visual column back to the logical buffer column.
    let visualToLogicalCol: [Int]
    /// The resolved paragraph base direction.
    let baseDirection: BidiDirection
    /// Changes when any row in the paragraph changes.
    let paragraphRevision: Int
}

enum TerminalBidi {

    // MARK: - Row scanning

    /// Fast check: does this scalar require BiDi processing?
    /// Covers Hebrew through Arabic Extended-A contiguously, the presentation
    /// form blocks, and the RTL directional formatting characters.
    @inline(__always)
    static func isRTLTrigger(_ v: UInt32) -> Bool {
        if v < 0x0590 { return false }
        switch v {
        case 0x0590...0x08FF,           // Hebrew ... Arabic Extended-A
             0xFB1D...0xFDFF,           // Hebrew/Arabic presentation forms A
             0xFE70...0xFEFC,           // Arabic presentation forms B
             0x10800...0x10FFF,         // historic right-to-left scripts
             0x1E800...0x1EFFF,         // Mende, Adlam, and Arabic math
             0x200F, 0x202B, 0x202E,    // RLM, RLE, RLO
             0x2067:                    // RLI
            return true
        default:
            return false
        }
    }

    // MARK: - Arabic joining classification

    enum Joining {
        case none         // U: non-joining
        case transparent  // T: combining marks, skipped when finding neighbors
        case causing      // C: tatweel, ZWJ
        case right        // R: joins only with the preceding letter
        case left         // L: joins only with the following letter
        case dual         // D: joins on both sides
    }

    static func joining(of v: UInt32) -> Joining {
        if v == 0x200C { // ZWNJ
            return .none
        }
        var lower = 0
        var upper = unicode17JoiningRanges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let entry = unicode17JoiningRanges[middle]
            if v < entry.0.lowerBound {
                upper = middle
            } else if v > entry.0.upperBound {
                lower = middle + 1
            } else {
                return entry.1
            }
        }
        if let scalar = UnicodeScalar(v) {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format:
                return .transparent
            default:
                break
            }
        }
        return .none
    }

    /// Lam-alef ligatures: alef variant -> (isolated, final) ligature form.
    static let lamAlef: [UInt32: (iso: UInt32, fin: UInt32)] = [
        0x0622: (0xFEF5, 0xFEF6),   // لآ
        0x0623: (0xFEF7, 0xFEF8),   // لأ
        0x0625: (0xFEF9, 0xFEFA),   // لإ
        0x0627: (0xFEFB, 0xFEFC),   // لا
    ]

    /// Horizontally asymmetric box drawing characters, mirrored on RTL-level
    /// cells when DECSET 2500 (terminal-wg box mirroring) is active.
    static let boxMirror: [Character: Character] = [
        "┌": "┐", "┐": "┌", "└": "┘", "┘": "└", "├": "┤", "┤": "├",
        "┏": "┓", "┓": "┏", "┗": "┛", "┛": "┗", "┣": "┫", "┫": "┣",
        "╔": "╗", "╗": "╔", "╚": "╝", "╝": "╚", "╠": "╣", "╣": "╠",
        "╭": "╮", "╮": "╭", "╰": "╯", "╯": "╰",
        "╒": "╕", "╕": "╒", "╘": "╛", "╛": "╘", "╓": "╖", "╖": "╓",
        "╙": "╜", "╜": "╙", "╞": "╡", "╡": "╞", "╟": "╢", "╢": "╟",
        "╴": "╶", "╶": "╴", "╸": "╺", "╺": "╸",
    ]

    /// True for cells that must be rendered as their own column-anchored
    /// segment in BiDi rows: Arabic-script cells (a font may apply required
    /// ligatures across adjacent presentation forms — e.g. compressing الله —
    /// merging glyphs and shifting the column mapping of the rest of the
    /// segment) and any multi-scalar cell (combining marks, emoji).
    @inline(__always)
    static func needsCellIsolation(_ text: Character) -> Bool {
        if text.unicodeScalars.count > 1 { return true }
        guard let v = text.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x08FF,
             0xFB50...0xFDFF, 0xFE70...0xFEFC:
            return true
        default:
            return false
        }
    }

    // MARK: - Cell extraction

    struct Cell: Equatable {
        let row: Int
        let logicalCol: Int
        let width: Int
        let text: Character

        init(row: Int = 0, logicalCol: Int, width: Int, text: Character) {
            self.row = row
            self.logicalCol = logicalCol
            self.width = width
            self.text = text
        }
    }

    /// Returns true when a row can require a BiDi pass. Pure ASCII rows do not
    /// allocate and do not call `Terminal.getCharacter(for:)`.
    static func mayNeedBidi(line: BufferLine, cols: Int, terminal: Terminal) -> Bool {
        var col = 0
        let count = min(cols, line.count)
        while col < count {
            let ch = line[col]
            let width = max(1, Int(ch.width))
            if ch.code >= 0x0590 && ch.code < CharData.maxRune {
                if isRTLTrigger(UInt32(ch.code)) {
                    return true
                }
            } else if ch.code >= CharData.maxRune {
                let character = terminal.getCharacter(for: ch)
                for scalar in character.unicodeScalars where isRTLTrigger(scalar.value) {
                    return true
                }
            }
            col += width
        }
        return false
    }

    /// Extracts the non-erased cells of one row. CoreText indices stay local
    /// to this adapter. SwiftTerm continues to use grapheme clusters and cells.
    static func appendCells(line: BufferLine, row: Int, cols: Int,
                            terminal: Terminal, to cells: inout [Cell]) -> Int {
        let contentLimit = min(cols, line.count, line.getTrimmedLength())
        var col = 0
        while col < contentLimit {
            let ch = line[col]
            let width = max(1, Int(ch.width))
            let character: Character = ch.code == 0 ? " " : terminal.getCharacter(for: ch)
            cells.append(Cell(row: row, logicalCol: col, width: width, text: character))
            col += width
        }
        return col
    }

    // MARK: - Visual ordering via CoreText (UAX #9)

    /// True for scalars that can shape or ligate under Arabic script rules and
    /// must therefore be substituted in the probe line.
    @inline(__always)
    static func isJoiningCapable(_ v: UInt32) -> Bool {
        switch v {
        case 0x0620...0x064A, 0x066E...0x066F, 0x0671...0x06D5,
             0x06EE, 0x06EF, 0x06FA...0x06FF, 0x0750...0x077F,
             0x0870...0x088F, 0x08A0...0x08D2, 0x200D:
            return true
        default:
            return false
        }
    }

    /// Builds the probe scalar for a cell: one BMP, non-joining, non-combining
    /// UTF-16 unit with the same Bidi_Class as the cell's first scalar.
    static func probeScalar(for text: Character) -> unichar {
        guard let first = text.unicodeScalars.first else { return 0x20 }
        let v = first.value
        if first.properties.canonicalCombiningClass != .notReordered
            || first.properties.generalCategory == .nonspacingMark
            || first.properties.generalCategory == .enclosingMark {
            return 0x00B7  // lone combining mark: neutral placeholder (ON)
        }
        if isJoiningCapable(v) {
            return 0x0621  // hamza: Bidi_Class AL, Joining_Type U
        }
        if v > 0xFFFF && isRTLTrigger(v) {
            return 0x200F  // astral RTL letter: one-unit strong R probe
        }
        if v > 0xFFFF {
            return 0x00B7  // astral (emoji etc.): neutral placeholder (ON)
        }
        return unichar(v)
    }

    /// Computes the visual order for one soft-wrapped row. The typesetter owns
    /// the full paragraph, so weak and neutral characters keep paragraph context.
    static func computeVisualOrder(range: Range<Int>, typesetter: CTTypesetter,
                                   baseDirection: BidiDirection)
        -> (order: [Int], rtl: [Bool])? {
        let count = range.count
        if count == 0 {
            return ([], [])
        }
        let ctLine = CTTypesetterCreateLine(typesetter,
                                            CFRange(location: range.lowerBound,
                                                    length: count))
        guard let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] else {
            return nil
        }

        var entries: [(x: CGFloat, index: Int)] = []
        entries.reserveCapacity(count)
        var resolvedRTL = [Bool?](repeating: nil, count: count)
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            if glyphCount == 0 {
                continue
            }
            let isRTLRun = CTRunGetStatus(run).contains(.rightToLeft)
            var indices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetStringIndices(run, CFRange(), &indices)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetPositions(run, CFRange(), &positions)
            for offset in 0..<glyphCount {
                let localIndex = indices[offset] - range.lowerBound
                guard localIndex >= 0 && localIndex < count else {
                    continue
                }
                entries.append((positions[offset].x, localIndex))
                resolvedRTL[localIndex] = isRTLRun
            }
        }
        entries.sort {
            if $0.x == $1.x {
                return $0.index < $1.index
            }
            return $0.x < $1.x
        }

        var order: [Int] = []
        order.reserveCapacity(count)
        var seen = Set<Int>()
        for entry in entries where seen.insert(entry.index).inserted {
            order.append(entry.index)
        }

        func inferredRTL(at index: Int) -> Bool {
            var distance = 1
            while index - distance >= 0 || index + distance < count {
                if index - distance >= 0, let value = resolvedRTL[index - distance] {
                    return value
                }
                if index + distance < count, let value = resolvedRTL[index + distance] {
                    return value
                }
                distance += 1
            }
            return baseDirection == .rightToLeft
        }

        // Formatting controls can have no glyph. Insert each one next to the
        // nearest neighbor whose run direction CoreText resolved.
        if order.count < count {
            for index in 0..<count where !seen.contains(index) {
                let isRTL = inferredRTL(at: index)
                resolvedRTL[index] = isRTL
                if let position = order.firstIndex(of: index - 1) {
                    order.insert(index, at: isRTL ? position : position + 1)
                } else if let position = order.firstIndex(of: index + 1) {
                    order.insert(index, at: isRTL ? position + 1 : position)
                } else {
                    order.append(index)
                }
                seen.insert(index)
            }
        }
        guard order.count == count else {
            return nil
        }
        return (order, resolvedRTL.map { $0 ?? (baseDirection == .rightToLeft) })
    }

    // MARK: - Arabic contextual shaping (cell level)

    /// Computes per-cell display substitutions for Arabic contextual forms and
    /// lam-alef ligatures. Operates on cells in logical order so that color or
    /// attribute changes never break joining. Combining marks stored beyond
    /// the base scalar of a cell (harakat) are preserved after the
    /// substituted presentation form; the renderer's per-cluster column
    /// mapping keeps them overlaid on their base cell.
    ///
    /// The input contains the full paragraph. A soft wrap does not break the
    /// joining context.
    static func shapeArabic(cells: [Cell]) -> [Character?] {
        let n = cells.count
        var result = [Character?](repeating: nil, count: n)

        func baseScalar(_ i: Int) -> UInt32 {
            cells[i].text.unicodeScalars.first?.value ?? 0x20
        }
        // Find the joining neighbor and skip transparent cells.
        func neighbor(from i: Int, step: Int) -> Joining {
            var j = i + step
            while j >= 0 && j < n {
                let kind = joining(of: baseScalar(j))
                if kind != .transparent { return kind }
                j += step
            }
            return .none
        }

        var i = 0
        while i < n {
            let v = baseScalar(i)
            let kind = joining(of: v)
            guard kind == .dual || kind == .right else {
                // Non-joining letters with a presentation form (hamza) still
                // get their explicit isolated form for rendering consistency.
                if kind == .none, let form = unicode17Forms[v] {
                    var text = String(UnicodeScalar(form.iso)!)
                    for scalar in cells[i].text.unicodeScalars.dropFirst() {
                        text.unicodeScalars.append(scalar)
                    }
                    result[i] = Character(text)
                }
                i += 1
                continue
            }
            let prevConnects: Bool = {
                let p = neighbor(from: i, step: -1)
                let previousJoinsForward = p == .dual || p == .left || p == .causing
                let currentJoinsBackward = kind == .dual || kind == .right || kind == .causing
                return previousJoinsForward && currentJoinsBackward
            }()

            // Retains any combining marks (harakat) stored after the base
            // scalar of a cell.
            func withMarks(_ shaped: UInt32, from sourceCells: [Cell]) -> Character {
                var text = String(UnicodeScalar(shaped)!)
                for cell in sourceCells {
                    for scalar in cell.text.unicodeScalars.dropFirst() {
                        text.unicodeScalars.append(scalar)
                    }
                }
                return Character(text)
            }

            // Lam followed by an alef variant in the adjacent cell forms the
            // mandatory lam-alef ligature: the ligature glyph goes in the lam
            // cell and the alef cell is blanked.
            if v == 0x0644, i + 1 < n, let lig = lamAlef[baseScalar(i + 1)] {
                let form = prevConnects ? lig.fin : lig.iso
                result[i] = withMarks(form, from: [cells[i], cells[i + 1]])
                result[i + 1] = " "
                i += 2
                continue
            }

            guard let form = unicode17Forms[v] else {
                i += 1
                continue
            }
            let nextKind = neighbor(from: i, step: 1)
            let currentJoinsForward = kind == .dual || kind == .left || kind == .causing
            let nextJoinsBackward = nextKind == .dual || nextKind == .right || nextKind == .causing
            let nextConnects = currentJoinsForward && nextJoinsBackward
            let shaped: UInt32
            if kind == .right {
                shaped = prevConnects ? form.fin : form.iso
            } else if prevConnects && nextConnects, let med = form.med {
                shaped = med
            } else if prevConnects {
                shaped = form.fin
            } else if nextConnects, let ini = form.ini {
                shaped = ini
            } else {
                shaped = form.iso
            }
            result[i] = withMarks(shaped, from: [cells[i]])
            i += 1
        }
        return result
    }

    // MARK: - Full paragraph layout

    private struct ParagraphKey: Hashable {
        let buffer: ObjectIdentifier
        let firstRow: Int
        let lastRow: Int
        let revision: Int
        let cols: Int
        let font: ObjectIdentifier
        let state: BidiPresentationState
    }

    private struct ParagraphResult {
        let rows: [Int: BidiRowLayout]
        let baseDirection: BidiDirection
    }

    /// Position-independent cache key: the layout of a paragraph is a pure
    /// function of its cell content, the column count, the font, and the
    /// presentation state — not of the buffer rows it happens to occupy. This
    /// is what lets a scrolling paragraph reuse its layout at every new row.
    private struct ParagraphContentKey: Hashable {
        let contentHash: Int
        let rowCount: Int
        let cols: Int
        let font: ObjectIdentifier
        let state: BidiPresentationState
    }

    /// A cached layout in paragraph-relative coordinates (row offsets from the
    /// paragraph's first row). `cells` keeps the full extracted content: a hit
    /// is served only after an exact cell-by-cell comparison, so a content-hash
    /// collision can never surface another paragraph's layout.
    private struct CachedParagraph {
        let cells: [Cell]
        let rowsByOffset: [BidiRowLayout?]
        let baseDirection: BidiDirection

        func matches(cells other: [Cell], firstRow: Int) -> Bool {
            if cells.count != other.count {
                return false
            }
            for index in 0..<cells.count {
                let stored = cells[index]
                let candidate = other[index]
                if stored.row != candidate.row - firstRow
                    || stored.logicalCol != candidate.logicalCol
                    || stored.width != candidate.width
                    || stored.text != candidate.text {
                    return false
                }
            }
            return true
        }
    }

    private static let cacheLock = NSLock()
    private static var paragraphCache: [ParagraphKey: ParagraphResult] = [:]
    private static var contentCache: [ParagraphContentKey: CachedParagraph] = [:]

    /// Test hooks: exercised by BidiCacheTests to prove hits happen where
    /// expected and to force fresh computation for staleness comparisons.
    static var _contentCacheHits = 0
    static var _contentCacheMisses = 0
    static func _testResetCaches() {
        cacheLock.lock()
        paragraphCache.removeAll()
        contentCache.removeAll()
        _contentCacheHits = 0
        _contentCacheMisses = 0
        cacheLock.unlock()
    }

    private static func contentKey(cells: [Cell], firstRow: Int, rowCount: Int,
                                   cols: Int, font: AnyObject,
                                   state: BidiPresentationState) -> ParagraphContentKey {
        var hasher = Hasher()
        hasher.combine(cells.count)
        for cell in cells {
            hasher.combine(cell.row - firstRow)
            hasher.combine(cell.logicalCol)
            hasher.combine(cell.width)
            hasher.combine(cell.text)
        }
        return ParagraphContentKey(contentHash: hasher.finalize(),
                                   rowCount: rowCount,
                                   cols: cols,
                                   font: ObjectIdentifier(font),
                                   state: state)
    }

    /// Rehomes a cached paragraph-relative layout onto absolute buffer rows,
    /// restamping the revision the fresh build would have produced.
    private static func rebase(_ entry: CachedParagraph, bounds: ClosedRange<Int>,
                               revision: Int) -> ParagraphResult {
        var rows: [Int: BidiRowLayout] = [:]
        rows.reserveCapacity(entry.rowsByOffset.count)
        for (offset, layout) in entry.rowsByOffset.enumerated() {
            guard let layout else {
                continue
            }
            rows[bounds.lowerBound + offset] = BidiRowLayout(
                visualCells: layout.visualCells,
                logicalToVisualCol: layout.logicalToVisualCol,
                visualToLogicalCol: layout.visualToLogicalCol,
                baseDirection: layout.baseDirection,
                paragraphRevision: revision)
        }
        return ParagraphResult(rows: rows, baseDirection: entry.baseDirection)
    }

    /// Finds a paragraph without visiting more than `maximumRows` rows. A nil
    /// result means that the row is invalid or that the paragraph is too large
    /// for paragraph-wide rendering.
    private static func paragraphBounds(row: Int, buffer: Buffer,
                                        maximumRows: Int) -> ClosedRange<Int>? {
        guard row >= 0, row < buffer.lines.count else {
            return nil
        }
        let limit = max(1, maximumRows)
        var first = row
        var count = 1
        while first > 0 && buffer.lines[first].isWrapped {
            guard count < limit else {
                return nil
            }
            first -= 1
            count += 1
        }
        var last = row
        while last + 1 < buffer.lines.count && buffer.lines[last + 1].isWrapped {
            guard count < limit else {
                return nil
            }
            last += 1
            count += 1
        }
        return first...last
    }

    private static func paragraphRevision(_ bounds: ClosedRange<Int>, buffer: Buffer) -> Int {
        var hasher = Hasher()
        for row in bounds {
            let line = buffer.lines[row]
            hasher.combine(ObjectIdentifier(line))
            hasher.combine(line.generation)
            hasher.combine(line.isWrapped)
        }
        return hasher.finalize()
    }

    private static func detectedBaseDirection(cells: [Cell], fallback: BidiDirection) -> BidiDirection {
        for cell in cells {
            for scalar in cell.text.unicodeScalars {
                let value = scalar.value
                if value == 0x200F {
                    return .rightToLeft
                }
                if value == 0x200E {
                    return .leftToRight
                }
                if isRTLTrigger(value) && scalar.properties.isAlphabetic {
                    return .rightToLeft
                }
                if scalar.properties.isAlphabetic {
                    return .leftToRight
                }
            }
        }
        return fallback
    }

    private static func makeTypesetter(cells: [Cell], direction: BidiDirection,
                                       font: AnyObject) -> CTTypesetter? {
        guard !cells.isEmpty else {
            return nil
        }
        var units = [unichar](repeating: 0, count: cells.count)
        for (index, cell) in cells.enumerated() {
            units[index] = probeScalar(for: cell.text)
        }
        let probe = NSString(characters: &units, length: units.count)
        var writingDirection: CTWritingDirection = direction == .rightToLeft
            ? .rightToLeft : .leftToRight
        let style: CTParagraphStyle = withUnsafeMutableBytes(of: &writingDirection) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .baseWritingDirection,
                valueSize: MemoryLayout<CTWritingDirection>.size,
                value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let ligature = 0 as CFNumber
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            NSAttributedString.Key(kCTLigatureAttributeName as String): ligature,
        ]
        let attributed = NSAttributedString(string: probe as String, attributes: attributes)
        return CTTypesetterCreateWithAttributedString(attributed)
    }

    private static func buildParagraph(bounds: ClosedRange<Int>,
                                       cells: [Cell],
                                       ranges: [Int: Range<Int>],
                                       usedColumns: [Int: Int],
                                       cols: Int, font: AnyObject,
                                       state: BidiPresentationState,
                                       hasPotentialRTL: Bool,
                                       revision: Int) -> ParagraphResult {
        let baseDirection = state.autodetectDirection
            ? detectedBaseDirection(cells: cells, fallback: state.fallbackDirection)
            : state.fallbackDirection
        if !hasPotentialRTL && baseDirection == .leftToRight {
            return ParagraphResult(rows: [:], baseDirection: baseDirection)
        }

        let typesetter = makeTypesetter(cells: cells, direction: baseDirection, font: font)
        var display = shapeArabic(cells: cells)
        var rowOrders: [Int: (order: [Int], rtl: [Bool])] = [:]
        for row in bounds {
            guard let range = ranges[row] else {
                continue
            }
            if range.isEmpty {
                rowOrders[row] = ([], [])
            } else if let typesetter,
                      let resolved = computeVisualOrder(range: range, typesetter: typesetter,
                                                        baseDirection: baseDirection) {
                rowOrders[row] = resolved
                for localIndex in 0..<range.count where resolved.rtl[localIndex]
                    && display[range.lowerBound + localIndex] == nil {
                    let cellIndex = range.lowerBound + localIndex
                    let cell = cells[cellIndex]
                    if cell.text.unicodeScalars.count == 1,
                       let source = cell.text.unicodeScalars.first?.value,
                       let mirroredValue = unicode17Mirror[source],
                       let mirrored = UnicodeScalar(mirroredValue) {
                        display[cellIndex] = Character(mirrored)
                    } else if state.boxMirroring, let mirrored = boxMirror[cell.text] {
                        display[cellIndex] = mirrored
                    }
                }
            }
        }

        var layouts: [Int: BidiRowLayout] = [:]
        for row in bounds {
            guard let range = ranges[row], let resolved = rowOrders[row] else {
                continue
            }
            let used = min(cols, usedColumns[row] ?? 0)
            var visualCells: [BidiCell] = []
            visualCells.reserveCapacity(range.count + max(0, cols - used))
            var logicalToVisual = [Int](repeating: 0, count: cols)
            var visualToLogical = [Int](repeating: 0, count: cols)
            var visualColumn = 0

            func append(logicalColumn: Int, width: Int, displayCharacter: Character?) {
                visualCells.append(BidiCell(logicalCol: logicalColumn, width: width,
                                            display: displayCharacter))
                for offset in 0..<width {
                    let logical = logicalColumn + offset
                    let visual = visualColumn + offset
                    if logical >= 0 && logical < cols {
                        logicalToVisual[logical] = visual
                    }
                    if visual >= 0 && visual < cols {
                        visualToLogical[visual] = logicalColumn
                    }
                }
                visualColumn += width
            }

            if baseDirection == .rightToLeft && used < cols {
                for logicalColumn in stride(from: cols - 1, through: used, by: -1) {
                    append(logicalColumn: logicalColumn, width: 1, displayCharacter: nil)
                }
            }
            for localIndex in resolved.order {
                let cellIndex = range.lowerBound + localIndex
                let cell = cells[cellIndex]
                append(logicalColumn: cell.logicalCol, width: cell.width,
                       displayCharacter: display[cellIndex])
            }
            if baseDirection == .leftToRight && used < cols {
                for logicalColumn in used..<cols {
                    append(logicalColumn: logicalColumn, width: 1, displayCharacter: nil)
                }
            }
            layouts[row] = BidiRowLayout(visualCells: visualCells,
                                         logicalToVisualCol: logicalToVisual,
                                         visualToLogicalCol: visualToLogical,
                                         baseDirection: baseDirection,
                                         paragraphRevision: revision)
        }
        return ParagraphResult(rows: layouts, baseDirection: baseDirection)
    }

    private static func paragraphResult(row: Int, buffer: Buffer, cols: Int,
                                        terminal: Terminal, font: AnyObject) -> ParagraphResult? {
        guard row >= 0, row < buffer.lines.count,
              buffer.lines[row].bidiState.supportMode == .implicit else {
            return nil
        }
        let maximumRows = max(1, terminal.options.maximumBidiParagraphRows)
        guard let bounds = paragraphBounds(row: row, buffer: buffer,
                                           maximumRows: maximumRows) else {
            return nil
        }
        let state = buffer.lines[bounds.lowerBound].bidiState
        let revision = paragraphRevision(bounds, buffer: buffer)
        let key = ParagraphKey(buffer: ObjectIdentifier(buffer),
                               firstRow: bounds.lowerBound,
                               lastRow: bounds.upperBound,
                               revision: revision,
                               cols: cols,
                               font: ObjectIdentifier(font),
                               state: state)
        cacheLock.lock()
        if let cached = paragraphCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Pure-LTR paragraphs never reach the typesetter; answer before
        // paying for cell extraction and content hashing.
        let hasPotentialRTL = bounds.contains {
            mayNeedBidi(line: buffer.lines[$0], cols: cols, terminal: terminal)
        }
        if !hasPotentialRTL && state.fallbackDirection == .leftToRight {
            let result = ParagraphResult(rows: [:], baseDirection: .leftToRight)
            storeIdentity(key, result)
            return result
        }

        var cells: [Cell] = []
        cells.reserveCapacity(bounds.count * min(cols, 80))
        var ranges: [Int: Range<Int>] = [:]
        var usedColumns: [Int: Int] = [:]
        for row in bounds {
            let start = cells.count
            usedColumns[row] = appendCells(line: buffer.lines[row], row: row,
                                           cols: cols, terminal: terminal, to: &cells)
            ranges[row] = start..<cells.count
        }

        let contentKey = contentKey(cells: cells, firstRow: bounds.lowerBound,
                                    rowCount: bounds.count, cols: cols,
                                    font: font, state: state)
        cacheLock.lock()
        if let entry = contentCache[contentKey],
           entry.matches(cells: cells, firstRow: bounds.lowerBound) {
            _contentCacheHits += 1
            cacheLock.unlock()
            let result = rebase(entry, bounds: bounds, revision: revision)
            storeIdentity(key, result)
            return result
        }
        _contentCacheMisses += 1
        cacheLock.unlock()

        let result = buildParagraph(bounds: bounds, cells: cells, ranges: ranges,
                                    usedColumns: usedColumns, cols: cols, font: font,
                                    state: state, hasPotentialRTL: hasPotentialRTL,
                                    revision: revision)

        let firstRow = bounds.lowerBound
        var rowsByOffset = [BidiRowLayout?](repeating: nil, count: bounds.count)
        for (absoluteRow, layout) in result.rows {
            rowsByOffset[absoluteRow - firstRow] = layout
        }
        let normalizedCells = cells.map {
            Cell(row: $0.row - firstRow, logicalCol: $0.logicalCol,
                 width: $0.width, text: $0.text)
        }
        cacheLock.lock()
        if contentCache.count >= 256 {
            contentCache.removeAll(keepingCapacity: true)
        }
        contentCache[contentKey] = CachedParagraph(cells: normalizedCells,
                                                   rowsByOffset: rowsByOffset,
                                                   baseDirection: result.baseDirection)
        cacheLock.unlock()
        storeIdentity(key, result)
        return result
    }

    private static func storeIdentity(_ key: ParagraphKey, _ result: ParagraphResult) {
        cacheLock.lock()
        if paragraphCache.count >= 256 {
            paragraphCache.removeAll(keepingCapacity: true)
        }
        paragraphCache[key] = result
        cacheLock.unlock()
    }

    /// Explicit RTL is a cell-path operation, not UAX #9. The application has
    /// already prepared display-order cells. Put column zero at the right edge
    /// and reverse every cell in the row without shaping the text.
    private static func explicitRightToLeftLayout(row: Int, buffer: Buffer,
                                                   cols: Int, terminal: Terminal)
        -> BidiRowLayout? {
        guard row >= 0, row < buffer.lines.count else {
            return nil
        }
        let line = buffer.lines[row]
        let state = line.bidiState
        var cells: [Cell] = []
        cells.reserveCapacity(min(cols, line.count))
        let used = min(cols, appendCells(line: line, row: row, cols: cols,
                                         terminal: terminal, to: &cells))
        var visualCells: [BidiCell] = []
        visualCells.reserveCapacity(cols)
        var logicalToVisual = [Int](repeating: 0, count: cols)
        var visualToLogical = [Int](repeating: 0, count: cols)
        var visualColumn = 0

        func append(logicalColumn: Int, width: Int, display: Character?) {
            visualCells.append(BidiCell(logicalCol: logicalColumn, width: width,
                                        display: display))
            for offset in 0..<width {
                let logical = logicalColumn + offset
                let visual = visualColumn + offset
                if logical >= 0, logical < cols {
                    logicalToVisual[logical] = visual
                }
                if visual >= 0, visual < cols {
                    visualToLogical[visual] = logicalColumn
                }
            }
            visualColumn += width
        }

        if used < cols {
            for logicalColumn in stride(from: cols - 1, through: used, by: -1) {
                append(logicalColumn: logicalColumn, width: 1, display: nil)
            }
        }
        for cell in cells.reversed() {
            let display: Character?
            if cell.text.unicodeScalars.count == 1,
               let source = cell.text.unicodeScalars.first?.value,
               let mirroredValue = unicode17Mirror[source],
               let mirrored = UnicodeScalar(mirroredValue) {
                display = Character(mirrored)
            } else if state.boxMirroring, let mirrored = boxMirror[cell.text] {
                display = mirrored
            } else {
                display = nil
            }
            append(logicalColumn: cell.logicalCol, width: cell.width, display: display)
        }

        return BidiRowLayout(visualCells: visualCells,
                             logicalToVisualCol: logicalToVisual,
                             visualToLogicalCol: visualToLogical,
                             baseDirection: .rightToLeft,
                             paragraphRevision: Int(truncatingIfNeeded: line.generation))
    }

    /// Returns a cell map for one row. The map was resolved with the complete
    /// soft-wrapped paragraph.
    static func layout(row: Int, buffer: Buffer, cols: Int, terminal: Terminal,
                       font: AnyObject, hostPolicy: BidiHostPolicy) -> BidiRowLayout? {
        guard hostPolicy == .respectTerminal else {
            return nil
        }
        guard row >= 0, row < buffer.lines.count else {
            return nil
        }
        let state = buffer.lines[row].bidiState
        if state.supportMode == .explicit {
            guard state.fallbackDirection == .rightToLeft else {
                return nil
            }
            return explicitRightToLeftLayout(row: row, buffer: buffer, cols: cols,
                                              terminal: terminal)
        }
        return paragraphResult(row: row, buffer: buffer, cols: cols,
                               terminal: terminal, font: font)?.rows[row]
    }

    static func resolvedBaseDirection(row: Int, buffer: Buffer, cols: Int,
                                      terminal: Terminal, font: AnyObject,
                                      hostPolicy: BidiHostPolicy) -> BidiDirection {
        guard hostPolicy == .respectTerminal, row >= 0, row < buffer.lines.count else {
            return .leftToRight
        }
        let state = buffer.lines[row].bidiState
        if state.supportMode == .explicit {
            return state.fallbackDirection
        }
        let fallback = state.fallbackDirection
        return paragraphResult(row: row, buffer: buffer, cols: cols,
                               terminal: terminal, font: font)?.baseDirection
            ?? fallback
    }

    /// Expands a changed row range to include every row whose paragraph-wide
    /// shaping can change. Oversized and explicit paragraphs use row-local
    /// rendering, so they do not expand the range.
    static func renderingDependencyRange(rows: ClosedRange<Int>, buffer: Buffer,
                                         maximumRows: Int) -> ClosedRange<Int> {
        guard !buffer.lines.isEmpty else {
            return rows
        }
        let firstRow = max(0, min(rows.lowerBound, buffer.lines.count - 1))
        let lastRow = max(firstRow, min(rows.upperBound, buffer.lines.count - 1))
        var first = firstRow
        var last = lastRow

        var firstBounds: ClosedRange<Int>?
        if buffer.lines[firstRow].bidiState.supportMode == .implicit {
            firstBounds = paragraphBounds(row: firstRow, buffer: buffer,
                                          maximumRows: maximumRows)
            if let firstBounds {
                first = firstBounds.lowerBound
                if firstBounds.contains(lastRow) {
                    last = firstBounds.upperBound
                }
            }
        }
        if firstBounds?.contains(lastRow) != true,
           buffer.lines[lastRow].bidiState.supportMode == .implicit,
           let lastBounds = paragraphBounds(row: lastRow, buffer: buffer,
                                            maximumRows: maximumRows) {
            last = lastBounds.upperBound
        }
        return first...last
    }

    static func layoutRevision(row: Int, buffer: Buffer,
                               maximumRows: Int) -> Int {
        guard row >= 0, row < buffer.lines.count,
              buffer.lines[row].bidiState.supportMode == .implicit,
              let bounds = paragraphBounds(row: row, buffer: buffer,
                                           maximumRows: maximumRows) else {
            return 0
        }
        return paragraphRevision(bounds, buffer: buffer)
    }
}
#endif
