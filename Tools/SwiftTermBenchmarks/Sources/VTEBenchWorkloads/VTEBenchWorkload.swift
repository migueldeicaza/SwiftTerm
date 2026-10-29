import Foundation

/// A deterministic byte stream adapted from one vtebench case.
public struct VTEBenchWorkload: Sendable {
    public let name: String
    public let setup: [UInt8]
    public let payload: [UInt8]
    /// The OSC size limit for this case. `nil` uses the terminal default.
    public let maximumOscBytes: Int?
    /// Split a repeated sample into input chunks of this size.
    ///
    /// A chunk size tests parser state that continues across feed calls.
    public let inputChunkSize: Int?
    /// The URI of the last OSC 8 link that the payload prints.
    ///
    /// A benchmark checks outside the timed region that this link still
    /// resolves after the run. `nil` means the payload prints no link text.
    public let lastHyperlink: String?

    public init(
        name: String,
        setup: [UInt8] = [],
        payload: [UInt8],
        maximumOscBytes: Int? = nil,
        inputChunkSize: Int? = nil,
        lastHyperlink: String? = nil
    ) {
        precondition(!payload.isEmpty, "A benchmark payload must not be empty")
        precondition(maximumOscBytes == nil || maximumOscBytes! >= 0,
                     "The OSC size limit must not be negative")
        precondition(inputChunkSize == nil || inputChunkSize! > 0,
                     "The input chunk size must be positive")
        self.name = name
        self.setup = setup
        self.payload = payload
        self.maximumOscBytes = maximumOscBytes
        self.inputChunkSize = inputChunkSize
        self.lastHyperlink = lastHyperlink
    }

    /// Repeats the complete payload until the sample is at least the requested size.
    /// This is the same expansion rule that vtebench uses.
    public func sample(minimumByteCount: Int = 1_048_576) -> [UInt8] {
        precondition(minimumByteCount > 0, "The minimum sample size must be positive")

        let repetitionCount = (minimumByteCount - 1) / payload.count + 1
        var result: [UInt8] = []
        result.reserveCapacity(payload.count * repetitionCount)
        for _ in 0..<repetitionCount {
            result.append(contentsOf: payload)
        }
        return result
    }

    /// Splits a complete sample into deterministic parser input chunks.
    public func sampleChunks(minimumByteCount: Int = 1_048_576) -> [[UInt8]] {
        let sample = sample(minimumByteCount: minimumByteCount)
        guard let inputChunkSize else { return [sample] }

        return stride(from: 0, to: sample.count, by: inputChunkSize).map { start in
            Array(sample[start..<min(start + inputChunkSize, sample.count)])
        }
    }
}

public enum VTEBenchWorkloads {
    public static let defaultColumns = 80
    public static let defaultRows = 25

    /// Creates the 12 cases in vtebench's default `benchmarks` directory.
    public static func makeDefault(
        columns: Int = defaultColumns,
        rows: Int = defaultRows
    ) throws -> [VTEBenchWorkload] {
        precondition(columns > 0 && rows > 0, "Terminal dimensions must be positive")

        let alternateScreen = bytes("\u{1b}[?1049h")
        let scrollLine = bytes("y\n")
        let fillScreen = repeatedBytes(scrollLine, count: 100_001)

        return [
            VTEBenchWorkload(
                name: "cursor_motion",
                payload: cursorMotion(columns: columns, rows: rows)),
            VTEBenchWorkload(
                name: "dense_cells",
                setup: alternateScreen,
                payload: denseCells(columns: columns, rows: rows)),
            VTEBenchWorkload(
                name: "light_cells",
                setup: alternateScreen,
                payload: lightCells(columns: columns, rows: rows)),
            VTEBenchWorkload(
                name: "medium_cells",
                payload: try resource(named: "medium_cells_vim_session")),
            VTEBenchWorkload(
                name: "scrolling",
                setup: fillScreen,
                payload: scrollLine),
            VTEBenchWorkload(
                name: "scrolling_bottom_region",
                setup: alternateScreen + bytes("\u{1b}[1;\(rows - 1)r"),
                payload: scrollLine),
            VTEBenchWorkload(
                name: "scrolling_bottom_small_region",
                setup: alternateScreen + bytes("\u{1b}[1;\(rows / 2)r"),
                payload: scrollLine),
            VTEBenchWorkload(
                name: "scrolling_fullscreen",
                setup: fillScreen,
                payload: scrollingFullscreen(columns: columns)),
            VTEBenchWorkload(
                name: "scrolling_top_region",
                setup: alternateScreen + bytes("\u{1b}[2;\(rows)r"),
                payload: scrollLine),
            VTEBenchWorkload(
                name: "scrolling_top_small_region",
                setup: alternateScreen + bytes("\u{1b}[\(rows / 2);\(rows)r"),
                payload: scrollLine),
            VTEBenchWorkload(
                name: "sync_medium_cells",
                payload: try resource(named: "sync_medium_cells_vim_session")),
            VTEBenchWorkload(
                name: "unicode",
                setup: alternateScreen,
                payload: unicodeSymbols())
        ]
    }

    /// Creates focused parser workloads for hardening changes.
    ///
    /// These cases are separate from `makeDefault()` so the 12 vtebench cases
    /// and their callers keep the same names and selection behavior.
    public static func makeHardening(
        columns: Int = defaultColumns,
        rows: Int = defaultRows
    ) -> [VTEBenchWorkload] {
        precondition(columns >= 8 && rows >= 4,
                     "Hardening workloads need at least 8 columns and 4 rows")

        let alternateScreen = bytes("\u{1b}[?1049h\u{1b}[2J\u{1b}[H")
        let oscLimit = 4_096
        let normalOscBody = String(repeating: "n", count: oscLimit - 2)
        let oversizedOscBody = String(repeating: "o", count: oscLimit - 1)

        return [
            VTEBenchWorkload(
                name: "hardening_ascii_seam_noop",
                setup: alternateScreen,
                payload: bytes("\u{1b}[1;\(columns - 1)HAB\u{1b}[1;\(columns - 1)HAB")),
            VTEBenchWorkload(
                name: "hardening_wide_seam_overwrite_edit",
                setup: alternateScreen,
                payload: bytes("\u{1b}[1;\(columns - 1)H界\u{1b}[1;\(columns)HX\u{1b}[1;\(columns - 1)H界\u{1b}[1;\(columns)H\u{1b}[P")),
            VTEBenchWorkload(
                name: "hardening_horizontal_margin_wide_scroll_edit",
                setup: alternateScreen + bytes("\u{1b}[?69h\u{1b}[3;\(columns - 2)s\u{1b}[2;\(rows - 1)r\u{1b}[?6h"),
                payload: bytes("\u{1b}[1;1H界界界\u{1b}[1S\u{1b}[1L\u{1b}[1M\u{1b}[1;2H\u{1b}[2@\u{1b}[1P")),
            VTEBenchWorkload(
                name: "hardening_osc_bounded_normal",
                payload: bytes("\u{1b}]2;\(normalOscBody)\u{07}"),
                maximumOscBytes: oscLimit),
            VTEBenchWorkload(
                name: "hardening_osc_bounded_over_limit",
                payload: bytes("\u{1b}]2;\(oversizedOscBody)\u{07}"),
                maximumOscBytes: oscLimit),
            VTEBenchWorkload(
                name: "hardening_osc_bounded_chunked",
                payload: bytes("\u{1b}]2;\(normalOscBody)\u{07}"),
                maximumOscBytes: oscLimit,
                inputChunkSize: 127),
            VTEBenchWorkload(
                name: "hardening_osc_short_normal",
                payload: bytes("\u{1b}]2;title\u{07}")),
            VTEBenchWorkload(
                name: "hardening_osc_short_chunked",
                payload: bytes("\u{1b}]2;title\u{07}"),
                inputChunkSize: 1),
            VTEBenchWorkload(
                name: "hardening_block_color_cells",
                setup: alternateScreen,
                payload: blockColorCells(columns: columns, rows: rows))
        ]
    }

    /// Creates OSC 8 hyperlink workloads.
    ///
    /// The `osc8_parse_*`, `osc8_stream*`, and `osc8_cell_churn` cases follow
    /// the OSC parser, terminal stream, and churn cases in Ghostty's benchmark
    /// guide. The other cases model link reuse and link release. All payloads
    /// close the active link at the end.
    public static func makeHyperlink(
        columns: Int = defaultColumns,
        rows: Int = defaultRows
    ) -> [VTEBenchWorkload] {
        precondition(columns > 0 && rows > 0, "Terminal dimensions must be positive")

        let benchmarkURI = "https://example.com/benchmark"
        let longURI = "https://example.com/" + String(repeating: "a", count: 1_000)
        // Scrollback holds 500 lines by default. 60,000 links with one cell
        // each is more than the cells that the screen and scrollback can keep,
        // so a repeated sample never finds its links still in use.
        let denseLinkCount = 60_000
        let distinctLineCount = 10_000

        return [
            VTEBenchWorkload(
                name: "osc8_parse_implicit",
                payload: oscPair(start: "8;;\(benchmarkURI)")),
            VTEBenchWorkload(
                name: "osc8_parse_explicit",
                payload: oscPair(start: "8;id=bench;\(benchmarkURI)")),
            VTEBenchWorkload(
                name: "osc8_parse_long_uri",
                payload: oscPair(start: "8;;\(longURI)")),
            VTEBenchWorkload(
                name: "osc8_stream",
                payload: bytes(hyperlink(benchmarkURI, "linked text") + "\r\n"),
                lastHyperlink: benchmarkURI),
            VTEBenchWorkload(
                name: "osc8_stream_plain",
                payload: bytes("linked text\r\n")),
            VTEBenchWorkload(
                name: "osc8_cell_churn",
                payload: bytes("\u{1b}[H\u{1b}]8;;\(benchmarkURI)\u{1b}\\"
                    + String(repeating: "x", count: columns * rows)
                    + "\u{1b}]8;;\u{1b}\\"),
                lastHyperlink: benchmarkURI),
            VTEBenchWorkload(
                name: "osc8_redraw_same",
                payload: redrawSameLinks(rows: rows),
                lastHyperlink: "https://example.com/file/\((rows - 1) % 10)"),
            VTEBenchWorkload(
                name: "osc8_distinct_lines",
                payload: distinctLinkLines(count: distinctLineCount),
                lastHyperlink: "https://example.com/commit/\(distinctLineCount - 1)"),
            VTEBenchWorkload(
                name: "osc8_dense",
                payload: denseLinks(count: denseLinkCount),
                lastHyperlink: "u\(denseLinkCount - 1)")
        ]
    }

    private static func hyperlink(_ uri: String, _ text: String) -> String {
        "\u{1b}]8;;\(uri)\u{1b}\\\(text)\u{1b}]8;;\u{1b}\\"
    }

    /// A link start and a link end with `BEL` terminators and no text.
    private static func oscPair(start: String) -> [UInt8] {
        bytes("\u{1b}]\(start)\u{07}\u{1b}]8;;\u{07}")
    }

    /// A full-screen redraw, as tmux sends it, with the same 10 links.
    private static func redrawSameLinks(rows: Int) -> [UInt8] {
        var result = "\u{1b}[H"
        for row in 0..<rows {
            result += "\u{1b}[\(row + 1);1H"
            result += hyperlink("https://example.com/file/\(row % 10)", "file-\(row % 10).swift")
            result += " text that fills the row\u{1b}[K"
        }
        return bytes(result)
    }

    /// One line for each new link. The lines scroll into scrollback.
    private static func distinctLinkLines(count: Int) -> [UInt8] {
        var result: [UInt8] = []
        for index in 0..<count {
            result.append(contentsOf: bytes(
                hyperlink("https://example.com/commit/\(index)", "commit \(index)")
                + " message text for this line\r\n"))
        }
        return result
    }

    /// One cell for each new link.
    private static func denseLinks(count: Int) -> [UInt8] {
        var result: [UInt8] = []
        for index in 0..<count {
            result.append(contentsOf: bytes(hyperlink("u\(index)", "x")))
        }
        return result
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)

    private static func cursorMotion(columns: Int, rows: Int) -> [UInt8] {
        var result: [UInt8] = []

        for character in alphabet {
            var columnStart = 1
            var columnEnd = columns
            var rowStart = 1
            var rowEnd = rows

            while true {
                var column = columnStart
                var row = rowStart

                while column < columnEnd {
                    appendCursorPosition(row: row, column: column, to: &result)
                    result.append(character)
                    column += 1
                }
                while row < rowEnd {
                    appendCursorPosition(row: row, column: column, to: &result)
                    result.append(character)
                    row += 1
                }
                while column > columnStart {
                    appendCursorPosition(row: row, column: column, to: &result)
                    result.append(character)
                    column -= 1
                }
                while row > rowStart {
                    appendCursorPosition(row: row, column: column, to: &result)
                    result.append(character)
                    row -= 1
                }

                columnStart += 1
                rowStart += 1
                columnEnd -= 1
                rowEnd -= 1
                if columnStart > columnEnd || rowStart > rowEnd {
                    break
                }
            }
        }
        return result
    }

    private static func denseCells(columns: Int, rows: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(columns * rows * alphabet.count * 25)

        for (offset, character) in alphabet.enumerated() {
            result.append(contentsOf: bytes("\u{1b}[H"))
            for row in 1...rows {
                for column in 1...columns {
                    let index = row + column + offset
                    let foreground = index % 156 + 100
                    let background = 255 - index % 156 + 100
                    result.append(contentsOf: bytes(
                        "\u{1b}[38;5;\(foreground);48;5;\(background);1;3;4m"))
                    result.append(character)
                }
            }
        }
        return result
    }

    /// A half-block image, as a terminal image viewer or a DOOM-fire demo
    /// draws one: every cell sets a 256-color foreground and background, then
    /// prints U+2580, so each print run is a single non-ASCII scalar.
    private static func blockColorCells(columns: Int, rows: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(columns * rows * 8 * 22)
        for frame in 0..<8 {
            result.append(contentsOf: bytes("\u{1b}[H"))
            for row in 1...rows {
                for column in 1...columns {
                    let index = row * 7 + column * 3 + frame * 11
                    let foreground = 16 + index % 216
                    let background = 16 + (index + 36) % 216
                    result.append(contentsOf: bytes("\u{1b}[38;5;\(foreground);48;5;\(background)m\u{2580}"))
                }
            }
        }
        return result
    }

    private static func lightCells(columns: Int, rows: Int) -> [UInt8] {
        var result: [UInt8] = []
        let cellCount = columns * rows
        result.reserveCapacity((cellCount + 3) * alphabet.count)

        for character in alphabet {
            result.append(contentsOf: bytes("\u{1b}[H"))
            result.append(contentsOf: repeatElement(character, count: cellCount))
        }
        return result
    }

    private static func scrollingFullscreen(columns: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity((columns + 1) * alphabet.count)
        for character in alphabet {
            result.append(contentsOf: repeatElement(character, count: columns))
            result.append(0x0a)
        }
        return result
    }

    private static func unicodeSymbols() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(138_296)

        // These are the exact contiguous ranges in vtebench's `symbols` file.
        // Keep the original corpus gaps so the generated bytes stay stable.
        let ranges = [
            0x00a1...0x0304, 0x0370...0x0487, 0x048a...0x0595,
            0x05be...0x0604, 0x0606...0x0614, 0x061b...0x064f,
            0x0660...0x06da, 0x06de...0x06e3, 0x06e5...0x0734,
            0x074b...0x07aa, 0x0910...0x0945, 0x0949...0x0955,
            0x0958...0x0a36, 0x10a1...0x1164, 0x1200...0x167d,
            0x1d00...0x1dc4, 0x1dfa...0x206a, 0x2070...0x20d4,
            0x20f1...0x28ff, 0x2e80...0x9fef, 0xac00...0xd7fb
        ]
        for range in ranges {
            for value in range {
                appendUnicodeScalar(value, to: &result)
            }
        }
        result.append(0x0a)
        for value in 0x1f600...0x1f64f {
            appendUnicodeScalar(value, to: &result)
        }
        result.append(0x0a)
        return result
    }

    private static func appendCursorPosition(row: Int, column: Int, to result: inout [UInt8]) {
        result.append(contentsOf: bytes("\u{1b}[\(row);\(column)H"))
    }

    private static func appendUnicodeScalar(_ value: Int, to result: inout [UInt8]) {
        let scalar = UnicodeScalar(value)!
        result.append(contentsOf: String(scalar).utf8)
    }

    private static func repeatedBytes(_ bytes: [UInt8], count: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count * count)
        for _ in 0..<count {
            result.append(contentsOf: bytes)
        }
        return result
    }

    private static func bytes(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    private static func resource(named name: String) throws -> [UInt8] {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Resources")
        else {
            throw ResourceError.missing(name)
        }
        return [UInt8](try Data(contentsOf: url))
    }

    private enum ResourceError: Error {
        case missing(String)
    }
}
