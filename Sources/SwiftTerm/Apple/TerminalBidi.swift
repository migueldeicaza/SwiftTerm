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

/// Controls how the terminal determines the paragraph direction of each row
/// when rendering bidirectional text (Arabic, Hebrew).
public enum BidiParagraphDirection {
    /// BiDi processing disabled: cells are rendered strictly left-to-right
    /// in logical order (legacy terminal behavior).
    case off
    /// The direction of each row is detected from its first strong
    /// directional character (UAX #9 rules P2/P3). Rows with no strong
    /// character are treated as left-to-right.
    case auto
    /// Every row is treated as a left-to-right paragraph.
    case leftToRight
    /// Every row is treated as a right-to-left paragraph: RTL text hugs the
    /// right edge and neutrals flow right-to-left.
    case rightToLeft
}

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
             0x200F, 0x202B, 0x202E,    // RLM, RLE, RLO
             0x2067:                    // RLI
            return true
        default:
            return false
        }
    }

    // MARK: - Arabic joining classification (subset of ArabicShaping.txt)

    enum Joining {
        case none         // U: non-joining
        case transparent  // T: combining marks, skipped when finding neighbors
        case causing      // C: tatweel, ZWJ
        case right        // R: joins only with the preceding letter
        case dual         // D: joins on both sides
    }

    static func joining(of v: UInt32) -> Joining {
        switch v {
        case 0x0640, 0x200D:
            return .causing
        case 0x0610...0x061A, 0x064B...0x065F, 0x0670,
             0x06D6...0x06DC, 0x06DF...0x06E4, 0x06E7, 0x06E8,
             0x06EA...0x06ED, 0x08D3...0x08FF:
            return .transparent
        case 0x0622, 0x0623, 0x0624, 0x0625, 0x0627, 0x0629,
             0x062F, 0x0630, 0x0631, 0x0632, 0x0648, 0x0649,
             0x0671,                                  // alef wasla
             0x0688, 0x0691, 0x0698, 0x06BA, 0x06D2, 0x06D5: // ڈ ڑ ژ ں ے ە
            return .right
        case 0x0626, 0x0628, 0x062A...0x062E, 0x0633...0x063A,
             0x0641...0x0647, 0x064A,
             0x0679, 0x067E, 0x0686, 0x06A9, 0x06AF, 0x06BE, 0x06CC: // ٹ پ چ ک گ ھ ی
            return .dual
        default:
            return .none
        }
    }

    /// Contextual presentation forms: base scalar -> (isolated, final, initial, medial).
    /// Initial/medial are nil for right-joining letters.
    /// Standard Arabic uses Presentation Forms-B (U+FE70...U+FEFC); the common
    /// Persian/Urdu letters use Presentation Forms-A.
    static let forms: [UInt32: (iso: UInt32, fin: UInt32, ini: UInt32?, med: UInt32?)] = [
        0x0621: (0xFE80, 0xFE80, nil, nil),          // ء
        0x0622: (0xFE81, 0xFE82, nil, nil),          // آ
        0x0623: (0xFE83, 0xFE84, nil, nil),          // أ
        0x0624: (0xFE85, 0xFE86, nil, nil),          // ؤ
        0x0625: (0xFE87, 0xFE88, nil, nil),          // إ
        0x0626: (0xFE89, 0xFE8A, 0xFE8B, 0xFE8C),    // ئ
        0x0627: (0xFE8D, 0xFE8E, nil, nil),          // ا
        0x0628: (0xFE8F, 0xFE90, 0xFE91, 0xFE92),    // ب
        0x0629: (0xFE93, 0xFE94, nil, nil),          // ة
        0x062A: (0xFE95, 0xFE96, 0xFE97, 0xFE98),    // ت
        0x062B: (0xFE99, 0xFE9A, 0xFE9B, 0xFE9C),    // ث
        0x062C: (0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0),    // ج
        0x062D: (0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4),    // ح
        0x062E: (0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8),    // خ
        0x062F: (0xFEA9, 0xFEAA, nil, nil),          // د
        0x0630: (0xFEAB, 0xFEAC, nil, nil),          // ذ
        0x0631: (0xFEAD, 0xFEAE, nil, nil),          // ر
        0x0632: (0xFEAF, 0xFEB0, nil, nil),          // ز
        0x0633: (0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4),    // س
        0x0634: (0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8),    // ش
        0x0635: (0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC),    // ص
        0x0636: (0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0),    // ض
        0x0637: (0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4),    // ط
        0x0638: (0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8),    // ظ
        0x0639: (0xFEC9, 0xFECA, 0xFECB, 0xFECC),    // ع
        0x063A: (0xFECD, 0xFECE, 0xFECF, 0xFED0),    // غ
        0x0641: (0xFED1, 0xFED2, 0xFED3, 0xFED4),    // ف
        0x0642: (0xFED5, 0xFED6, 0xFED7, 0xFED8),    // ق
        0x0643: (0xFED9, 0xFEDA, 0xFEDB, 0xFEDC),    // ك
        0x0644: (0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0),    // ل
        0x0645: (0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4),    // م
        0x0646: (0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8),    // ن
        0x0647: (0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC),    // ه
        0x0648: (0xFEED, 0xFEEE, nil, nil),          // و
        0x0649: (0xFEEF, 0xFEF0, nil, nil),          // ى
        0x064A: (0xFEF1, 0xFEF2, 0xFEF3, 0xFEF4),    // ي
        // Persian / Urdu (Presentation Forms-A)
        0x0679: (0xFB66, 0xFB67, 0xFB68, 0xFB69),    // ٹ
        0x067E: (0xFB56, 0xFB57, 0xFB58, 0xFB59),    // پ
        0x0686: (0xFB7A, 0xFB7B, 0xFB7C, 0xFB7D),    // چ
        0x0688: (0xFB88, 0xFB89, nil, nil),          // ڈ
        0x0691: (0xFB8C, 0xFB8D, nil, nil),          // ڑ
        0x0698: (0xFB8A, 0xFB8B, nil, nil),          // ژ
        0x06A9: (0xFB8E, 0xFB8F, 0xFB90, 0xFB91),    // ک
        0x06AF: (0xFB92, 0xFB93, 0xFB94, 0xFB95),    // گ
        0x06BA: (0xFB9E, 0xFB9F, nil, nil),          // ں
        0x06BE: (0xFBAA, 0xFBAB, 0xFBAC, 0xFBAD),    // ھ
        0x06CC: (0xFBFC, 0xFBFD, 0xFBFE, 0xFBFF),    // ی
        0x06D2: (0xFBAE, 0xFBAF, nil, nil),          // ے
    ]

    /// Lam-alef ligatures: alef variant -> (isolated, final) ligature form.
    static let lamAlef: [UInt32: (iso: UInt32, fin: UInt32)] = [
        0x0622: (0xFEF5, 0xFEF6),   // لآ
        0x0623: (0xFEF7, 0xFEF8),   // لأ
        0x0625: (0xFEF9, 0xFEFA),   // لإ
        0x0627: (0xFEFB, 0xFEFC),   // لا
    ]

    /// Common mirrored pairs (UAX #9 rule L4) applied to cells resolved RTL.
    static let mirror: [Character: Character] = [
        "(": ")", ")": "(", "[": "]", "]": "[", "{": "}", "}": "{",
        "<": ">", ">": "<", "«": "»", "»": "«", "‹": "›", "›": "‹",
        "⟨": "⟩", "⟩": "⟨", "≤": "≥", "≥": "≤",
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
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,
             0xFB50...0xFDFF, 0xFE70...0xFEFC:
            return true
        default:
            return false
        }
    }

    // MARK: - Cell extraction

    struct Cell {
        let logicalCol: Int
        let width: Int
        let text: Character
    }

    /// Extracts the renderable cells of a row (skipping wide-character
    /// continuation columns), noting whether any cell contains a character
    /// that triggers BiDi processing.
    static func extractCells(line: BufferLine, cols: Int, terminal: Terminal) -> (cells: [Cell], hasRTL: Bool) {
        var cells: [Cell] = []
        cells.reserveCapacity(cols)
        var hasRTL = false
        var col = 0
        let count = min(cols, line.count)
        while col < count {
            let ch = line[col]
            let width = max(1, Int(ch.width))
            let character: Character = ch.code == 0 ? " " : terminal.getCharacter(for: ch)
            if !hasRTL {
                for scalar in character.unicodeScalars where isRTLTrigger(scalar.value) {
                    hasRTL = true
                    break
                }
            }
            cells.append(Cell(logicalCol: col, width: width, text: character))
            col += width
        }
        return (cells, hasRTL)
    }

    // MARK: - Visual ordering via CoreText (UAX #9)

    /// True for scalars that can shape or ligate under Arabic script rules and
    /// must therefore be substituted in the probe line.
    @inline(__always)
    static func isJoiningCapable(_ v: UInt32) -> Bool {
        switch v {
        case 0x0620...0x064A, 0x066E...0x066F, 0x0671...0x06D5,
             0x06EE, 0x06EF, 0x06FA...0x06FF, 0x0750...0x077F,
             0x08A0...0x08D2, 0x200D:
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
        if v > 0xFFFF {
            return 0x00B7  // astral (emoji etc.): neutral placeholder (ON)
        }
        return unichar(v)
    }

    /// Computes the visual order of cells and which cells resolved to an RTL
    /// embedding level, using CoreText's UAX #9 implementation.
    static func computeVisualOrder(cells: [Cell], direction: BidiParagraphDirection, font: AnyObject)
        -> (order: [Int], rtl: [Bool])?
    {
        let n = cells.count
        if n == 0 { return nil }

        var units = [unichar](repeating: 0, count: n)
        for (i, cell) in cells.enumerated() {
            units[i] = probeScalar(for: cell.text)
        }
        let probe = NSString(characters: &units, length: n)

        var writingDirection: CTWritingDirection
        switch direction {
        case .rightToLeft: writingDirection = .rightToLeft
        case .leftToRight: writingDirection = .leftToRight
        default: writingDirection = .natural
        }
        let style: CTParagraphStyle = withUnsafeMutableBytes(of: &writingDirection) { ptr in
            var setting = CTParagraphStyleSetting(
                spec: .baseWritingDirection,
                valueSize: MemoryLayout<CTWritingDirection>.size,
                value: ptr.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let ligature = 0 as CFNumber
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            NSAttributedString.Key(kCTLigatureAttributeName as String): ligature,
        ]
        let attributed = NSAttributedString(string: probe as String, attributes: attributes)
        let ctLine = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun], !runs.isEmpty else {
            return nil
        }

        var entries: [(x: CGFloat, idx: Int)] = []
        entries.reserveCapacity(n)
        var rtl = [Bool](repeating: false, count: n)
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            if glyphCount == 0 { continue }
            let isRTLRun = CTRunGetStatus(run).contains(.rightToLeft)
            var indices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetStringIndices(run, CFRange(), &indices)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetPositions(run, CFRange(), &positions)
            for i in 0..<glyphCount {
                let idx = indices[i]
                guard idx >= 0 && idx < n else { continue }
                entries.append((positions[i].x, idx))
                if isRTLRun {
                    rtl[idx] = true
                }
            }
        }
        entries.sort { $0.x < $1.x }

        var order: [Int] = []
        order.reserveCapacity(n)
        var seen = Set<Int>()
        for entry in entries where seen.insert(entry.idx).inserted {
            order.append(entry.idx)
        }
        // Repair pass: any cell whose probe produced no glyph (e.g. a control
        // or formatting character) is reinserted next to its logical neighbor.
        if order.count < n {
            for k in 0..<n where !seen.contains(k) {
                if let p = order.firstIndex(of: k - 1) {
                    order.insert(k, at: rtl[k - 1] ? p : p + 1)
                } else if let p = order.firstIndex(of: k + 1) {
                    order.insert(k, at: rtl[k + 1] ? p + 1 : p)
                } else {
                    order.append(k)
                }
                seen.insert(k)
            }
        }
        guard order.count == n else { return nil }
        return (order, rtl)
    }

    // MARK: - Arabic contextual shaping (cell level)

    /// Computes per-cell display substitutions for Arabic contextual forms and
    /// lam-alef ligatures. Operates on cells in logical order so that color or
    /// attribute changes never break joining. Combining marks stored beyond
    /// the base scalar of a cell (harakat) are preserved after the
    /// substituted presentation form; the renderer's per-cluster column
    /// mapping keeps them overlaid on their base cell.
    ///
    /// `precedingScalar`/`followingScalar` supply joining context from the
    /// adjacent rows of a soft-wrapped logical line, so words split by
    /// wrapping keep their connected forms at the seam.
    static func shapeArabic(cells: [Cell],
                            precedingScalar: UInt32? = nil,
                            followingScalar: UInt32? = nil) -> [Character?] {
        let n = cells.count
        var result = [Character?](repeating: nil, count: n)

        func baseScalar(_ i: Int) -> UInt32 {
            cells[i].text.unicodeScalars.first?.value ?? 0x20
        }
        // The joining neighbor on a given side, skipping transparent cells;
        // past the row edge, the wrapped-neighbor context applies.
        func neighbor(from i: Int, step: Int) -> Joining {
            var j = i + step
            while j >= 0 && j < n {
                let kind = joining(of: baseScalar(j))
                if kind != .transparent { return kind }
                j += step
            }
            if step < 0, let precedingScalar {
                return joining(of: precedingScalar)
            }
            if step > 0, let followingScalar {
                return joining(of: followingScalar)
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
                if kind == .none, let form = forms[v] {
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
                return p == .dual || p == .causing
            }()

            // Retains any combining marks (harakat) stored after the base
            // scalar of a cell.
            func withMarks(_ shaped: UInt32, from cell: Cell) -> Character {
                var text = String(UnicodeScalar(shaped)!)
                for scalar in cell.text.unicodeScalars.dropFirst() {
                    text.unicodeScalars.append(scalar)
                }
                return Character(text)
            }

            // Lam followed by an alef variant in the adjacent cell forms the
            // mandatory lam-alef ligature: the ligature glyph goes in the lam
            // cell and the alef cell is blanked.
            if v == 0x0644, i + 1 < n, let lig = lamAlef[baseScalar(i + 1)] {
                let form = prevConnects ? lig.fin : lig.iso
                result[i] = withMarks(form, from: cells[i])
                result[i + 1] = " "
                i += 2
                continue
            }

            guard let form = forms[v] else {
                i += 1
                continue
            }
            let nextKind = neighbor(from: i, step: 1)
            let nextConnects = nextKind == .dual || nextKind == .right || nextKind == .causing
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
            result[i] = withMarks(shaped, from: cells[i])
            i += 1
        }
        return result
    }

    // MARK: - Full row layout

    /// The joining-relevant scalar at the logical end of a row (for use as
    /// preceding context of the wrapped row after it).
    static func trailingScalar(of line: BufferLine, cols: Int, terminal: Terminal) -> UInt32? {
        var col = min(cols, line.count) - 1
        while col >= 0 {
            let ch = line[col]
            if ch.code != 0 {
                return terminal.getCharacter(for: ch).unicodeScalars.first?.value
            }
            col -= 1
        }
        return nil
    }

    /// The joining-relevant scalar at the logical start of a row (for use as
    /// following context of the row it wraps from).
    static func leadingScalar(of line: BufferLine, cols: Int, terminal: Terminal) -> UInt32? {
        var col = 0
        let count = min(cols, line.count)
        while col < count {
            let ch = line[col]
            if ch.code != 0 {
                return terminal.getCharacter(for: ch).unicodeScalars.first?.value
            }
            col += max(1, Int(ch.width))
        }
        return nil
    }

    /// Computes the visual layout of a row, or nil when the row needs no BiDi
    /// processing (pure LTR content or BiDi disabled) and the caller should use
    /// the plain logical rendering path.
    ///
    /// For rows that are part of a soft-wrapped logical line, pass the edge
    /// scalars of the adjacent rows so Arabic joining survives the wrap seam.
    static func layout(line: BufferLine, cols: Int, terminal: Terminal,
                       direction: BidiParagraphDirection, font: AnyObject,
                       precedingScalar: UInt32? = nil,
                       followingScalar: UInt32? = nil) -> BidiRowLayout?
    {
        if direction == .off { return nil }
        let (cells, hasRTL) = extractCells(line: line, cols: cols, terminal: terminal)
        // Fast path: rows with no RTL content lay out identically under auto
        // or forced-LTR paragraphs. A forced-RTL paragraph reorders even
        // pure-LTR rows (right alignment via UAX #9 L1), so it always runs.
        if !hasRTL && direction != .rightToLeft {
            return nil
        }
        if cells.isEmpty {
            return nil
        }
        guard let (order, rtl) = computeVisualOrder(cells: cells, direction: direction, font: font) else {
            return nil
        }

        var display = shapeArabic(cells: cells,
                                  precedingScalar: precedingScalar,
                                  followingScalar: followingScalar)
        for (i, cell) in cells.enumerated() where rtl[i] && display[i] == nil {
            if let mirrored = mirror[cell.text] {
                display[i] = mirrored
            } else if terminal.bidiBoxMirroring, let mirrored = boxMirror[cell.text] {
                display[i] = mirrored
            }
        }

        var visualCells: [BidiCell] = []
        visualCells.reserveCapacity(cells.count)
        var logicalToVisual = [Int](repeating: 0, count: cols)
        var visualToLogical = [Int](repeating: 0, count: cols)
        var visualCol = 0
        for cellIndex in order {
            let cell = cells[cellIndex]
            visualCells.append(BidiCell(logicalCol: cell.logicalCol,
                                        width: cell.width,
                                        display: display[cellIndex]))
            for k in 0..<cell.width {
                let logical = cell.logicalCol + k
                let visual = visualCol + k
                if logical < cols { logicalToVisual[logical] = visual }
                if visual < cols { visualToLogical[visual] = cell.logicalCol }
            }
            visualCol += cell.width
        }
        return BidiRowLayout(visualCells: visualCells,
                             logicalToVisualCol: logicalToVisual,
                             visualToLogicalCol: visualToLogical)
    }
}
#endif
