import Foundation
import Testing
@testable import SwiftTerm

@Suite(.serialized)
struct KittyClipboardIntegrationTests {
    typealias S = KittyClipboardTestSupport

    @Test func synchronousAndBackgroundCompletionsAreSafeAndAtMostOnce() {
        let success = KittyClipboardReadSuccess(
            representations: [], availableTypes: [], remember: false)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(success))
        S.feed(terminal, S.osc("type=read:id=sync;"))
        #expect(delegate.state.withLock { $0.callbackHadTerminalLock })
        #expect(delegate.output.contains("type=read:status=DONE:id=sync"))

        delegate.clearSent()
        delegate.state.withLock { $0.deferReads = true }
        S.feed(terminal, S.osc("type=read:id=async;"))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            delegate.completeRead(.success(success), keep: true)
            delegate.completeRead(.denied)
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(delegate.waitForSends(2))
        let packets = S.packets(delegate.outputBytes)
        #expect(packets.count == 2)
        #expect(packets.last?.contains("status=DONE:id=async") == true)

        delegate.clearSent()
        S.feed(terminal, S.osc("type=read:id=main;"))
        DispatchQueue.main.async {
            delegate.completeRead(.success(success))
        }
        #expect(delegate.waitForSends(2))
        #expect(delegate.output.contains("status=DONE:id=main"))
    }

    @Test func resetBeforeCompletionMakesItStale() {
        let (terminal, delegate) = S.makeTerminal()
        delegate.state.withLock { $0.deferReads = true }
        S.feed(terminal, S.osc("type=read:id=stale;"))
        S.feed(terminal, "\u{1b}c")
        delegate.completeRead(.success(KittyClipboardReadSuccess(
            representations: [], availableTypes: [], remember: false)))
        #expect(delegate.output.isEmpty)
    }

    @Test func busyRulesAndWriteReplacement() {
        let done = KittyClipboardWriteResult.success(KittyClipboardWriteSuccess(remember: false))
        let (terminal, delegate) = S.makeTerminal(writeResult: done)

        delegate.state.withLock { $0.deferWrites = true }
        S.feed(terminal, S.osc("type=write:id=w1"))
        S.feed(terminal, S.osc("type=wdata"))
        S.feed(terminal, S.osc("type=read:id=r1;"))
        S.feed(terminal, S.osc("type=write:id=w2"))
        #expect(delegate.output.contains("type=read:status=EBUSY:id=r1"))
        #expect(delegate.output.contains("type=write:status=EBUSY:id=w2"))
        delegate.completeWrite(done)
        #expect(delegate.output.contains("type=write:status=DONE:id=w1"))

        delegate.clearSent()
        delegate.state.withLock { $0.deferWrites = false }
        S.feed(terminal, S.osc("type=write:id=old"))
        S.feed(terminal, S.osc("type=wdata:mime=YQ==;b2xk"))
        S.feed(terminal, S.osc("type=write:id=new"))
        S.feed(terminal, S.osc("type=wdata:mime=YQ==;bmV3"))
        S.feed(terminal, S.osc("type=wdata"))
        #expect(!delegate.output.contains("id=old"))
        #expect(delegate.output.contains("status=DONE:id=new"))
        #expect(delegate.state.withLock {
            $0.writeRequests.last?.representations.first?.data
        } == Data("new".utf8))

        delegate.clearSent()
        S.feed(terminal, S.osc("type=write:id=receiving"))
        S.feed(terminal, S.osc("type=read:id=blocked;"))
        #expect(delegate.output.contains("type=read:status=EBUSY:id=blocked"))
    }

    @Test func pendingReadMakesNewWriteBusy() {
        let (terminal, delegate) = S.makeTerminal()
        delegate.state.withLock { $0.deferReads = true }
        S.feed(terminal, S.osc("type=read:id=r;"))
        S.feed(terminal, S.osc("type=write:id=w"))
        #expect(delegate.output == "\u{1b}]5522;type=write:status=EBUSY:id=w\u{1b}\\")
    }

    @Test func modeQueryResetAndPastePrecedence() throws {
        let (terminal, delegate) = S.makeTerminal()
        S.feed(terminal, "\u{1b}[?5522h\u{1b}[?5522$p")
        #expect(delegate.output == "\u{1b}[?5522;0$y")

        delegate.clearSent()
        delegate.state.withLock { $0.pasteEventsSupported = true }
        S.feed(terminal, "\u{1b}[?5522l\u{1b}[?5522$p\u{1b}[?5522h\u{1b}[?5522$p")
        #expect(delegate.output == "\u{1b}[?5522;2$y\u{1b}[?5522;1$y")

        delegate.clearSent()
        S.locked(terminal) { $0.kittyClipboardPasswordGenerator = { "0123456789abcdef" } }
        S.feed(terminal, "\u{1b}[?2004h")
        let reader: TerminalPasteRequest.Reader = { request, completion in
            completion(.success(KittyClipboardReadSuccess(
                representations: request.types.map {
                    KittyClipboardRepresentation(type: $0, data: Data("value".utf8))
                },
                availableTypes: ["text/plain", "text/html"],
                remember: false)))
        }
        let result = S.locked(terminal) {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.primary),
                types: ["text/plain", "text/html"],
                text: "fallback",
                read: reader))
        }
        #expect(result == .kittyEvent(password: "0123456789abcdef"))
        let packets = S.packets(delegate.outputBytes)
        #expect(packets.count == 3)
        #expect(packets[0].hasPrefix("type=read:status=OK:loc=primary:pw="))
        #expect(packets[1].hasPrefix("type=read:status=DATA:mime=Lg==:pw="))
        #expect(packets[2].hasPrefix("type=read:status=DONE:pw="))
        #expect(packets.allSatisfy { !$0.contains(":id=") })
        #expect(!delegate.output.contains("\u{1b}[200~"))

        delegate.clearSent()
        let fallback = S.locked(terminal) {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.clipboard), types: ["text/plain"], text: "fallback"))
        }
        #expect(fallback == .text)
        #expect(delegate.output == "\u{1b}[200~fallback\u{1b}[201~")
    }

    @Test func hardAndSoftResetClearMode() {
        let (terminal, _) = S.makeTerminal()
        S.feed(terminal, "\u{1b}[?5522h\u{1b}[!p")
        #expect(!S.locked(terminal) { $0.kittyClipboardPasteMode })
        S.feed(terminal, "\u{1b}[?5522h\u{1b}c")
        #expect(!S.locked(terminal) { $0.kittyClipboardPasteMode })
    }

    @Test func modeResetRevokesOutstandingPastePassword() throws {
        let success = KittyClipboardReadSuccess(
            representations: [], availableTypes: [], remember: false)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(success))
        delegate.state.withLock { $0.pasteEventsSupported = true }
        S.locked(terminal) { $0.kittyClipboardPasswordGenerator = { "0123456789abcdef" } }
        S.feed(terminal, "\u{1b}[?5522h")
        let reader: TerminalPasteRequest.Reader = { _, completion in
            completion(.success(success))
        }
        _ = S.locked(terminal) {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.clipboard), types: ["text/plain"], read: reader))
        }
        delegate.clearSent()
        S.feed(terminal, "\u{1b}[?5522l")
        S.feed(terminal, S.osc(
            "type=read:pw=\(S.b64("0123456789abcdef")):name=YXBw;\(S.b64("text/plain"))"))
        let request = try #require(delegate.state.withLock { $0.readRequests.last })
        #expect(request.authorization == .required)
    }

    @Test func pastePasswordListingUseConsumptionLocationAndExpiry() throws {
        let success = KittyClipboardReadSuccess(
            representations: [], availableTypes: [], remember: false)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(success))
        delegate.state.withLock { $0.pasteEventsSupported = true }
        let now = Locked(Date(timeIntervalSince1970: 1_000))
        S.locked(terminal) { terminal in
            terminal.kittyClipboardPasswordGenerator = { "0123456789abcdef" }
            terminal.kittyClipboardNow = { now.withLock { $0 } }
        }
        S.feed(terminal, "\u{1b}[?5522h")
        let reader: TerminalPasteRequest.Reader = { request, completion in
            completion(.success(KittyClipboardReadSuccess(
                representations: request.types.map {
                    KittyClipboardRepresentation(type: $0, data: Data("paste".utf8))
                },
                availableTypes: ["text/plain"], remember: false)))
        }
        _ = S.locked(terminal) {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.clipboard), types: ["text/plain"], read: reader))
        }
        delegate.clearSent()
        let password = S.b64("0123456789abcdef")

        S.feed(terminal, S.osc("type=read:pw=\(password):name=UGFzdGUgZXZlbnQ=;Lg=="))
        #expect(delegate.state.withLock { $0.readRequests.isEmpty })
        #expect(delegate.output.contains("status=DATA:mime=Lg=="))

        delegate.clearSent()
        S.feed(terminal, S.osc(
            "type=read:pw=\(password):name=UGFzdGUgZXZlbnQ=;\(S.b64("text/plain"))"))
        #expect(delegate.output.contains("cGFzdGU="))

        delegate.clearSent()
        S.feed(terminal, S.osc(
            "type=read:pw=\(password):name=UGFzdGUgZXZlbnQ=;\(S.b64("text/plain"))"))
        let second = try #require(delegate.state.withLock { $0.readRequests.last })
        #expect(second.authorization == .required)

        _ = S.locked(terminal) {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.clipboard), types: ["text/plain"], read: reader))
        }
        delegate.clearSent()
        S.feed(terminal, S.osc(
            "type=read:loc=primary:pw=\(password):name=YXBw;\(S.b64("text/plain"))"))
        #expect(delegate.state.withLock { $0.readRequests.last?.authorization } == .required)

        now.withLock { $0 = $0.addingTimeInterval(31) }
        S.feed(terminal, S.osc(
            "type=read:pw=\(password):name=YXBw;\(S.b64("text/plain"))"))
        #expect(delegate.state.withLock { $0.readRequests.last?.authorization } == .required)
    }

    @Test func rememberedGrantsAreDirectionAndLocationScopedAndReset() throws {
        let remembered = KittyClipboardReadSuccess(
            representations: [], availableTypes: [], remember: true)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(remembered))
        let password = S.b64("session-secret")
        let request = { (location: String) in
            S.osc("type=read\(location):pw=\(password):name=YXBw;\(S.b64("text/plain"))")
        }
        S.feed(terminal, request(""))
        S.feed(terminal, request(""))
        S.feed(terminal, request(":loc=primary"))
        let authorizations = delegate.state.withLock { $0.readRequests.map(\.authorization) }
        #expect(authorizations == [.required, .granted, .required])

        delegate.state.withLock {
            $0.writeResult = .success(KittyClipboardWriteSuccess(remember: false))
        }
        S.feed(terminal, S.osc("type=write:pw=\(password):name=YXBw"))
        S.feed(terminal, S.osc("type=wdata"))
        let write = try #require(delegate.state.withLock { $0.writeRequests.last })
        #expect(write.authorization == .required)

        S.feed(terminal, "\u{1b}c")
        S.feed(terminal, request(""))
        #expect(delegate.state.withLock { $0.readRequests.last?.authorization } == .required)
    }

    @Test func passwordWithoutNameCannotGrant() throws {
        let remembered = KittyClipboardReadSuccess(
            representations: [], availableTypes: [], remember: true)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(remembered))
        let password = S.b64("secret")
        S.feed(terminal, S.osc("type=read:pw=\(password);\(S.b64("text/plain"))"))
        S.feed(terminal, S.osc("type=read:pw=\(password);\(S.b64("text/plain"))"))
        let requests = delegate.state.withLock { $0.readRequests }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.authorization == .required && !$0.canRemember })
    }

    @Test func grantStoreEvictsOldestAndSoftResetKeepsSessionGrant() throws {
        let remembered = KittyClipboardReadSuccess(
            representations: [], availableTypes: [], remember: true)
        let (terminal, delegate) = S.makeTerminal(readResult: .success(remembered))
        for index in 0..<33 {
            S.feed(terminal, S.osc(
                "type=read:pw=\(S.b64("password-\(index)")):name=YXBw;\(S.b64("text/plain"))"))
        }
        S.feed(terminal, S.osc(
            "type=read:pw=\(S.b64("password-0")):name=YXBw;\(S.b64("text/plain"))"))
        #expect(delegate.state.withLock { $0.readRequests.last?.authorization } == .required)
        S.feed(terminal, S.osc(
            "type=read:pw=\(S.b64("password-32")):name=YXBw;\(S.b64("text/plain"))"))
        #expect(delegate.state.withLock { $0.readRequests.last?.authorization } == .granted)

        S.feed(terminal, "\u{1b}[!p")
        S.feed(terminal, S.osc(
            "type=read:pw=\(S.b64("password-32")):name=YXBw;\(S.b64("text/plain"))"))
        let request = try #require(delegate.state.withLock { $0.readRequests.last })
        #expect(request.authorization == .granted)
    }
}
