//
//  DecrqssLimitTests.swift
//
//  DECRQSS (DCS $ q) request size limit tests. This file is not restricted
//  to macOS, so that the tests also run on Linux and WASM.
//
//  A payload that is more than the limit receives the invalid reply
//  DCS 0 $ r ST, as xterm sends for an unknown request. Ghostty keeps the
//  same 2-byte limit, but it sends no reply for a longer payload.
//
import Testing

@testable import SwiftTerm

struct DecrqssLimitTests {
    private let esc = "\u{1b}"

    private var invalidReply: [UInt8] {
        Array("\(esc)P0$r\(esc)\\".utf8)
    }

    private func request(_ payload: String) -> String {
        "\(esc)P$q\(payload)\(esc)\\"
    }

    // MARK: - Payload accumulator

    @Test func theAccumulatorKeepsAPayloadAtTheLimit() {
        var payload = Terminal.BoundedDcsPayload(limit: 2)
        payload.append([0x61][...])
        payload.append([0x62][...])
        #expect(payload.take() == [0x61, 0x62])
        #expect(payload.bytes == [])
    }

    @Test func theAccumulatorDiscardsAndDoesNotTruncate() {
        var payload = Terminal.BoundedDcsPayload(limit: 2)
        payload.append([0x61, 0x62][...])
        payload.append([0x63][...])
        #expect(payload.bytes == nil)
        payload.append([0x64][...])
        #expect(payload.take() == nil)
        #expect(payload.bytes == [])
    }

    // MARK: - Limit and known requests

    /// The limit must be the length of the longest known request. If the two
    /// values do not agree, a request is cut off or more bytes are kept than
    /// necessary.
    @Test func theLimitIsTheLengthOfTheLongestKnownRequest() {
        let longest = Terminal.DECRQSS.knownRequests.map { $0.utf8.count }.max()
        #expect(longest == Terminal.DECRQSS.maximumRequestBytes)
    }

    /// Each known request receives one valid reply.
    @Test func eachKnownRequestReceivesAValidReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        for known in Terminal.DECRQSS.knownRequests {
            terminal.feed(text: request(known))
        }
        #expect(delegate.sentData.count == Terminal.DECRQSS.knownRequests.count)
        let prefix = Array("\(esc)P1$r".utf8)
        for reply in delegate.sentData {
            #expect(reply.starts(with: prefix))
        }
    }

    // MARK: - Payloads that are more than the limit

    /// A valid request plus one more byte is discarded, not truncated to the
    /// valid request.
    @Test(arguments: [" qX", "mm", "rr"])
    func aValidRequestWithOneMoreByteIsInvalid(_ payload: String) {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request(payload))
        #expect(delegate.sentData == [invalidReply])
    }

    /// The handler does not keep a payload that is more than the limit, and
    /// it sends one reply only when the request ends.
    @Test func aLongPayloadIsNotKeptAndReceivesOneReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)P$q")
        for _ in 0..<8 {
            terminal.feed(text: "AAAAAAAA")
        }
        let handler = terminal.activeDcsHandlerForTesting as? Terminal.DECRQSS
        #expect(handler != nil)
        #expect(handler?.payload.bytes == nil)
        #expect(delegate.sentData.isEmpty)

        terminal.feed(text: "\(esc)\\")
        #expect(delegate.sentData == [invalidReply])
    }

    /// The limit counts the whole payload, so a valid request that arrives in
    /// two feeds receives its reply.
    @Test func aValidRequestSplitAcrossFeedsReceivesItsReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)[5 q")
        terminal.feed(text: "\(esc)P$q ")
        terminal.feed(text: "q\(esc)\\")
        #expect(delegate.sentData == [Array("\(esc)P1$r5 q\(esc)\\".utf8)])
    }

    /// A valid request after a long request receives its reply.
    @Test func aValidRequestAfterALongRequestReceivesItsReply() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: request(String(repeating: "A", count: 64)))
        terminal.feed(text: "\(esc)[5 q")
        terminal.feed(text: request(" q"))
        #expect(delegate.sentData == [
            invalidReply,
            Array("\(esc)P1$r5 q\(esc)\\".utf8),
        ])
    }

    /// A long request with no terminator sends no reply when the parser
    /// resets, and the next request receives its reply.
    @Test func anUnterminatedLongRequestSendsNothingOnParserReset() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\(esc)P$q" + String(repeating: "A", count: 64))
        terminal.resetParserForTesting()
        #expect(terminal.activeDcsHandlerForTesting == nil)
        #expect(delegate.sentData.isEmpty)

        terminal.feed(text: "\(esc)[5 q")
        terminal.feed(text: request(" q"))
        #expect(delegate.sentData == [Array("\(esc)P1$r5 q\(esc)\\".utf8)])
    }
}
