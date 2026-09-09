//
//  XtgettcapTests.swift
//
//  XTGETTCAP (DCS + q) protocol and reply tests.
//  Ported from Ghostty's dcs.zig, Source.zig, and stream_terminal.zig tests.
//
import Foundation
import Testing

@testable import SwiftTerm

struct XtgettcapTests {
    private let esc = "\u{1b}"

    /// The complete reply for one request key, with 7-bit framing.
    private func reply(_ key: String, _ value: String? = nil) -> [UInt8] {
        let body = value.map { "\(key)=\($0)" } ?? key
        return Array("\u{1b}P1+r\(body)\u{1b}\\".utf8)
    }

    private func request(_ payload: String) -> String {
        "\(esc)P+q\(payload)\(esc)\\"
    }

    // MARK: - Parser dispatch

    /// From Ghostty: "dcs: XTGETTCAP" in Parser.zig.
    @Test func dcsPlusQSelectsTheXtgettcapHandler() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)P+q")
        #expect(terminal.activeDcsHandlerForTesting is Terminal.XTGETTCAP)
    }

    /// A DCS form that is not `+ q` keeps its own handler.
    @Test func otherDcsFormsAreUnchanged() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)P$q")
        #expect(terminal.activeDcsHandlerForTesting is Terminal.DECRQSS)

        let (other, _) = TerminalTestHarness.makeTerminal()
        other.feed(text: "\(esc)P+p")
        #expect(other.activeDcsHandlerForTesting == nil)
    }

    /// A new DCS must not inherit the handler of an earlier, unterminated one.
    ///
    /// `0x90` (8-bit DCS) restarts the sequence from inside the payload of the
    /// `+ q` request, and `+ p` has no handler, so the terminator must be
    /// silent instead of answering with the leftover XTGETTCAP request.
    @Test func anUnterminatedRequestDoesNotAnswerTheNextDcs() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(byteArray: Array("\(esc)P+q616D".utf8))
        terminal.feed(byteArray: [0x90, 0x2b, 0x70])  // DCS + p
        terminal.feed(byteArray: [0x1b, 0x5c])        // ST
        #expect(terminal.activeDcsHandlerForTesting == nil)
        #expect(delegate.sentData.isEmpty)
    }

    /// The handler ignores DCS parameters, which is what Ghostty does.
    @Test func dcsParametersAreIgnored() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)P1;2+q616D\(esc)\\")
        #expect(delegate.sentData == [reply("616D")])
    }

    // MARK: - Capability value shapes

    /// A Boolean capability replies without an `=`.
    @Test func booleanCapabilityRepliesWithoutAValue() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("616D"))          // am
        #expect(delegate.sentData == [reply("616D")])
    }

    /// A numeric capability replies with its hex-encoded decimal text.
    @Test func numericCapabilityRepliesWithDecimalText() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("636F6C6F7273"))  // colors#256
        #expect(delegate.sentData == [reply("636F6C6F7273", "323536")])
    }

    /// A string without parameters replies with its terminal bytes.
    @Test func controlCharacterStringRepliesWithTerminalBytes() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("62656C;6B6273;6B6631"))  // bel, kbs, kf1
        #expect(delegate.sentData == [
            reply("62656C", "07"),      // ^G
            reply("6B6273", "7F"),      // \177
            reply("6B6631", "1B4F50")   // \EOP
        ])
    }

    /// An escaped comma and an escaped backslash decode to their own byte.
    @Test func escapedPunctuationDecodesToOneByte() throws {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        // acsc starts with `++\,\,--`, so the reply starts with `++,,--`.
        terminal.feed(text: request("61637363"))
        let acsc = try #require(delegate.sentData.first)
        let prefix = Array("\u{1b}P1+r61637363=2B2B2C2C2D2D".utf8)
        #expect(Array(acsc.prefix(prefix.count)) == prefix)

        // rs1 is `\E]\E\\\Ec`, which is ESC ] ESC \ ESC c.
        delegate.clearSentData()
        terminal.feed(text: request("727331"))
        #expect(delegate.sentData == [reply("727331", "1B5D1B5C1B63")])
    }

    /// A string with a parameter expression replies with terminfo source text.
    /// From Ghostty: "xtgettcap map" in Source.zig.
    @Test func parameterizedStringRepliesWithSourceText() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("536D756C78"))    // Smulx
        #expect(delegate.sentData == [reply("536D756C78", "5C455B343A25703125646D")])
    }

    /// `Co` and `RGB` are not terminfo capabilities but are query-able.
    /// From Ghostty: "XTGETTCAP responses" in stream_terminal.zig.
    @Test func colorCapabilitiesUseTheSpecifiedValues() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("436F;524742"))
        #expect(delegate.sentData == [
            reply("436F", "323536"),
            reply("524742", "38")
        ])
    }

    // MARK: - Request-key processing

    /// From Ghostty: "XTGETTCAP mixed case" in dcs.zig.
    @Test func mixedCaseHexadecimalInputWorks() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("536d756C78"))
        #expect(delegate.sentData == [reply("536D756C78", "5C455B343A25703125646D")])
    }

    /// From Ghostty: "XTGETTCAP command multiple keys" in dcs.zig.
    @Test func multipleKeysReplyInRequestOrder() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("436F;616D;524742"))
        #expect(delegate.sentData == [
            reply("436F", "323536"),
            reply("616D"),
            reply("524742", "38")
        ])
    }

    @Test func aRepeatedKeyRepeatsItsReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("616D;616D"))
        #expect(delegate.sentData == [reply("616D"), reply("616D")])
    }

    @Test func anUnknownKeyGetsNoReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        // "zz" is hex-valid but is not a capability of this entry.
        terminal.feed(text: request("7A7A"))
        #expect(delegate.sentData.isEmpty)
    }

    /// An empty, odd-length, or nonhexadecimal key is unknown.
    @Test func aMalformedKeyGetsNoReply() {
        for payload in ["", ";", "616", "WHO", "61;6D", "61 6D"] {
            let (terminal, delegate) = TerminalTestHarness.makeTerminal()
            terminal.feed(text: request(payload))
            #expect(delegate.sentData.isEmpty, "payload \"\(payload)\" must get no reply")
        }
    }

    /// From Ghostty: "XTGETTCAP command invalid data" in dcs.zig.
    @Test func anUnknownKeyDoesNotStopLaterKeys() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("616D;WHO;7A7A;616;536D756C78"))
        #expect(delegate.sentData == [
            reply("616D"),
            reply("536D756C78", "5C455B343A25703125646D")
        ])
    }

    // MARK: - Framing

    @Test func aRequestSplitAcrossFeedsGivesTheSameReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)P+q53")
        terminal.feed(text: "6D75")
        terminal.feed(text: "6C78")
        #expect(delegate.sentData.isEmpty)
        terminal.feed(text: "\(esc)\\")
        #expect(delegate.sentData == [reply("536D756C78", "5C455B343A25703125646D")])
    }

    /// The 8-bit ST input form is accepted, and the reply stays 7-bit.
    ///
    /// SwiftTerm reads its input as UTF-8, so `0x90` in the ground state is a
    /// UTF-8 byte and never the 8-bit DCS introducer. See
    /// `SIMDParserTests.utf8ContinuationByteDoesNotStartDcs`. A request has to
    /// start with the 7-bit `ESC P` form.
    @Test func eightBitTerminatorGivesASevenBitReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        // ESC P + q 616D ST(0x9c)
        terminal.feed(byteArray: [0x1b, 0x50, 0x2b, 0x71, 0x36, 0x31, 0x36, 0x44, 0x9c])
        #expect(delegate.sentData == [reply("616D")])
    }

    /// S8C1T selects 8-bit control output for other replies. XTGETTCAP always
    /// answers with 7-bit framing.
    @Test func s8c1tDoesNotChangeTheReplyFraming() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc) G")               // S8C1T
        terminal.feed(text: request("616D"))
        #expect(delegate.sentData == [reply("616D")])

        delegate.clearSentData()
        terminal.feed(text: "\(esc) F")               // S7C1T
        terminal.feed(text: request("616D"))
        #expect(delegate.sentData == [reply("616D")])
    }

    // MARK: - Dynamic TN

    /// From Ghostty: "XTGETTCAP TN responses" in stream_terminal.zig.
    @Test func terminalNameComesFromTheTerminalOptions() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request("544E"))
        #expect(delegate.sentData == [reply("544E", "787465726D2D323536636F6C6F72")])

        let (named, namedDelegate) = TerminalTestHarness.makeTerminal(termName: "swifterm-terminfo")
        named.feed(text: request("544E"))
        #expect(namedDelegate.sentData
                == [reply("544E", "737769667465726D2D7465726D696E666F")])
    }

    @Test func anEmptyTerminalNameGetsNoReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(termName: "")
        terminal.feed(text: request("544E;616D"))
        #expect(delegate.sentData == [reply("616D")])
    }

    @Test func terminalNameLengthLimit() {
        let allowed = String(repeating: "a", count: 128)
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(termName: allowed)
        terminal.feed(text: request("544E"))
        #expect(delegate.sentData == [reply("544E", String(repeating: "61", count: 128))])

        let tooLong = String(repeating: "a", count: 129)
        let (long, longDelegate) = TerminalTestHarness.makeTerminal(termName: tooLong)
        long.feed(text: request("544E;616D"))
        #expect(longDelegate.sentData == [reply("616D")])
    }

    /// The limit counts UTF-8 bytes, and every byte is hex-encoded rather than
    /// filtered.
    @Test func aNonAsciiTerminalNameIsHexEncoded() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(termName: "é")
        terminal.feed(text: request("544E"))
        #expect(delegate.sentData == [reply("544E", "C3A9")])
    }

    // MARK: - Request limits and lifetime

    @Test func aRequestAtTheSizeLimitIsAnswered() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        // "616D;" plus a padding key that fills the payload to exactly 1 MiB.
        // The padding is not hexadecimal, so it is its own unknown key.
        let padding = String(repeating: "z", count: 1024 * 1024 - 5)
        terminal.feed(text: request("616D;\(padding)"))
        #expect(delegate.sentData == [reply("616D")])
    }

    @Test func anOversizedRequestIsDroppedAndDoesNotBreakTheNextRequest() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        let padding = String(repeating: "z", count: 1024 * 1024 - 4)
        terminal.feed(text: request("616D;\(padding)"))
        #expect(delegate.sentData.isEmpty)

        terminal.feed(text: request("616D"))
        #expect(delegate.sentData == [reply("616D")])
    }

    /// The limit is on the whole payload, not on one parser input block.
    @Test func theSizeLimitSpansFeedCalls() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        let block = String(repeating: "z", count: 512 * 1024)
        terminal.feed(text: "\(esc)P+q616D;")
        for _ in 0..<3 {
            terminal.feed(text: block)
        }
        terminal.feed(text: "\(esc)\\")
        #expect(delegate.sentData.isEmpty)
    }

    /// An unterminated request replies with nothing, and its storage goes away
    /// with the parser reset.
    /// From Ghostty: "DCS command memory is released" in stream_terminal.zig.
    @Test func aCanceledRequestSendsNoPartialReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)P+q616D;536D756C78")
        #expect(delegate.sentData.isEmpty)

        terminal.resetParserForTesting()
        #expect(terminal.activeDcsHandlerForTesting == nil)
        #expect(delegate.sentData.isEmpty)

        terminal.feed(text: request("616D"))
        #expect(delegate.sentData == [reply("616D")])
    }

    /// An escape ends the DCS string, so the keys collected up to that point
    /// still get their replies and the next sequence runs normally.
    @Test func anInterruptedRequestRepliesAndRunsTheNextSequence() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[5;5H")
        terminal.feed(text: "\(esc)P+q616D")
        terminal.feed(text: "\(esc)[H")
        #expect(delegate.sentData == [reply("616D")])
        #expect(terminal.buffer.x == 0)
        #expect(terminal.buffer.y == 0)
    }

    /// A terminal with no live delegate completes a request without an error.
    /// From Ghostty: "XTGETTCAP without write effect is ignored".
    @Test func aTerminalWithNoDelegateCompletesTheRequest() {
        var delegate: TerminalTestDelegate? = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate!, options: TerminalOptions())
        delegate = nil
        terminal.feed(text: request("616D;544E;7A7A"))
        #expect(terminal.tdel == nil)
    }

    /// XTGETTCAP reports state but never changes it.
    @Test func aRequestDoesNotChangeTerminalState() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[31mAB")
        let cell = try #require(TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0))
        let position = TerminalTestHarness.cursorPosition(buffer: terminal.buffer)

        terminal.feed(text: request("616D;544E;436F"))
        let after = try #require(TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0))
        #expect(after.code == cell.code)
        #expect(after.attribute == cell.attribute)
        #expect(TerminalTestHarness.cursorPosition(buffer: terminal.buffer) == position)

        // The graphic rendition that was in effect still applies.
        terminal.feed(text: "C")
        let next = try #require(TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 2))
        #expect(next.attribute == cell.attribute)
    }

    // MARK: - Generated table

    /// From Ghostty: "xtgettcap map" in Source.zig, as a generated-table test.
    @Test func theGeneratedTableHasEveryCapabilityAndTheTwoExtraKeys() throws {
        let names = try TerminfoFixture.capabilityNames()
        #expect(names.count == 268)

        for name in names {
            let key = TerminfoFixture.hexEncoded(name)
            #expect(SwiftTermTerminfo.xtgettcapReplies[key] != nil,
                    "the table has no entry for \(name)")
        }
        #expect(SwiftTermTerminfo.xtgettcapReplies.count == 270)
        #expect(SwiftTermTerminfo.xtgettcapReplies["436F"] != nil)   // Co
        #expect(SwiftTermTerminfo.xtgettcapReplies["524742"] != nil) // RGB
        #expect(SwiftTermTerminfo.xtgettcapReplies["544E"] == nil)   // TN is dynamic
    }

    /// Every stored reply carries complete 7-bit framing and holds only bytes
    /// that are safe to send unchanged.
    @Test func everyStoredReplyIsSafeToSend() {
        for (key, response) in SwiftTermTerminfo.xtgettcapReplies {
            let bytes = Array(response.utf8)
            #expect(Array(bytes.prefix(5)) == [0x1b, 0x50, 0x31, 0x2b, 0x72])
            #expect(Array(bytes.suffix(2)) == [0x1b, 0x5c])
            #expect(response.hasPrefix("\u{1b}P1+r\(key)"))

            let body = bytes.dropFirst(5).dropLast(2)
            for byte in body {
                let isHex = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46)
                #expect(isHex || byte == UInt8(ascii: "="), "reply for \(key) has a raw byte")
            }
        }
    }
}
