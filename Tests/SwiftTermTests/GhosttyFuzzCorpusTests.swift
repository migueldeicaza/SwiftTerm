import Foundation
import Testing

@testable import SwiftTerm

@Suite("Ghostty fuzz corpora", .serialized)
struct GhosttyFuzzCorpusTests {
    @Test func replayOscCorpora() throws {
        try replayArchives([
            "osc-initial",
            "osc-cmin",
        ], target: .osc)
    }

    @Test func replayParserCorpora() throws {
        try replayArchives([
            "parser-initial",
        ], target: .parser)
    }

    @Test func replayStreamCorpora() throws {
        try replayArchives([
            "stream-initial",
            "stream-cmin",
        ], target: .stream)
    }

    private enum Target {
        case osc
        case parser
        case stream
    }

    private func replayArchives(
        _ archives: [String],
        target: Target
    ) throws {
        for archive in archives {
            let entries = try GhosttyFuzzArchive.load(named: archive)
            #expect(!entries.isEmpty)

            for entry in entries {
                if ProcessInfo.processInfo.environment["SWIFTTERM_FUZZ_TRACE"] == "1" {
                    print("Ghostty fuzz input \(archive)/\(entry.name)")
                }
                let (terminal, _) = TerminalTestHarness.makeTerminal(
                    cols: 80,
                    rows: 24,
                    scrollback: 100)
                terminal.silentLog = true

                switch target {
                case .osc:
                    let parser = EscapeSequenceParser()
                    replayOsc(entry.bytes, with: parser, in: terminal)
                    assertParserBounds(parser, input: entry.name)
                case .parser:
                    let parser = EscapeSequenceParser()
                    // Ghostty's parser target calls `next` for each byte.
                    // Use one-byte slices to exercise the same input shape.
                    for byte in entry.bytes {
                        parser.parse(data: [byte][...], terminal)
                    }
                    assertParserBounds(parser, input: entry.name)
                case .stream:
                    replayStream(entry.bytes, in: terminal)
                }

                assertTerminalBounds(terminal, input: entry.name)
            }
        }
    }

    private func replayOsc(
        _ input: [UInt8],
        with parser: EscapeSequenceParser,
        in terminal: Terminal
    ) {
        guard let selector = input.first else { return }
        var framed: [UInt8] = [0x1b, 0x5d]
        framed.append(contentsOf: input.dropFirst())
        switch selector % 3 {
        case 0: framed.append(0x07)
        case 1: framed.append(0x9c)
        default: break
        }
        parser.parse(data: framed[...], terminal)
    }

    private func replayStream(_ input: [UInt8], in terminal: Terminal) {
        guard let selector = input.first else { return }
        let payload = input.dropFirst()
        if selector & 1 == 0 {
            terminal.feed(buffer: payload)
        } else {
            for byte in payload {
                terminal.feed(byteArray: [byte])
            }
        }
    }

    private func assertParserBounds(_ parser: EscapeSequenceParser, input: String) {
        #expect(parser._osc.count <= parser.maximumOscBytes,
                "OSC bound exceeded after \(input)")
        #expect(parser._apc.count <= EscapeSequenceParser.maximumApcBytes,
                "APC bound exceeded after \(input)")
        #expect(parser._pars.count <= EscapeSequenceParser.maximumParameterCount,
                "Parameter bound exceeded after \(input)")
        #expect(parser._pars.withView { $0.allSatisfy { $0 <= EscapeSequenceParser.maximumParameterValue } },
                "Parameter value bound exceeded after \(input)")
    }

    private func assertTerminalBounds(_ terminal: Terminal, input: String) {
        // DECCOLM can change an 80-column terminal to 132 columns.
        #expect(terminal.cols >= terminal.MINIMUM_COLS,
                "Column count is invalid after \(input)")
        #expect(terminal.rows >= terminal.MINIMUM_ROWS,
                "Row count is invalid after \(input)")
        #expect(terminal.buffer.cols == terminal.cols,
                "Buffer column count differs after \(input)")
        #expect(terminal.buffer.rows == terminal.rows,
                "Buffer row count differs after \(input)")
        // `x == cols` is SwiftTerm's valid pending-wrap representation.
        #expect(terminal.buffer.x >= 0 && terminal.buffer.x <= terminal.cols,
                "Cursor column is invalid after \(input)")
        #expect(terminal.buffer.y >= 0 && terminal.buffer.y < terminal.rows,
                "Cursor row is invalid after \(input)")
        #expect(terminal.buffer.lines.count <= terminal.rows + 100,
                "Scrollback bound exceeded after \(input)")
        #expect((0..<terminal.buffer.lines.count).allSatisfy {
                    terminal.buffer.lines[$0].count == terminal.cols
                },
                "A line has an invalid width after \(input)")
    }
}

private enum GhosttyFuzzArchive {
    struct Entry {
        let name: String
        let bytes: [UInt8]
    }

    enum ArchiveError: Error, CustomStringConvertible {
        case missing(String)
        case corrupt(String)

        var description: String {
            switch self {
            case .missing(let name): return "Missing Ghostty fuzz archive: \(name)"
            case .corrupt(let reason): return "Corrupt Ghostty fuzz archive: \(reason)"
            }
        }
    }

    static func load(named name: String) throws -> [Entry] {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "stfuzz",
            subdirectory: "GhosttyFuzzCorpus")
            ?? Bundle.module.url(forResource: name, withExtension: "stfuzz") else {
            throw ArchiveError.missing(name)
        }

        let bytes = [UInt8](try Data(contentsOf: url))
        var cursor = 0

        func readBytes(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, cursor <= bytes.count, count <= bytes.count - cursor else {
                throw ArchiveError.corrupt("truncated \(name)")
            }
            defer { cursor += count }
            return bytes[cursor..<(cursor + count)]
        }

        func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let raw = try readBytes(MemoryLayout<T>.size)
            return raw.enumerated().reduce(0) { value, item in
                value | (T(item.element) << T(item.offset * 8))
            }
        }

        guard Array(try readBytes(5)) == Array("STFZ1".utf8) else {
            throw ArchiveError.corrupt("bad magic in \(name)")
        }
        let entryCount = Int(try readInteger(UInt32.self))
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            let nameLength = Int(try readInteger(UInt16.self))
            let entryName = String(decoding: try readBytes(nameLength), as: UTF8.self)
            let inputLength = Int(try readInteger(UInt32.self))
            entries.append(Entry(name: entryName, bytes: Array(try readBytes(inputLength))))
        }

        guard cursor == bytes.count else {
            throw ArchiveError.corrupt("trailing bytes in \(name)")
        }
        return entries
    }
}
