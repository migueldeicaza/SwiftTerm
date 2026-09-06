import Foundation
import Testing
@testable import SwiftTerm

final class EscapeSequenceParserHardeningTests {
    private let esc = "\u{1b}"

    @Test func parameterValuesSaturateAtUInt16Maximum() {
        let (parser, terminal) = makeParser()
        var dispatched: [[Int]] = []
        parser.dcsHandlerFactory = { _, _, pars in
            dispatched.append(Array(pars))
            return RecordingDcsHandler()
        }

        feed(parser, terminal, "\(esc)P65535p")
        feed(parser, terminal, "\(esc)P65536p")
        feed(parser, terminal, "\(esc)P999999999999999999999999999999p")

        #expect(dispatched == [
            [EscapeSequenceParser.maximumParameterValue],
            [EscapeSequenceParser.maximumParameterValue],
            [EscapeSequenceParser.maximumParameterValue],
        ])
    }

    @Test func parameterSaturationIsPreservedAcrossInputChunks() {
        let (parser, terminal) = makeParser()
        var dispatched: [Int] = []
        parser.dcsHandlerFactory = { _, _, pars in
            if let value = pars.first {
                dispatched.append(value)
            }
            return RecordingDcsHandler()
        }

        feed(parser, terminal, "\(esc)P6553")
        feed(parser, terminal, "699999999999999999999p")

        #expect(dispatched == [EscapeSequenceParser.maximumParameterValue])
    }

    @Test func saturatedParametersRemainSafeInTerminalCommands() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        terminal.feed(text: "\(esc)[10;10H")
        terminal.feed(text: "\(esc)[999999999999999999999999999999B")
        terminal.feed(text: "\(esc)[999999999999999999999999999999C")

        TerminalTestHarness.assertCursor(terminal.buffer, col: 79, row: 23)
    }

    @Test func dcsParameterValuesSaturateAtUInt16Maximum() {
        let recorder = RecordingDcsHandler()
        let (parser, terminal) = makeParser()
        parser.dcsHandlerFactory = { _, _, _ in recorder }

        feed(parser, terminal, "\(esc)P999999999999999999999999999999p")

        #expect(recorder.hooks.count == 1)
        #expect(recorder.hooks.first?.parameters == [EscapeSequenceParser.maximumParameterValue])
    }

    @Test func csiWithMoreThanMaximumParametersIsDropped() {
        let (parser, terminal) = makeParser(cols: 10, rows: 1)

        feed(parser, terminal, csi(parameterCount: EscapeSequenceParser.maximumParameterCount))
        #expect(terminal.buffer.x == 1)

        feed(parser, terminal, csi(parameterCount: EscapeSequenceParser.maximumParameterCount + 1))
        #expect(terminal.buffer.x == 1)

        feed(parser, terminal, "\(esc)[1C")
        #expect(terminal.buffer.x == 2)
    }

    @Test func dcsWithMoreThanMaximumParametersIsDropped() {
        let acceptedRecorder = RecordingDcsHandler()
        let (acceptedParser, acceptedTerminal) = makeParser()
        acceptedParser.dcsHandlerFactory = { _, _, _ in acceptedRecorder }
        feed(acceptedParser, acceptedTerminal, dcs(parameterCount: EscapeSequenceParser.maximumParameterCount))
        #expect(acceptedRecorder.hooks.count == 1)

        let droppedRecorder = RecordingDcsHandler()
        let (droppedParser, droppedTerminal) = makeParser()
        droppedParser.dcsHandlerFactory = { _, _, _ in droppedRecorder }
        feed(droppedParser, droppedTerminal, dcs(parameterCount: EscapeSequenceParser.maximumParameterCount + 1))
        #expect(droppedRecorder.hooks.isEmpty)
    }

    @Test func malformedAndOverflowingOscSelectorsAreDropped() {
        let (parser, terminal) = makeParser()
        var saturatedHandlerCalled = false
        parser.oscHandlers[EscapeSequenceParser.maximumParameterValue] = { _ in
            saturatedHandlerCalled = true
        }

        feed(parser, terminal, "\(esc)]12x;invalid\u{7}")
        feed(parser, terminal, "\(esc)]999999999999999999999999999999;overflow\u{7}")

        #expect(!saturatedHandlerCalled)
    }

    @Test func validOscSelectorsStillSupportTheFullIntRange() {
        let (parser, terminal) = makeParser()
        var handlerCallCount = 0
        parser.oscHandlers[Int.max] = { _ in handlerCallCount += 1 }

        feed(parser, terminal, "\(esc)]\(Int.max);valid\u{7}")
        feed(parser, terminal, "\(esc)]\(Int.max)0;overflow\u{7}")

        #expect(handlerCallCount == 1)
    }

    @Test func oversizedOscTreatsC1StAsPayloadAndRecovers() {
        let prefix = Array("\(esc)]77;abcdef".utf8)
        let suffix = [UInt8(0xc5), 0x9c] + Array("[5CX".utf8) + [ControlCodes.BEL]
        let chunkings = [
            [prefix + suffix],
            [prefix + [0xc5], Array(suffix.dropFirst())],
            [prefix, suffix],
        ]

        for chunks in chunkings {
            let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
            terminal.silentLog = true
            let parser = EscapeSequenceParser(maximumOscBytes: 8)
            var received: [String] = []
            parser.oscHandlers[77] = { received.append(String(decoding: $0, as: UTF8.self)) }

            for chunk in chunks {
                feed(parser, terminal, chunk)
            }
            feed(parser, terminal, "\(esc)]77;ok\u{7}")

            #expect(received == ["ok"])
            #expect(terminal.buffer.x == 0)
            TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "")
        }
    }

    @Test func bareEscapeDispatchesTitleOscBeforeStartingCsi() {
        let delegate = BareEscapeOscDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 10, rows: 2, scrollback: 0))
        terminal.feed(text: "\(esc)[2;4H")

        terminal.feed(text: "\(esc)]0;Title\(esc)[H")

        #expect(delegate.titles == ["Title"])
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }

    @Test func bareEscapeDispatchesClipboardOscBeforeStartingCsi() {
        let delegate = BareEscapeOscDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 10, rows: 2, scrollback: 0))
        terminal.feed(text: "\(esc)[2;4H")

        terminal.feed(text: "\(esc)]52;c;aGVsbG8=\(esc)[H")

        #expect(delegate.clipboardContent == Data("hello".utf8))
        TerminalTestHarness.assertCursor(terminal.buffer, col: 0, row: 0)
    }

    @Test func transitionTableIsSharedAndReadOnlyAfterConstruction() {
        let first = EscapeSequenceParser()
        let second = EscapeSequenceParser()

        #expect(first.table === second.table)
    }

    @Test func everyByteIsSafeInEveryParserState() {
        for rawState in ParserState.ground.rawValue...ParserState.dcsPassthrough.rawValue {
            let state = ParserState(rawValue: rawState)!
            let (parser, terminal) = makeParser()

            for byte in UInt8.min...UInt8.max {
                parser.reset(terminal)
                parser.currentState = state
                parser.parse(data: [byte][...], terminal)

                #expect(parser.currentState.rawValue <= ParserState.dcsPassthrough.rawValue)
            }
        }
    }

    @Test func reusedParameterStorageDoesNotLeakPriorParameters() {
        let (parser, terminal) = makeParser()
        var dispatched: [[Int]] = []
        parser.dcsHandlerFactory = { _, _, pars in
            dispatched.append(Array(pars))
            return RecordingDcsHandler()
        }

        feed(parser, terminal, "\(dcs(parameterCount: EscapeSequenceParser.maximumParameterCount))\(esc)\\")
        feed(parser, terminal, "\(esc)P7p")

        #expect(dispatched == [
            Array(repeating: 1, count: EscapeSequenceParser.maximumParameterCount),
            [7],
        ])
    }

    @Test func nestedOscFeedRestoresEmptyParameterStorage() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        let nestedSequence = "\(esc)[1C"
        var handlerCallCount = 0
        terminal.registerOscHandler(code: 777) { [unowned terminal] _ in
            handlerCallCount += 1
            terminal.feed(text: nestedSequence)
        }

        terminal.feed(text: "\(esc)]777;nested\u{7}")

        #expect(handlerCallCount == 1)
        #expect(terminal.buffer.x == 1)
    }

    @Test func risAbandonsTheCurrentParserSequence() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)

        terminal.feed(text: "\(esc)[12")
        terminal.feed(text: "\(esc)c")
        terminal.feed(text: "X")

        TerminalTestHarness.assertLineText(terminal.buffer, row: 0, equals: "X")
    }

    @Test func largeApcSequenceDoesNotKeepItsBuffer() {
        let (parser, terminal) = makeParser()
        let payload = String(repeating: "a", count: 2 * 1024 * 1024)
        feed(parser, terminal, "\(esc)_X\(payload)\(esc)\\")
        // The accumulator is cleared when the next sequence begins. A buffer
        // this large must be handed back rather than kept for the life of the
        // terminal, which is what an oversized APC would otherwise pin.
        feed(parser, terminal, "\(esc)[0m")
        #expect(parser._apc.isEmpty)
        #expect(parser._apc.capacity <= EscapeSequenceParser.maximumRetainedApcBytes)
    }

    @Test func modestApcSequenceKeepsItsBufferForReuse() {
        let (parser, terminal) = makeParser()
        feed(parser, terminal, "\(esc)_XGa=t,f=32,s=1,v=1;AQIDBA==\(esc)\\")
        feed(parser, terminal, "\(esc)[0m")
        #expect(parser._apc.isEmpty)
        #expect(parser._apc.capacity > 0)
    }

    private func makeParser(cols: Int = 80, rows: Int = 24) -> (EscapeSequenceParser, Terminal) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows)
        terminal.silentLog = true
        return (EscapeSequenceParser(), terminal)
    }

    private func feed(_ parser: EscapeSequenceParser, _ terminal: Terminal, _ text: String) {
        let bytes = Array(text.utf8)
        parser.parse(data: bytes[...], terminal)
    }

    private func feed(_ parser: EscapeSequenceParser, _ terminal: Terminal, _ bytes: [UInt8]) {
        parser.parse(data: bytes[...], terminal)
    }

    private func csi(parameterCount: Int) -> String {
        "\(esc)[\(Array(repeating: "1", count: parameterCount).joined(separator: ";"))C"
    }

    private func dcs(parameterCount: Int) -> String {
        "\(esc)P\(Array(repeating: "1", count: parameterCount).joined(separator: ";"))p"
    }
}

private final class BareEscapeOscDelegate: TerminalDelegate {
    private(set) var clipboardContent: Data?
    private(set) var titles: [String] = []

    func clipboardCopy(source: Terminal, content: Data) {
        clipboardContent = content
    }

    func setTerminalTitle(source: Terminal, title: String) {
        titles.append(title)
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

private final class RecordingDcsHandler: DcsHandler {
    struct Hook {
        let collect: cstring
        let parameters: [Int]
        let flag: UInt8
    }

    var hooks: [Hook] = []

    func hook(collect: cstring, parameters: CsiParameters, flag: UInt8) {
        hooks.append(Hook(collect: collect, parameters: Array(parameters), flag: flag))
    }

    func put(data: ArraySlice<UInt8>) {}
    func unhook() {}
}
