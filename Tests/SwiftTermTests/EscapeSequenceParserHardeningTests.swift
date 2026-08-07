import Testing
@testable import SwiftTerm

final class EscapeSequenceParserHardeningTests {
    private let esc = "\u{1b}"

    @Test func parameterValuesSaturateAtUInt16Maximum() {
        let parser = EscapeSequenceParser()
        var dispatched: [[Int]] = []
        parser.csiHandlerFallback = { pars, _, _ in dispatched.append(pars) }

        feed(parser, "\(esc)[65535C")
        feed(parser, "\(esc)[65536C")
        feed(parser, "\(esc)[999999999999999999999999999999C")

        #expect(dispatched == [
            [EscapeSequenceParser.maximumParameterValue],
            [EscapeSequenceParser.maximumParameterValue],
            [EscapeSequenceParser.maximumParameterValue],
        ])
    }

    @Test func parameterSaturationIsPreservedAcrossInputChunks() {
        let parser = EscapeSequenceParser()
        var dispatched: [Int] = []
        parser.csiHandlerFallback = { pars, _, _ in
            if let value = pars.first {
                dispatched.append(value)
            }
        }

        feed(parser, "\(esc)[6553")
        feed(parser, "699999999999999999999C")

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
        let parser = RecordingDcsParser(handler: recorder)

        feed(parser, "\(esc)P999999999999999999999999999999p")

        #expect(recorder.hooks.count == 1)
        #expect(recorder.hooks.first?.parameters == [EscapeSequenceParser.maximumParameterValue])
    }

    @Test func csiWithMoreThanMaximumParametersIsDropped() {
        let parser = EscapeSequenceParser()
        var dispatchCount = 0
        parser.csiHandlerFallback = { _, _, _ in dispatchCount += 1 }

        feed(parser, csi(parameterCount: EscapeSequenceParser.maximumParameterCount))
        #expect(dispatchCount == 1)

        feed(parser, csi(parameterCount: EscapeSequenceParser.maximumParameterCount + 1))
        #expect(dispatchCount == 1)

        feed(parser, "\(esc)[1C")
        #expect(dispatchCount == 2)
    }

    @Test func dcsWithMoreThanMaximumParametersIsDropped() {
        let acceptedRecorder = RecordingDcsHandler()
        let acceptedParser = RecordingDcsParser(handler: acceptedRecorder)
        feed(acceptedParser, dcs(parameterCount: EscapeSequenceParser.maximumParameterCount))
        #expect(acceptedRecorder.hooks.count == 1)

        let droppedRecorder = RecordingDcsHandler()
        let droppedParser = RecordingDcsParser(handler: droppedRecorder)
        feed(droppedParser, dcs(parameterCount: EscapeSequenceParser.maximumParameterCount + 1))
        #expect(droppedRecorder.hooks.isEmpty)
    }

    @Test func malformedAndOverflowingOscSelectorsAreDropped() {
        let parser = EscapeSequenceParser()
        var fallbackCodes: [Int] = []
        var saturatedHandlerCalled = false
        parser.oscHandlers[EscapeSequenceParser.maximumParameterValue] = { _ in
            saturatedHandlerCalled = true
        }
        parser.oscHandlerFallback = { code, _ in fallbackCodes.append(code) }

        feed(parser, "\(esc)]12x;invalid\u{7}")
        feed(parser, "\(esc)]999999999999999999999999999999;overflow\u{7}")

        #expect(fallbackCodes.isEmpty)
        #expect(!saturatedHandlerCalled)
    }

    @Test func validOscSelectorsStillSupportTheFullIntRange() {
        let parser = EscapeSequenceParser()
        var fallbackCodes: [Int] = []
        parser.oscHandlerFallback = { code, _ in fallbackCodes.append(code) }

        feed(parser, "\(esc)]\(Int.max);valid\u{7}")
        feed(parser, "\(esc)]\(Int.max)0;overflow\u{7}")

        #expect(fallbackCodes == [Int.max])
    }

    @Test func transitionTableIsSharedAndReadOnlyAfterConstruction() {
        let first = EscapeSequenceParser()
        let second = EscapeSequenceParser()

        #expect(first.table === second.table)
    }

    private func feed(_ parser: EscapeSequenceParser, _ text: String) {
        let bytes = Array(text.utf8)
        parser.parse(data: bytes[...])
    }

    private func csi(parameterCount: Int) -> String {
        "\(esc)[\(Array(repeating: "1", count: parameterCount).joined(separator: ";"))C"
    }

    private func dcs(parameterCount: Int) -> String {
        "\(esc)P\(Array(repeating: "1", count: parameterCount).joined(separator: ";"))p"
    }
}

private final class RecordingDcsHandler: DcsHandler {
    struct Hook {
        let collect: cstring
        let parameters: [Int]
        let flag: UInt8
    }

    var hooks: [Hook] = []

    func hook(collect: cstring, parameters: [Int], flag: UInt8) {
        hooks.append(Hook(collect: collect, parameters: parameters, flag: flag))
    }

    func put(data: ArraySlice<UInt8>) {}
    func unhook() {}
}

private final class RecordingDcsParser: EscapeSequenceParser {
    let handler: RecordingDcsHandler

    init(handler: RecordingDcsHandler) {
        self.handler = handler
        super.init()
    }

    override func dispatchDcs(collect: cstring, code: UInt8, pars: [Int]) -> DcsHandler? {
        handler
    }
}
