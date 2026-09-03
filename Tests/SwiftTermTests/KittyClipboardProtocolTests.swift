import Foundation
import Testing
@testable import SwiftTerm

private final class ScriptedKittyClipboardDelegate: TerminalDelegate, @unchecked Sendable {
    struct State {
        var capabilities: KittyClipboardCapabilities = []
        var sent: [[UInt8]] = []
        var pasteDeliverySucceeds = true
        var available: [String]? = []
        var reads: [String: Data] = [:]
        var permission: KittyClipboardPermissionResult = .deny
        var permissionAccepted = true
        var permissionCount = 0
        var deferPermission = false
        var deferredPermission: (@Sendable (KittyClipboardPermissionResult) -> Void)?
        var writeResult: KittyClipboardWriteResult = .success
        var writeAccepted = true
        var writes: [[KittyClipboardRepresentation]] = []
        var callbackObservedTerminalLock = false
    }

    let state = Locked(State())
    private let sentSignal = DispatchSemaphore(value: 0)

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        state.withLock { $0.sent.append(Array(data)) }
        sentSignal.signal()
    }

    func kittyClipboardCapabilities(source: Terminal) -> KittyClipboardCapabilities {
        state.withLock { $0.capabilities }
    }

    func kittyClipboardSendPasteEvent(source: Terminal, data: ArraySlice<UInt8>) -> Bool {
        let succeeds = state.withLock { $0.pasteDeliverySucceeds }
        if succeeds {
            send(source: source, data: data)
        }
        return succeeds
    }

    func kittyClipboardAvailableMimeTypes(
        source: Terminal,
        location: KittyClipboardLocation,
        completion: @escaping @Sendable ([String]?) -> Void
    ) -> Bool {
        state.withLock { $0.callbackObservedTerminalLock = source.terminalLock.isLockedByCurrentThread }
        completion(state.withLock { $0.available })
        return true
    }

    func kittyClipboardRead(
        source: Terminal,
        location: KittyClipboardLocation,
        mimeType: String,
        completion: @escaping @Sendable (Data?) -> Void
    ) -> Bool {
        state.withLock { $0.callbackObservedTerminalLock = source.terminalLock.isLockedByCurrentThread }
        completion(state.withLock { $0.reads[mimeType] })
        return true
    }

    func kittyClipboardWrite(
        source: Terminal,
        location: KittyClipboardLocation,
        representations: [KittyClipboardRepresentation],
        completion: @escaping @Sendable (KittyClipboardWriteResult) -> Void
    ) -> Bool {
        let snapshot = state.withLock { state -> (Bool, KittyClipboardWriteResult) in
            state.callbackObservedTerminalLock = source.terminalLock.isLockedByCurrentThread
            state.writes.append(representations)
            return (state.writeAccepted, state.writeResult)
        }
        if snapshot.0 {
            completion(snapshot.1)
        }
        return snapshot.0
    }

    func kittyClipboardRequestPermission(
        source: Terminal,
        request: KittyClipboardPermissionRequest,
        completion: @escaping @Sendable (KittyClipboardPermissionResult) -> Void
    ) -> Bool {
        let snapshot = state.withLock { state -> (Bool, KittyClipboardPermissionResult) in
            state.callbackObservedTerminalLock = source.terminalLock.isLockedByCurrentThread
            state.permissionCount += 1
            if state.deferPermission {
                state.deferredPermission = completion
            }
            return (state.permissionAccepted, state.permission)
        }
        if snapshot.0, !state.withLock({ $0.deferPermission }) {
            completion(snapshot.1)
        }
        return snapshot.0
    }

    func clearSent() {
        state.withLock { $0.sent.removeAll() }
    }

    func output() -> [UInt8] {
        state.withLock { $0.sent.flatMap { $0 } }
    }

    func waitForSends(_ minimum: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while state.withLock({ $0.sent.count }) < minimum {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            _ = sentSignal.wait(timeout: .now() + min(remaining, 0.1))
        }
        return true
    }

    func completeDeferredPermission(_ result: KittyClipboardPermissionResult) {
        let completion = state.withLock { state in
            let value = state.deferredPermission
            state.deferredPermission = nil
            state.deferPermission = false
            return value
        }
        completion?(result)
    }
}

@Suite(.serialized)
struct KittyClipboardProtocolTests {
    private let esc = "\u{1b}"

    @Test func pasteResultTextFallbackClassification() {
        #expect(TerminalPasteResult.requiresText.needsTextFallback)
        #expect(TerminalPasteResult.deliveryFailed.needsTextFallback)
        #expect(TerminalPasteResult.entropyUnavailable.needsTextFallback)
        #expect(!TerminalPasteResult.kittyEvent(password: "password").needsTextFallback)
        #expect(!TerminalPasteResult.text.needsTextFallback)
        #expect(!TerminalPasteResult.unsafePayload.needsTextFallback)
    }

    @Test func absentCapabilityGatesQueryAndFallsBackToText() {
        let (terminal, delegate) = makeTerminal(capabilities: [])
        feed(terminal, "\(esc)[?5522h\(esc)[?5522$p")

        #expect(output(delegate).contains("\(esc)[?5522;0$y"))
        delegate.clearSent()
        let result = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.standard),
                mimeTypes: ["text/plain"],
                text: "fallback"))
        }
        #expect(result == .text)
        #expect(output(delegate) == "fallback")
    }

    @Test func mode5522SaveRestoreAndRISUseStoredBit() {
        let (terminal, _) = makeTerminal(capabilities: [])
        feed(terminal, "\(esc)[?5522h\(esc)[?5522s\(esc)[?5522l\(esc)[?5522r")
        #expect(withTerminal(terminal) { $0.kittyPasteEventsEnabled })
        feed(terminal, "\(esc)c")
        #expect(!withTerminal(terminal) { $0.kittyPasteEventsEnabled })
        feed(terminal, "\(esc)[?5522h\(esc)[?5522r")
        #expect(!withTerminal(terminal) { $0.kittyPasteEventsEnabled })
    }

    @Test func capabilityReportsStoredStateAndPasteEventShape() throws {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        feed(terminal, "\(esc)[?5522$p\(esc)[?5522h\(esc)[?5522$p")
        #expect(output(delegate) == "\(esc)[?5522;2$y\(esc)[?5522;1$y")
        delegate.clearSent()

        let mimes = (0..<18).map { "type/\($0)" }
        let result = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(source: .clipboard(.primary), mimeTypes: mimes))
        }
        guard case .kittyEvent(let password) = result else {
            Issue.record("Expected a Kitty paste event")
            return
        }
        let alphabet = Set("23456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ")
        #expect(password.count == 22)
        #expect(password.allSatisfy { alphabet.contains($0) })

        let packets = oscPackets(delegate.output())
        #expect(packets.count == 3)
        let encodedPassword = b64(password)
        #expect(packets[0] == "type=read:status=OK:loc=primary:pw=\(encodedPassword)")
        #expect(packets[1].hasPrefix("type=read:status=DATA:mime=Lg==:pw=\(encodedPassword);"))
        #expect(packets[2] == "type=read:status=DONE:pw=\(encodedPassword)")
        let listing = try #require(payload(from: packets[1]))
        #expect(String(data: listing, encoding: .utf8) == mimes.prefix(16).joined(separator: " ") + "\n")
        #expect(delegate.output().suffix(2) == [ControlCodes.ESC, UInt8(ascii: "\\")])
        #expect(delegate.state.withLock { $0.reads.isEmpty })
    }

    @Test func oneTimeGrantWorksOnceAnd5522Precedes2004() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        feed(terminal, "\(esc)[?2004;5522h")
        let event = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.standard),
                mimeTypes: ["text/plain"],
                readMimeType: { mime, completion in
                    completion(mime == "text/plain" ? Data("snapshot".utf8) : nil)
                    return true
                }))
        }
        guard case .kittyEvent(let password) = event else {
            Issue.record("Expected event")
            return
        }
        #expect(!delegate.output().containsSubsequence(EscapeSequences.bracketedPasteStart))

        delegate.state.withLock {
            $0.reads["text/plain"] = Data("value".utf8)
            $0.permission = .deny
        }
        delegate.clearSent()
        feed(terminal, readRequest(password: password, mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("status=OK"))
        #expect(output(delegate).contains(b64("snapshot")))
        #expect(delegate.state.withLock { $0.permissionCount } == 0)

        delegate.clearSent()
        feed(terminal, readRequest(password: password, mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("status=EPERM"))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)

        delegate.clearSent()
        let text = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(source: .text, text: "typed"))
        }
        #expect(text == .text)
        #expect(delegate.output() == EscapeSequences.bracketedPasteStart + Array("typed".utf8)
            + EscapeSequences.bracketedPasteEnd)
    }

    @Test func failedPasteDeliveryRevokesGrantWithoutTextFallback() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        delegate.state.withLock { $0.pasteDeliverySucceeds = false }
        feed(terminal, "\(esc)[?5522h")
        let result = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.standard),
                mimeTypes: ["text/plain"],
                text: "must-not-send"))
        }
        #expect(result == .deliveryFailed)
        #expect(delegate.output().isEmpty)
    }

    @Test func malformedMetadataAndInvalidReadsAreSilent() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read, .write])
        for body in [
            "type=read:broken;Lg==",
            "type=unknown;Lg==",
            "loc=primary;Lg==",
            "type=read;dGV4 dA==",
            "type=read;dGV4dA",
            "type=read:mime=%%%;;",
            "type=read:name=dGV4dA;",
            "type=read:pw=dGV4 dA==;",
            "type=read:mime=dGV4dA===;",
        ] {
            feed(terminal, osc(body))
        }
        #expect(delegate.output().isEmpty)
    }

    @Test func invalidAndOversizeWriteAbortWithExactStatuses() {
        let (terminal, delegate) = makeTerminal(capabilities: [.write])
        feed(terminal, osc("type=write:id=bad"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));%%%"))
        #expect(output(delegate).contains("type=write:status=EINVAL:id=bad"))

        let options = TerminalOptions(kittyClipboardWriteLimitBytes: 2)
        let limitedDelegate = ScriptedKittyClipboardDelegate()
        limitedDelegate.state.withLock { $0.capabilities = [.write] }
        let limited = Terminal(delegate: limitedDelegate, options: options)
        feed(limited, osc("type=write:id=large"))
        feed(limited, osc("type=wdata:mime=\(b64("text/plain"));\(b64("abc"))"))
        #expect(output(limitedDelegate).contains("type=write:status=EFBIG:id=large"))
        #expect(limitedDelegate.state.withLock { $0.writes.isEmpty })
    }

    @Test func writeStreamsAcrossPacketsReplacementAndEmptyCommit() {
        let (terminal, delegate) = makeTerminal(capabilities: [.write])
        delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
        feed(terminal, osc("type=wdata"))
        #expect(delegate.output().isEmpty)

        feed(terminal, osc("type=write:id=old"))
        feed(terminal, osc("type=write:id=new"))
        let mime = b64("text/plain")
        for piece in ["S", "GV", "sbG", "8="] {
            feed(terminal, osc("type=wdata:mime=\(mime);\(piece)"))
        }
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("type=write:status=DONE:id=new"))
        let writes = delegate.state.withLock { $0.writes }
        #expect(writes.count == 1)
        #expect(writes.first?.first == KittyClipboardRepresentation(
            mimeType: "text/plain",
            data: Data("Hello".utf8)))

        delegate.clearSent()
        feed(terminal, osc("type=write:id=chunks"))
        feed(terminal, osc("type=wdata:mime=\(mime);QQ=="))
        feed(terminal, osc("type=wdata:mime=\(mime);Qg=="))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.writes.last?.first?.data } == Data("AB".utf8))
    }

    @Test func multiMegabyteWriteInFourKilobyteChunks() {
        let (terminal, delegate) = makeTerminal(capabilities: [.write])
        delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
        let original = Data(repeating: 0xa5, count: 3 * 1024 * 1024 + 1)
        let encoded = [UInt8](original.base64EncodedData())
        let prefix = Array("\(esc)]5522;type=wdata:mime=\(b64("application/octet-stream"));".utf8)
        let suffix = [ControlCodes.ESC, UInt8(ascii: "\\")]

        feed(terminal, osc("type=write:id=bulk"))
        var offset = 0
        while offset < encoded.count {
            let end = min(offset + 4096, encoded.count)
            var packet = prefix
            packet.append(contentsOf: encoded[offset..<end])
            packet.append(contentsOf: suffix)
            feedBytes(terminal, packet)
            offset = end
        }
        feed(terminal, osc("type=wdata"))

        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("type=write:status=DONE:id=bulk"))
        #expect(delegate.state.withLock { $0.writes.last?.first } == KittyClipboardRepresentation(
            mimeType: "application/octet-stream",
            data: original))
    }

    @Test func aliasesResolveAtomicallyAndRISAbortsTransaction() {
        let (terminal, delegate) = makeTerminal(capabilities: [.write])
        delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
        let plain = b64("text/plain")
        feed(terminal, osc("type=write:id=alias"))
        feed(terminal, osc("type=wdata:mime=\(plain);\(b64("value"))"))
        feed(terminal, osc("type=walias:mime=\(plain);\(b64("text/x-copy"))"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        let written = delegate.state.withLock { $0.writes.first ?? [] }
        #expect(written == [
            KittyClipboardRepresentation(mimeType: "text/plain", data: Data("value".utf8)),
            KittyClipboardRepresentation(mimeType: "text/x-copy", data: Data("value".utf8)),
        ])

        delegate.clearSent()
        feed(terminal, osc("type=write:id=reset"))
        feed(terminal, osc("type=wdata:mime=\(plain);\(b64("discard"))"))
        feed(terminal, "\(esc)c")
        feed(terminal, osc("type=wdata"))
        #expect(delegate.output().isEmpty)
        #expect(delegate.state.withLock { $0.writes.count } == 1)
    }

    @Test func readsUseTargetsPacketRequestOrderAnd4096ByteChunks() throws {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        delegate.state.withLock {
            $0.permission = .allow(rememberPassword: false)
            $0.available = []
            $0.reads["application/a"] = Data(repeating: 0x41, count: 8193)
            $0.reads["application/b"] = Data()
        }
        feed(terminal, readRequest(password: "", mimes: ". application/a application/b"))
        #expect(delegate.waitForSends(1))
        let packets = oscPackets(delegate.output())
        #expect(packets[0] == "type=read:status=OK")
        #expect(packets[1] == "type=read:status=DATA:mime=Lg==")
        let dataPackets = packets.filter { $0.contains("mime=YXBwbGljYXRpb24vYQ==") }
        #expect(dataPackets.count == 3)
        #expect(try dataPackets.map { try #require(payload(from: $0)).count } == [4096, 4096, 1])
        #expect(!packets.contains { $0.contains("mime=YXBwbGljYXRpb24vYg==") })
        #expect(packets.last == "type=read:status=DONE")
    }

    @Test func idSanitizingFieldOrderAndTerminatorEchoAreExact() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        let rawID = String(repeating: "a", count: 520) + "!@"
        feed(terminal, osc("type=read:id=\(rawID);", bell: true))
        #expect(delegate.waitForSends(1))
        let id = String(repeating: "a", count: 512)
        let expected = "\(esc)]5522;type=read:status=OK:id=\(id)\u{7}"
            + "\(esc)]5522;type=read:status=DONE:id=\(id)\u{7}"
        #expect(output(delegate) == expected)

        delegate.clearSent()
        feed(terminal, osc("type=read:id=x+y.z_-/;", bell: false))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate) == "\(esc)]5522;type=read:status=OK:id=x+y.z_-\(esc)\\"
            + "\(esc)]5522;type=read:status=DONE:id=x+y.z_-\(esc)\\")
    }

    @Test func responseIntroducerUsesTerminalControlWidth() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        withTerminal(terminal) { $0.cmdSet8BitControls() }
        feed(terminal, osc("type=read;"))

        #expect(delegate.waitForSends(1))
        #expect(delegate.output().filter { $0 == 0x9d }.count == 2)
        #expect(!delegate.output().containsSubsequence([ControlCodes.ESC, UInt8(ascii: "]")]))
    }

    @Test func grantDirectionEvictionAndRISClearing() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read, .write])
        feed(terminal, "\(esc)[?5522h")
        var passwords: [String] = []
        for _ in 0..<33 {
            let result = withTerminal(terminal) {
                $0.paste(TerminalPasteRequest(
                    source: .clipboard(.standard),
                    mimeTypes: ["text/plain"]))
            }
            if case .kittyEvent(let password) = result { passwords.append(password) }
        }
        delegate.state.withLock {
            $0.permission = .deny
            $0.reads["text/plain"] = Data("ok".utf8)
        }
        delegate.clearSent()
        feed(terminal, readRequest(password: passwords[0], mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("EPERM"))

        delegate.clearSent()
        feed(terminal, readRequest(password: passwords[32], mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("status=OK"))

        let directionPassword: String
        if case .kittyEvent(let value) = withTerminal(terminal, {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.standard), mimeTypes: ["text/plain"]))
        }) {
            directionPassword = value
        } else {
            Issue.record("Expected password")
            return
        }
        delegate.clearSent()
        feed(terminal, osc("type=write:name=\(b64("app")):pw=\(b64(directionPassword)):id=w"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("EPERM"))
        let promptsAfterWrongDirection = delegate.state.withLock { $0.permissionCount }
        delegate.clearSent()
        feed(terminal, readRequest(password: directionPassword, mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == promptsAfterWrongDirection + 1)

        let resetPassword: String
        if case .kittyEvent(let value) = withTerminal(terminal, {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.standard), mimeTypes: ["text/plain"]))
        }) {
            resetPassword = value
        } else { return }
        feed(terminal, "\(esc)c")
        delegate.clearSent()
        feed(terminal, readRequest(password: resetPassword, mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("EPERM"))
    }

    @Test func persistentGrantRequiresNameAndSurvivesUse() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        delegate.state.withLock {
            $0.permission = .allow(rememberPassword: true)
            $0.reads["text/plain"] = Data("ok".utf8)
        }
        let request = readRequest(password: "secret", name: "app", mimes: "text/plain")
        feed(terminal, request)
        #expect(delegate.waitForSends(1))
        delegate.clearSent()
        feed(terminal, request)
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)

        let unnamed = readRequest(password: "unnamed", mimes: "text/plain")
        delegate.clearSent()
        feed(terminal, unnamed)
        #expect(delegate.waitForSends(1))
        delegate.clearSent()
        feed(terminal, unnamed)
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 3)
    }

    @Test func writeStatusMappingAndMissingReply() {
        let cases: [(KittyClipboardWriteResult, String)] = [
            (.success, "DONE"), (.denied, "EPERM"), (.unsupported, "ENOSYS"),
            (.busy, "EBUSY"), (.invalidData, "EINVAL"), (.ioError, "EIO"),
        ]
        for (hostResult, status) in cases {
            let (terminal, delegate) = makeTerminal(capabilities: [.write])
            delegate.state.withLock {
                $0.permission = .allow(rememberPassword: false)
                $0.writeResult = hostResult
            }
            feed(terminal, osc("type=write:id=s"))
            feed(terminal, osc("type=wdata"))
            #expect(delegate.waitForSends(1))
            #expect(output(delegate).contains("type=write:status=\(status):id=s"))
        }

        let (terminal, delegate) = makeTerminal(capabilities: [.write])
        delegate.state.withLock {
            $0.permission = .allow(rememberPassword: false)
            $0.writeAccepted = false
        }
        feed(terminal, osc("type=write:id=missing"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("status=EPERM:id=missing"))
    }

    @Test func synchronousCompletionsRunWithoutTerminalLock() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        delegate.state.withLock {
            $0.permission = .allow(rememberPassword: false)
            $0.available = ["text/plain"]
            $0.reads["text/plain"] = Data("ok".utf8)
        }
        feed(terminal, readRequest(password: "", mimes: ". text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(!delegate.state.withLock { $0.callbackObservedTerminalLock })
    }

    @Test func entropyFailureAbortsWithoutFallback() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        feed(terminal, "\(esc)[?5522h")
        withTerminal(terminal) { $0.kittyClipboardPasswordGenerator = { nil } }
        let result = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                source: .clipboard(.standard),
                mimeTypes: ["text/plain"],
                text: "must-not-fallback"))
        }
        #expect(result == .entropyUnavailable)
        #expect(delegate.output().isEmpty)
    }

    @Test func stalePermissionCallbacksCannotWriteOrRestoreGrants() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read, .write])
        delegate.state.withLock {
            $0.permission = .allow(rememberPassword: true)
            $0.deferPermission = true
        }
        feed(terminal, osc("type=write:name=\(b64("app")):pw=\(b64("secret")):id=old"))
        feed(terminal, osc("type=wdata"))
        #expect(waitUntil { delegate.state.withLock { $0.permissionCount == 1 } })
        feed(terminal, osc("type=write:id=new"))
        delegate.completeDeferredPermission(.allow(rememberPassword: true))
        Thread.sleep(forTimeInterval: 0.02)
        #expect(delegate.state.withLock { $0.writes.isEmpty })

        delegate.state.withLock {
            $0.deferPermission = true
            $0.permission = .allow(rememberPassword: true)
        }
        feed(terminal, readRequest(password: "read-secret", name: "app", mimes: "text/plain"))
        #expect(waitUntil { delegate.state.withLock { $0.permissionCount == 2 } })
        feed(terminal, "\(esc)c")
        delegate.completeDeferredPermission(.allow(rememberPassword: true))
        Thread.sleep(forTimeInterval: 0.02)

        delegate.clearSent()
        delegate.state.withLock { $0.permission = .deny }
        feed(terminal, readRequest(password: "read-secret", name: "app", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 3)
        #expect(output(delegate).contains("EPERM"))
    }

    @Test func oscAcceptsOnlyBELOrSTAndEchoesC1ST() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read])
        feedBytes(terminal, Array("\(esc)]5522;type=read;\(esc)X".utf8))
        #expect(delegate.waitForSends(1))
        #expect(delegate.output().containsSubsequence([ControlCodes.ESC, UInt8(ascii: "\\")]))

        delegate.clearSent()
        feedBytes(terminal, Array("\(esc)]5522;type=read;".utf8) + [0x9c])
        #expect(delegate.waitForSends(1))
        let bytes = delegate.output()
        #expect(bytes.filter { $0 == 0x9c }.count == 2)
        #expect(!bytes.containsSubsequence([ControlCodes.ESC, UInt8(ascii: "\\")]))
    }

    @Test func delayedCompletionAfterTerminalDestructionIsIgnored() {
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock {
            $0.capabilities = [.read]
            $0.deferPermission = true
        }
        var terminal: Terminal? = Terminal(delegate: delegate)
        weak var releasedTerminal = terminal
        feed(terminal!, readRequest(password: "secret", name: "app", mimes: "text/plain"))
        #expect(waitUntil { delegate.state.withLock { $0.permissionCount == 1 } })
        terminal = nil
        #expect(releasedTerminal == nil)
        releasedTerminal = nil
        delegate.completeDeferredPermission(.allow(rememberPassword: true))
        Thread.sleep(forTimeInterval: 0.02)
        #expect(delegate.output().isEmpty)
    }

    @Test func metadataRulesAndRepresentationLimits() {
        let (terminal, delegate) = makeTerminal(capabilities: [.read, .write])
        delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }

        feed(terminal, osc("ignored=x:type=unknown:type=read:id=bad!:id=good.;"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("type=read:status=OK:id=good."))

        delegate.clearSent()
        for field in ["mime", "name"] {
            feed(terminal, osc("type=read:\(field)=\(b64(String(repeating: "x", count: 257)));"))
        }
        feed(terminal, osc("type=read:pw=\(b64(String(repeating: "x", count: 129)));"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()).count == 2)

        delegate.clearSent()
        feed(terminal, osc("type=write:id=representations"))
        for index in 0..<65 {
            feed(terminal, osc("type=wdata:mime=\(b64("type/\(index)"));"))
        }
        #expect(output(delegate).contains("status=EFBIG:id=representations"))

        delegate.clearSent()
        feed(terminal, osc("type=write:id=aliases"))
        let aliases = (0..<65).map { "type/a\($0)" }.joined(separator: " ")
        feed(terminal, osc("type=walias:mime=\(b64("text/plain"));\(b64(aliases))"))
        #expect(output(delegate).contains("status=EFBIG:id=aliases"))
    }

    private func makeTerminal(
        capabilities: KittyClipboardCapabilities
    ) -> (Terminal, ScriptedKittyClipboardDelegate) {
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock { $0.capabilities = capabilities }
        return (Terminal(delegate: delegate), delegate)
    }

    private func feed(_ terminal: Terminal, _ text: String) {
        terminal.terminalLock.withLock { terminal.feed(text: text) }
    }

    private func feedBytes(_ terminal: Terminal, _ bytes: [UInt8]) {
        terminal.terminalLock.withLock { terminal.feed(byteArray: bytes) }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        } while Date() < deadline
        return condition()
    }

    private func withTerminal<T>(_ terminal: Terminal, _ body: (Terminal) -> T) -> T {
        terminal.terminalLock.withLock { body(terminal) }
    }

    private func output(_ delegate: ScriptedKittyClipboardDelegate) -> String {
        String(decoding: delegate.output(), as: UTF8.self)
    }

    private func osc(_ body: String, bell: Bool = false) -> String {
        "\u{1b}]5522;\(body)" + (bell ? "\u{7}" : "\u{1b}\\")
    }

    private func readRequest(
        password: String,
        name: String = "",
        mimes: String
    ) -> String {
        var metadata = "type=read"
        if !name.isEmpty { metadata += ":name=\(b64(name))" }
        if !password.isEmpty { metadata += ":pw=\(b64(password))" }
        return osc("\(metadata);\(b64(mimes))")
    }

    private func b64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private func oscPackets(_ bytes: [UInt8]) -> [String] {
        let prefix = Array("\u{1b}]5522;".utf8)
        var packets: [String] = []
        var index = 0
        while index + prefix.count <= bytes.count {
            guard bytes[index..<(index + prefix.count)].elementsEqual(prefix) else {
                index += 1
                continue
            }
            let start = index + prefix.count
            var end = start
            while end < bytes.count, bytes[end] != ControlCodes.BEL,
                  !(bytes[end] == ControlCodes.ESC && end + 1 < bytes.count
                    && bytes[end + 1] == UInt8(ascii: "\\"))
            {
                end += 1
            }
            packets.append(String(decoding: bytes[start..<end], as: UTF8.self))
            index = end + (end < bytes.count && bytes[end] == ControlCodes.BEL ? 1 : 2)
        }
        return packets
    }

    private func payload(from packet: String) -> Data? {
        guard let separator = packet.firstIndex(of: ";") else { return nil }
        return Data(base64Encoded: String(packet[packet.index(after: separator)...]))
    }
}

private extension Collection where Element == UInt8 {
    func containsSubsequence(_ subsequence: [UInt8]) -> Bool {
        guard count >= subsequence.count else { return false }
        for start in indices {
            var left = start
            var right = subsequence.startIndex
            while left != endIndex, right != subsequence.endIndex, self[left] == subsequence[right] {
                formIndex(after: &left)
                subsequence.formIndex(after: &right)
            }
            if right == subsequence.endIndex { return true }
        }
        return false
    }
}
