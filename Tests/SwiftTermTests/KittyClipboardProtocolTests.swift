import Foundation
import Testing
@testable import SwiftTerm

final class KittyClipboardTestDelegate: TerminalDelegate, @unchecked Sendable {
    struct State {
        var sent: [[UInt8]] = []
        var pasteEventsSupported = false
        var readResult: KittyClipboardReadResult = .denied
        var writeResult: KittyClipboardWriteResult = .unsupported
        var readRequests: [KittyClipboardReadRequest] = []
        var writeRequests: [KittyClipboardWriteRequest] = []
        var deferredRead: (@Sendable (KittyClipboardReadResult) -> Void)?
        var deferredWrite: (@Sendable (KittyClipboardWriteResult) -> Void)?
        var deferReads = false
        var deferWrites = false
        var callbackHadTerminalLock = false
    }

    let state = Locked(State())
    private let sendSignal = DispatchSemaphore(value: 0)

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        state.withLock { $0.sent.append(Array(data)) }
        sendSignal.signal()
    }

    func kittyClipboardRead(
        source: Terminal,
        request: KittyClipboardReadRequest,
        completion: @escaping @Sendable (KittyClipboardReadResult) -> Void
    ) {
        let result = state.withLock { state -> KittyClipboardReadResult? in
            state.callbackHadTerminalLock = source.terminalLock.isLockedByCurrentThread
            state.readRequests.append(request)
            if state.deferReads {
                state.deferredRead = completion
                return nil
            }
            return state.readResult
        }
        if let result { completion(result) }
    }

    func kittyClipboardWrite(
        source: Terminal,
        request: KittyClipboardWriteRequest,
        completion: @escaping @Sendable (KittyClipboardWriteResult) -> Void
    ) {
        let result = state.withLock { state -> KittyClipboardWriteResult? in
            state.callbackHadTerminalLock = source.terminalLock.isLockedByCurrentThread
            state.writeRequests.append(request)
            if state.deferWrites {
                state.deferredWrite = completion
                return nil
            }
            return state.writeResult
        }
        if let result { completion(result) }
    }

    func kittyClipboardPasteEventsSupported(source: Terminal) -> Bool {
        state.withLock { $0.pasteEventsSupported }
    }

    func completeRead(_ result: KittyClipboardReadResult, keep: Bool = false) {
        let completion = state.withLock { state in
            let value = state.deferredRead
            if !keep { state.deferredRead = nil }
            return value
        }
        completion?(result)
    }

    func completeWrite(_ result: KittyClipboardWriteResult, keep: Bool = false) {
        let completion = state.withLock { state in
            let value = state.deferredWrite
            if !keep { state.deferredWrite = nil }
            return value
        }
        completion?(result)
    }

    func clearSent() {
        state.withLock { $0.sent.removeAll() }
    }

    var outputBytes: [UInt8] {
        state.withLock { $0.sent.flatMap { $0 } }
    }

    var output: String { String(decoding: outputBytes, as: UTF8.self) }

    func waitForSends(_ count: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while state.withLock({ $0.sent.count }) < count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            _ = sendSignal.wait(timeout: .now() + min(remaining, 0.1))
        }
        return true
    }
}

enum KittyClipboardTestSupport {
    static let esc = "\u{1b}"

    static func makeTerminal(
        readResult: KittyClipboardReadResult = .denied,
        writeResult: KittyClipboardWriteResult = .unsupported
    ) -> (Terminal, KittyClipboardTestDelegate) {
        let delegate = KittyClipboardTestDelegate()
        delegate.state.withLock {
            $0.readResult = readResult
            $0.writeResult = writeResult
        }
        return (Terminal(delegate: delegate), delegate)
    }

    static func feed(_ terminal: Terminal, _ text: String) {
        terminal.terminalLock.withLock { terminal.feed(text: text) }
    }

    static func feed(_ terminal: Terminal, bytes: ArraySlice<UInt8>) {
        terminal.terminalLock.withLock { terminal.feed(buffer: bytes) }
    }

    static func locked<T>(_ terminal: Terminal, _ body: (Terminal) -> T) -> T {
        terminal.terminalLock.withLock { body(terminal) }
    }

    static func osc(_ body: String, bell: Bool = false) -> String {
        "\u{1b}]5522;\(body)" + (bell ? "\u{7}" : "\u{1b}\\")
    }

    static func b64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    static func packets(_ bytes: [UInt8]) -> [String] {
        let prefix = Array("\u{1b}]5522;".utf8)
        var result: [String] = []
        var index = 0
        while index + prefix.count <= bytes.count {
            guard bytes[index..<(index + prefix.count)].elementsEqual(prefix) else {
                index += 1
                continue
            }
            let start = index + prefix.count
            var end = start
            while end + 1 < bytes.count,
                  !(bytes[end] == ControlCodes.ESC && bytes[end + 1] == UInt8(ascii: "\\"))
            {
                end += 1
            }
            result.append(String(decoding: bytes[start..<end], as: UTF8.self))
            index = end + 2
        }
        return result
    }

    static func payload(_ packet: String) -> Data? {
        guard let separator = packet.firstIndex(of: ";") else { return nil }
        return Data(base64Encoded: String(packet[packet.index(after: separator)...]))
    }
}

@Suite(.serialized)
struct KittyClipboardProtocolTests {
    typealias S = KittyClipboardTestSupport

    @Test func configurationEnforcesNormativeMinimum() {
        #expect(TerminalOptions.default.kittyClipboard.writeLimitBytes == 64 * 1024 * 1024)
        let enabled = KittyClipboardConfiguration(enabled: true, writeLimitBytes: 1)
        #expect(enabled.writeLimitBytes == KittyClipboardConfiguration.minimumWriteLimitBytes)
        let disabled = KittyClipboardConfiguration(enabled: false, writeLimitBytes: 1)
        #expect(disabled.writeLimitBytes == 1)
        let unlimited = KittyClipboardConfiguration(enabled: true, writeLimitBytes: nil)
        #expect(unlimited.writeLimitBytes == nil)
    }

    @Test func metadataIDStrictBase64AndTerminators() {
        let success = KittyClipboardReadSuccess(
            representations: [], availableTypes: [], remember: false)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(success))

        S.feed(terminal, S.osc("unknown=x:type=read:id=bad!:id=good.;", bell: true))
        #expect(delegate.output ==
            "\u{1b}]5522;type=read:status=OK:id=good.\u{1b}\\" +
            "\u{1b}]5522;type=read:status=DONE:id=good.\u{1b}\\")

        for body in [
            "", "x=y", "type=nope", "type=read;!!!", "type=read;Y Q==",
            "type=read:name=__8=;", "type=read:name=YQ=;"
        ] {
            delegate.clearSent()
            S.feed(terminal, S.osc(body))
            #expect(delegate.output.isEmpty)
        }
    }

    @Test func metadataAndRequestedTypeLimits() throws {
        let success = KittyClipboardReadSuccess(
            representations: [], availableTypes: [], remember: false)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(success))
        let longID = String(repeating: "a", count: 513)
        let requested = (0..<65).map { "type/\($0)" }.joined(separator: " ")
        S.feed(terminal, S.osc(
            "type=read:id=\(longID):name=\(S.b64(String(repeating: "n", count: 256)));\(S.b64(requested))"))
        let request = try #require(delegate.state.withLock { $0.readRequests.first })
        #expect(request.types.count == 64)
        #expect(request.applicationName?.utf8.count == 256)
        let ok = try #require(S.packets(delegate.outputBytes).first)
        let id = try #require(ok.split(separator: ":").first { $0.hasPrefix("id=") })
        #expect(id.dropFirst(3).utf8.count == 512)

        let count = delegate.state.withLock { $0.readRequests.count }
        S.feed(terminal, S.osc(
            "type=read:name=\(S.b64(String(repeating: "n", count: 257)));"))
        #expect(delegate.state.withLock { $0.readRequests.count } == count)

        S.feed(terminal, S.osc(
            "type=read:pw=\(S.b64(String(repeating: "p", count: 129))):name=YXBw;\(S.b64("text/plain"))"))
        let oversizedPassword = try #require(delegate.state.withLock { $0.readRequests.last })
        #expect(!oversizedPassword.canRemember)
    }

    @Test func readFixtureOrderingFilteringPrimaryAndIDs() {
        let success = KittyClipboardReadSuccess(
            representations: [
                KittyClipboardRepresentation(type: "text/html", data: Data("<b>hi</b>".utf8)),
                KittyClipboardRepresentation(type: "ignored/type", data: Data("no".utf8)),
                KittyClipboardRepresentation(type: "text/plain", data: Data("Ghostty".utf8))
            ],
            availableTypes: ["text/plain", "text/html"],
            remember: false)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(success))
        S.feed(terminal, S.osc(
            "type=read:loc=primary:id=*r 1*;\(S.b64(". text/plain text/html"))"))

        #expect(delegate.output ==
            "\u{1b}]5522;type=read:status=OK:loc=primary:id=r1\u{1b}\\" +
            "\u{1b}]5522;type=read:status=DATA:id=r1:mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\u{1b}\\" +
            "\u{1b}]5522;type=read:status=DATA:id=r1:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\u{1b}\\" +
            "\u{1b}]5522;type=read:status=DATA:id=r1:mime=dGV4dC9odG1s;PGI+aGk8L2I+\u{1b}\\" +
            "\u{1b}]5522;type=read:status=DONE:id=r1\u{1b}\\")
    }

    @Test func readChunkEdgesAndEmptyRepresentation() throws {
        for size in [0, 1, 4095, 4096, 4097, 16385] {
            let data = Data((0..<size).map { UInt8($0 & 0xff) })
            let success = KittyClipboardReadSuccess(
                representations: [KittyClipboardRepresentation(type: "application/octet-stream", data: data)],
                availableTypes: [], remember: false)
            let (terminal, delegate) = S.makeTerminal(readResult: .success(success))
            S.feed(terminal, S.osc("type=read;\(S.b64("application/octet-stream"))"))
            let dataPackets = S.packets(delegate.outputBytes).filter { $0.contains("status=DATA") }
            let chunks = try dataPackets.map { try #require(S.payload($0)) }
            #expect(chunks.flatMap { $0 } == Array(data))
            #expect(chunks.allSatisfy { $0.count <= 4096 })
            #expect(dataPackets.count == max(1, (size + 4095) / 4096))
        }
    }

    @Test func listingEmptyAndLargeSplitsAt4096() throws {
        var types: [String] = []
        while (types.joined(separator: " ") + "\n").utf8.count <= 4096 {
            types.append("application/x-\(types.count)-xxxxxxxxxxxxxxxx")
        }
        let success = KittyClipboardReadSuccess(
            representations: [], availableTypes: types, remember: false)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(success))
        S.feed(terminal, S.osc("type=read;Lg=="))
        let chunks = try S.packets(delegate.outputBytes)
            .filter { $0.contains("status=DATA") }
            .map { try #require(S.payload($0)) }
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 4096 })
        #expect(String(decoding: chunks.flatMap { $0 }, as: UTF8.self) ==
            types.joined(separator: " ") + "\n")

        delegate.clearSent()
        delegate.state.withLock {
            $0.readResult = .success(KittyClipboardReadSuccess(
                representations: [], availableTypes: [], remember: false))
        }
        S.feed(terminal, S.osc("type=read;Lg=="))
        let emptyData = try #require(S.packets(delegate.outputBytes).first { $0.contains("status=DATA") })
        #expect(emptyData.hasSuffix(";"))
    }

    @Test func packetCanBeSplitAtEveryByteBoundary() {
        let request = Array(S.osc("type=read:id=split;Lg==").utf8)
        for boundary in 0...request.count {
            let success = KittyClipboardReadSuccess(
                representations: [], availableTypes: [], remember: false)
            let (terminal, delegate) = S.makeTerminal(readResult: .success(success))
            S.feed(terminal, bytes: request[..<boundary])
            S.feed(terminal, bytes: request[boundary...])
            #expect(delegate.output.contains("type=read:status=DONE:id=split"))
        }
    }

    @Test func ghosttyWriteFixtureAndAlias() throws {
        let done = KittyClipboardWriteResult.success(KittyClipboardWriteSuccess(remember: false))
        let (terminal, delegate) = S.makeTerminal(writeResult: done)
        S.feed(terminal, S.osc("type=write:id=42"))
        S.feed(terminal, S.osc("type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q="))
        S.feed(terminal, S.osc("type=wdata:mime=dGV4dC9wbGFpbg==;dHk="))
        S.feed(terminal, S.osc("type=wdata:mime=dGV4dC9odG1s;PGI+aGk8L2I+"))
        S.feed(terminal, S.osc(
            "type=walias:mime=dGV4dC9wbGFpbg==;VEVYVCBVVEY4X1NUUklORw=="))
        S.feed(terminal, S.osc("type=wdata"))

        #expect(delegate.output == "\u{1b}]5522;type=write:status=DONE:id=42\u{1b}\\")
        let write = try #require(delegate.state.withLock { $0.writeRequests.first })
        #expect(write.representations == [
            KittyClipboardRepresentation(type: "text/plain", data: Data("Ghostty".utf8)),
            KittyClipboardRepresentation(type: "text/html", data: Data("<b>hi</b>".utf8)),
            KittyClipboardRepresentation(type: "TEXT", data: Data("Ghostty".utf8)),
            KittyClipboardRepresentation(type: "UTF8_STRING", data: Data("Ghostty".utf8))
        ])
    }

    @Test func streamingQuartetSplitsAndPaddedPacketSegments() throws {
        let done = KittyClipboardWriteResult.success(KittyClipboardWriteSuccess(remember: false))
        for split in 1...3 {
            let (terminal, delegate) = S.makeTerminal(writeResult: done)
            let encoded = Array("YWJjZA==".utf8)
            S.feed(terminal, S.osc("type=write"))
            S.feed(terminal, S.osc("type=wdata:mime=YXBw;\(String(decoding: encoded[..<split], as: UTF8.self))"))
            S.feed(terminal, S.osc("type=wdata:mime=YXBw;\(String(decoding: encoded[split...], as: UTF8.self))"))
            S.feed(terminal, S.osc("type=wdata"))
            let data = try #require(delegate.state.withLock {
                $0.writeRequests.first?.representations.first?.data
            })
            #expect(data == Data("abcd".utf8))
        }

        let (terminal, delegate) = S.makeTerminal(writeResult: done)
        S.feed(terminal, S.osc("type=write"))
        S.feed(terminal, S.osc("type=wdata:mime=YXBw;YQ=="))
        S.feed(terminal, S.osc("type=walias:mime=YXBw;Y29weQ=="))
        S.feed(terminal, S.osc("type=wdata:mime=YXBw;Yg=="))
        S.feed(terminal, S.osc("type=wdata"))
        #expect(delegate.state.withLock {
            $0.writeRequests.first?.representations.first?.data
        } == Data("ab".utf8))
    }

    @Test func invalidPaddingDiscardsUntilFreshWrite() {
        let done = KittyClipboardWriteResult.success(KittyClipboardWriteSuccess(remember: false))
        let (terminal, delegate) = S.makeTerminal(writeResult: done)
        S.feed(terminal, S.osc("type=write:id=bad"))
        S.feed(terminal, S.osc("type=wdata:mime=YXBw;YQ==Yg=="))
        S.feed(terminal, S.osc("type=wdata"))
        S.feed(terminal, S.osc("type=wdata:mime=YXBw;YQ=="))
        #expect(delegate.output == "\u{1b}]5522;type=write:status=EINVAL:id=bad\u{1b}\\")
        #expect(delegate.state.withLock { $0.writeRequests.isEmpty })

        S.feed(terminal, S.osc("type=write:id=good"))
        S.feed(terminal, S.osc("type=wdata:mime=YXBw;YQ=="))
        S.feed(terminal, S.osc("type=wdata"))
        #expect(delegate.output.contains("type=write:status=DONE:id=good"))
    }

    @Test func repeatedMimeAndAliasMatrix() throws {
        let done = KittyClipboardWriteResult.success(KittyClipboardWriteSuccess(remember: false))
        let (terminal, delegate) = S.makeTerminal(writeResult: done)
        S.feed(terminal, S.osc("type=write"))
        S.feed(terminal, S.osc("type=wdata:mime=YQ==;b2xk"))
        S.feed(terminal, S.osc("type=wdata:mime=Yg==;dmFsdWU="))
        S.feed(terminal, S.osc("type=wdata:mime=YQ==;bmV3"))
        S.feed(terminal, S.osc("type=walias:mime=Yg==;Y29weQ=="))
        S.feed(terminal, S.osc("type=walias:mime=Y29weQ==;Y2hhaW4="))
        S.feed(terminal, S.osc("type=walias:mime=YQ==;Yg=="))
        S.feed(terminal, S.osc("type=walias:mime=bWlzc2luZw==;aWdub3JlZA=="))
        S.feed(terminal, S.osc("type=wdata"))
        let values = Dictionary(uniqueKeysWithValues: try #require(
            delegate.state.withLock { $0.writeRequests.first?.representations }
        ).map { ($0.type, $0.data) })
        #expect(values["a"] == Data("new".utf8))
        #expect(values["b"] == Data("new".utf8))
        #expect(values["copy"] == Data("value".utf8))
        #expect(values["chain"] == Data("value".utf8))
        #expect(values["ignored"] == nil)
    }

    @Test func writeLimitExactAndOneByteOver() {
        let done = KittyClipboardWriteResult.success(KittyClipboardWriteSuccess(remember: false))
        let (terminal, delegate) = S.makeTerminal(writeResult: done)
        S.locked(terminal) { $0.kittyClipboardWriteLimitOverride = 3 }
        S.feed(terminal, S.osc("type=write:id=exact"))
        S.feed(terminal, S.osc("type=wdata:mime=YQ==;YWJj"))
        S.feed(terminal, S.osc("type=wdata"))
        #expect(delegate.output.contains("status=DONE:id=exact"))

        delegate.clearSent()
        S.feed(terminal, S.osc("type=write:id=fragmented"))
        for packet in ["YQ==", "Yg==", "Yw=="] {
            S.feed(terminal, S.osc("type=wdata:mime=YQ==;\(packet)"))
        }
        S.feed(terminal, S.osc("type=wdata"))
        #expect(delegate.output.contains("status=DONE:id=fragmented"))

        delegate.clearSent()
        S.feed(terminal, S.osc("type=write:id=large"))
        S.feed(terminal, S.osc("type=wdata:mime=YQ==;YWJjZA=="))
        #expect(delegate.output == "\u{1b}]5522;type=write:status=EFBIG:id=large\u{1b}\\")
    }

    @Test func nonemptyCommitPayloadAndMalformedWriteMetadataAbortOnce() {
        let (terminal, delegate) = S.makeTerminal()
        S.feed(terminal, S.osc("type=write:id=payload"))
        S.feed(terminal, S.osc("type=wdata;YQ=="))
        S.feed(terminal, S.osc("type=wdata"))
        #expect(delegate.output ==
            "\u{1b}]5522;type=write:status=EINVAL:id=payload\u{1b}\\")

        delegate.clearSent()
        S.feed(terminal, S.osc("type=write:id=syntax"))
        S.feed(terminal, S.osc("broken:type=wdata"))
        S.feed(terminal, S.osc("type=wdata:mime=YQ==;YQ=="))
        #expect(delegate.output ==
            "\u{1b}]5522;type=write:status=EINVAL:id=syntax\u{1b}\\")

        delegate.clearSent()
        S.feed(terminal, S.osc("type=write:id=alphabet"))
        S.feed(terminal, S.osc("type=wdata:mime=YQ==;!!!!"))
        #expect(delegate.output ==
            "\u{1b}]5522;type=write:status=EINVAL:id=alphabet\u{1b}\\")

        delegate.clearSent()
        S.feed(terminal, S.osc("type=write:id=alias"))
        S.feed(terminal, S.osc("type=walias;YQ=="))
        #expect(delegate.output ==
            "\u{1b}]5522;type=write:status=EINVAL:id=alias\u{1b}\\")
    }

    @Test func representationAndAliasLimitsIgnoreLaterValues() throws {
        let done = KittyClipboardWriteResult.success(KittyClipboardWriteSuccess(remember: false))
        let (terminal, delegate) = S.makeTerminal(writeResult: done)
        S.feed(terminal, S.osc("type=write"))
        for index in 0..<65 {
            S.feed(terminal, S.osc("type=wdata:mime=\(S.b64("type/\(index)"));"))
        }
        let aliases = (0..<65).map { "alias/\($0)" }.joined(separator: " ")
        S.feed(terminal, S.osc("type=walias:mime=\(S.b64("type/0"));\(S.b64(aliases))"))
        S.feed(terminal, S.osc("type=wdata"))
        let request = try #require(delegate.state.withLock { $0.writeRequests.first })
        #expect(request.representations.count == 128)
        #expect(!request.representations.contains { $0.type == "type/64" || $0.type == "alias/64" })
    }

    @Test func sliceBackedRepresentationDataIsServed() throws {
        var backing = Data([0xff, 0xff, 0xff, 0xff])
        backing.append(Data((0..<5000).map { UInt8($0 & 0xff) }))
        let sliced = backing.dropFirst(4)
        let success = KittyClipboardReadSuccess(
            representations: [KittyClipboardRepresentation(type: "application/octet-stream", data: sliced)],
            availableTypes: [], remember: false)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(success))
        S.feed(terminal, S.osc("type=read;\(S.b64("application/octet-stream"))"))
        let chunks = try S.packets(delegate.outputBytes)
            .filter { $0.contains("status=DATA") }
            .map { try #require(S.payload($0)) }
        #expect(chunks.count == 2)
        #expect(Data(chunks.flatMap { $0 }) == Data(sliced))
    }

    @Test func largeChunkedWriteDecodesAcrossPacketBoundaries() throws {
        let done = KittyClipboardWriteResult.success(KittyClipboardWriteSuccess(remember: false))
        let (terminal, delegate) = S.makeTerminal(writeResult: done)
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<300_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let encoded = Array(payload.base64EncodedString().utf8)
        S.feed(terminal, S.osc("type=write:id=big"))
        var offset = 0
        while offset < encoded.count {
            let end = min(offset + 4093, encoded.count)
            let fragment = String(decoding: encoded[offset..<end], as: UTF8.self)
            S.feed(terminal, S.osc("type=wdata:mime=YQ==;\(fragment)"))
            offset = end
        }
        S.feed(terminal, S.osc("type=wdata"))
        #expect(delegate.output == "\u{1b}]5522;type=write:status=DONE:id=big\u{1b}\\")
        #expect(delegate.state.withLock {
            $0.writeRequests.first?.representations.first?.data
        } == payload)

        delegate.clearSent()
        S.feed(terminal, S.osc("type=write:id=onepacket"))
        S.feed(terminal, S.osc(
            "type=wdata:mime=YQ==;\(String(decoding: encoded, as: UTF8.self))"))
        S.feed(terminal, S.osc("type=wdata"))
        #expect(delegate.output == "\u{1b}]5522;type=write:status=DONE:id=onepacket\u{1b}\\")
        #expect(delegate.state.withLock {
            $0.writeRequests.last?.representations.first?.data
        } == payload)
    }

    @Test func hostStatusMappingsAreByteExact() {
        let writeCases: [(KittyClipboardWriteResult, String)] = [
            (.success(KittyClipboardWriteSuccess(remember: false)), "DONE"),
            (.denied, "EPERM"), (.unsupported, "ENOSYS"), (.busy, "EBUSY"),
            (.invalidData, "EINVAL"), (.ioError, "EIO")
        ]
        for (result, status) in writeCases {
            let (terminal, delegate) = S.makeTerminal(writeResult: result)
            S.feed(terminal, S.osc("type=write:id=x"))
            S.feed(terminal, S.osc("type=wdata"))
            #expect(delegate.output ==
                "\u{1b}]5522;type=write:status=\(status):id=x\u{1b}\\")
        }

        let readCases: [(KittyClipboardReadResult, String)] = [
            (.denied, "EPERM"), (.unsupported, "ENOSYS"), (.busy, "EBUSY"),
            (.ioError, "EBUSY")
        ]
        for (result, status) in readCases {
            let (terminal, delegate) = S.makeTerminal(readResult: result)
            S.feed(terminal, S.osc("type=read:id=x;\(S.b64("text/plain"))"))
            #expect(delegate.output ==
                "\u{1b}]5522;type=read:status=\(status):id=x\u{1b}\\")
        }
    }
}
