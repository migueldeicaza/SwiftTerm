import Testing
@testable import SwiftTerm

final class SIMDParserTests {
    private let esc: UInt8 = 0x1b

    @Test func oscTerminatorsWorkAtEveryVectorLane() {
        let terminators: [(bytes: [UInt8], dispatches: Bool)] = [
            ([0x07], true),
            ([0x18], false),
            ([0x1a], false),
            ([0x1b, 0x5c], true)
        ]

        for payloadCount in 0..<32 {
            let payload = Array(repeating: UInt8(0x61), count: payloadCount)
            for terminator in terminators {
                let result = parseOsc(payload: payload, terminator: terminator.bytes)
                #expect(result.state == .ground)
                #expect(result.payloads == (terminator.dispatches ? [payload] : []))
            }
        }
    }

    @Test func oscResultsDoNotDependOnInputChunks() {
        let payload: [UInt8] = [0x41, 0x7f, 0xc3, 0xa9, 0x42]
        let terminators: [(bytes: [UInt8], dispatches: Bool)] = [
            ([0x07], true),
            ([0x18], false),
            ([0x1a], false),
            ([0x1b, 0x5c], true)
        ]

        for terminator in terminators {
            let input = oscInput(payload: payload, terminator: terminator.bytes)
            for split in 0...input.count {
                let result = parseOsc(
                    payload: payload,
                    terminator: terminator.bytes,
                    splitAt: split)
                #expect(result.state == .ground)
                #expect(result.payloads == (terminator.dispatches ? [payload] : []))
            }
        }
    }

    @Test func oscIgnoresOtherC0BytesAndKeepsPayloadBytes() {
        let payload: [UInt8] = [0x41, 0x01, 0x42, 0x7f, 0xc3, 0xa9]
        let result = parseOsc(payload: payload, terminator: [0x07])

        #expect(result.state == .ground)
        #expect(result.payloads == [[0x41, 0x42, 0x7f, 0xc3, 0xa9]])
    }

    @Test func oscPreservesUtf8ContinuationBytesAcrossInputChunks() {
        let payload = Array(repeating: UInt8(0x61), count: 17) + [0xc3, 0x9c, 0x62]
        let input = oscInput(payload: payload, terminator: [0x07])

        for split in 0...input.count {
            let result = parseOsc(payload: payload, terminator: [0x07], splitAt: split)
            #expect(result.state == .ground)
            #expect(result.payloads == [payload])
        }
    }

    @Test func apcTerminatorsDoNotDependOnInputChunks() {
        let payload = Array(repeating: UInt8(0x61), count: 33)
        let terminators: [[UInt8]] = [
            [0x07],
            [0x18],
            [0x1a],
            [0x1b, 0x5c]
        ]

        for terminator in terminators {
            let input = apcInput(payload: payload, terminator: terminator)
            for split in 0...input.count {
                let (parser, terminal) = makeParser()
                parser.parse(data: input[..<split], terminal)
                parser.parse(data: input[split...], terminal)

                #expect(parser.currentState == .ground)
                #expect(parser._apc.isEmpty)
            }
        }
    }

    @Test func apcPreservesUtf8ContinuationBytesAcrossInputChunks() {
        let payload = Array(repeating: UInt8(0x61), count: 17) + [0xc3, 0x9c, 0x62]
        let input = [esc, 0x5f, 0x58] + payload

        for split in 0...input.count {
            let (parser, terminal) = makeParser()
            parser.parse(data: input[..<split], terminal)
            parser.parse(data: input[split...], terminal)

            #expect(parser.currentState == .apcString)
            #expect(parser._apc == [0x58] + payload)

            parser.parse(data: [UInt8(0x07)][...], terminal)
            #expect(parser.currentState == .ground)
            #expect(parser._apc.isEmpty)
        }
    }

    @Test func groundAndUtf8ResultsDoNotDependOnInputChunks() {
        let input = Array(repeating: UInt8(0x41), count: 31) +
            [0x00] +
            Array("é".utf8) +
            [0xff] +
            Array(repeating: UInt8(0x42), count: 31)
        let oneShot = parseTerminalText(input: input, splitAt: nil)

        for split in 0...input.count {
            let splitResult = parseTerminalText(input: input, splitAt: split)
            #expect(splitResult.lines == oneShot.lines)
            #expect(splitResult.cursor == oneShot.cursor)
        }
    }

    private func parseOsc(
        payload: [UInt8],
        terminator: [UInt8],
        splitAt split: Int? = nil
    ) -> (payloads: [[UInt8]], state: ParserState) {
        let (parser, terminal) = makeParser()
        var payloads: [[UInt8]] = []
        parser.oscHandlers[777] = { payloads.append(Array($0)) }
        let input = oscInput(payload: payload, terminator: terminator)

        if let split {
            parser.parse(data: input[..<split], terminal)
            parser.parse(data: input[split...], terminal)
        } else {
            parser.parse(data: input[...], terminal)
        }
        return (payloads, parser.currentState)
    }

    private func oscInput(payload: [UInt8], terminator: [UInt8]) -> [UInt8] {
        return [esc, 0x5d] + Array("777;".utf8) + payload + terminator
    }

    private func apcInput(payload: [UInt8], terminator: [UInt8]) -> [UInt8] {
        return [esc, 0x5f, 0x58] + payload + terminator
    }

    private func makeParser() -> (EscapeSequenceParser, Terminal) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 100, rows: 2)
        terminal.silentLog = true
        return (EscapeSequenceParser(), terminal)
    }

    private func parseTerminalText(
        input: [UInt8],
        splitAt split: Int?
    ) -> (lines: [String], cursor: Position) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 100, rows: 2)
        terminal.silentLog = true
        if let split {
            terminal.feed(byteArray: Array(input[..<split]))
            terminal.feed(byteArray: Array(input[split...]))
        } else {
            terminal.feed(byteArray: input)
        }
        return (
            TerminalTestHarness.visibleLinesText(buffer: terminal.buffer, terminal: terminal),
            TerminalTestHarness.cursorPosition(buffer: terminal.buffer))
    }
}
