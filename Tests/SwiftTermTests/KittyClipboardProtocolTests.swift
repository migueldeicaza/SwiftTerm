import Foundation
import Testing
@testable import SwiftTerm

private let esc = "\u{1b}"

private final class ScriptedKittyClipboardDelegate: TerminalDelegate, @unchecked Sendable {
    struct State {
        var capabilities: KittyClipboardCapabilities = []
        var sent: [[UInt8]] = []
        var pasteDeliverySucceeds = true
        var available: [String]? = []
        var reads: [String: KittyClipboardReadResult] = [:]
        var readAccepted = true
        var permission: KittyClipboardPermissionResult = .deny
        var permissionAccepted = true
        var permissionCount = 0
        var permissionRequests: [KittyClipboardPermissionRequest] = []
        var deferPermission = false
        var deferredPermission: (@Sendable (KittyClipboardPermissionResult) -> Void)?
        var writeResult: KittyClipboardWriteResult = .success
        var writeAccepted = true
        var writes: [KittyClipboardWriteContent] = []
        var callbackObservedTerminalLock = false
        var pasteEvents: [[UInt8]] = []
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
        let succeeds = state.withLock { state -> Bool in
            if state.pasteDeliverySucceeds {
                state.pasteEvents.append(Array(data))
            }
            return state.pasteDeliverySucceeds
        }
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
        state.withLock {
            $0.callbackObservedTerminalLock =
                $0.callbackObservedTerminalLock || source.terminalLock.isLockedByCurrentThread
        }
        completion(state.withLock { $0.available })
        return true
    }

    func kittyClipboardRead(
        source: Terminal,
        location: KittyClipboardLocation,
        mimeType: String,
        completion: @escaping @Sendable (KittyClipboardReadResult) -> Void
    ) -> Bool {
        let snapshot = state.withLock { state -> (Bool, KittyClipboardReadResult) in
            state.callbackObservedTerminalLock =
                state.callbackObservedTerminalLock || source.terminalLock.isLockedByCurrentThread
            return (state.readAccepted, state.reads[mimeType] ?? .unavailable)
        }
        guard snapshot.0 else { return false }
        completion(snapshot.1)
        return true
    }

    func kittyClipboardWrite(
        source: Terminal,
        location: KittyClipboardLocation,
        content: KittyClipboardWriteContent,
        completion: @escaping @Sendable (KittyClipboardWriteResult) -> Void
    ) -> Bool {
        let snapshot = state.withLock { state -> (Bool, KittyClipboardWriteResult) in
            state.callbackObservedTerminalLock =
                state.callbackObservedTerminalLock || source.terminalLock.isLockedByCurrentThread
            state.writes.append(content)
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
            state.callbackObservedTerminalLock =
                state.callbackObservedTerminalLock || source.terminalLock.isLockedByCurrentThread
            state.permissionCount += 1
            state.permissionRequests.append(request)
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

/// A scripted clipboard snapshot with a mutable change counter.
private final class ScriptedSnapshotSource: @unchecked Sendable {
    struct State {
        var identity: UInt64 = 1
        var data: [String: KittyClipboardReadResult] = [:]
        var accepts = true
        var reads: [String] = []
    }

    let state = Locked(State())

    init(data: [String: KittyClipboardReadResult] = [:]) {
        state.withLock { $0.data = data }
    }

    func snapshot(
        location: KittyClipboardLocation = .standard,
        mimeTypes: [String],
        expiresAfter: TimeInterval? = nil
    ) -> TerminalClipboardSnapshot {
        let identity = state.withLock { $0.identity }
        return TerminalClipboardSnapshot(
            location: location,
            mimeTypes: mimeTypes,
            identity: identity,
            expiresAfter: expiresAfter
        ) { [self] mimeType, completion in
            let snapshot = state.withLock { state -> (Bool, KittyClipboardReadResult) in
                state.reads.append(mimeType)
                if state.identity != identity {
                    return (state.accepts, .unavailable)
                }
                return (state.accepts, state.data[mimeType] ?? .unavailable)
            }
            guard snapshot.0 else { return false }
            completion(snapshot.1)
            return true
        }
    }

    /// Models the user replacing the clipboard.
    func replaceClipboard() {
        state.withLock { $0.identity += 1 }
    }
}

@Suite(.serialized)
struct KittyClipboardProtocolTests {

    // MARK: - 16.1 Detection and mode state

    @Test func decrqmReportsResetSetAndUnsupportedStates() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522$p\(esc)[?5522h\(esc)[?5522$p")
        #expect(output(delegate) == "\(esc)[?5522;2$y\(esc)[?5522;1$y")

        for partial: KittyClipboardCapabilities in [[], .standardRead, .standardWrite] {
            let (partialTerminal, partialDelegate) = makeTerminal(capabilities: partial)
            feed(partialTerminal, "\(esc)[?5522$p")
            #expect(output(partialDelegate) == "\(esc)[?5522;0$y")
        }
    }

    @Test func decrqmReportsUnsupportedWithoutTerminalPolicy() {
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock { $0.capabilities = .all }
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 25))
        feed(terminal, "\(esc)[?5522$p")
        #expect(output(delegate) == "\(esc)[?5522;0$y")
    }

    @Test func mode5522SaveRestoreAndRISUseStoredBit() {
        let (terminal, _) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h\(esc)[?5522s\(esc)[?5522l\(esc)[?5522r")
        #expect(withTerminal(terminal) { $0.kittyPasteEventsEnabled })
        feed(terminal, "\(esc)c")
        #expect(!withTerminal(terminal) { $0.kittyPasteEventsEnabled })

        // XTRESTORE with no earlier XTSAVE is a no-op.
        feed(terminal, "\(esc)[?5522h\(esc)[?5522r")
        #expect(!withTerminal(terminal) { $0.kittyPasteEventsEnabled })
    }

    @Test func losingHostSupportResetsModeAndProtocolState() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        feed(terminal, osc("type=write:id=live"))
        delegate.clearSent()

        delegate.state.withLock { $0.capabilities = [.standardRead] }
        withTerminal(terminal) { $0.refreshKittyClipboardCapabilities() }

        #expect(!withTerminal(terminal) { $0.kittyPasteEventsEnabled })
        #expect(output(delegate).contains("type=write:status=ENOSYS:id=live"))
        feed(terminal, "\(esc)[?5522$p")
        #expect(output(delegate).contains("\(esc)[?5522;0$y"))
    }

    // MARK: - 16.2 Paste events

    @Test func pasteEventMatchesTheThreePacketGoldenFormat() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        let source = ScriptedSnapshotSource()
        let result = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain", "text/html"])))
        }
        #expect(result == .eventSent)

        let packets = oscPackets(delegate.output())
        #expect(packets.count == 3)
        guard packets.count == 3 else { return }
        let token = passwordField(packets[0])
        #expect(token != nil)
        #expect(packets[0] == "type=read:status=OK:pw=\(b64(token ?? ""))")
        #expect(packets[1] == "type=read:status=DATA:mime=Lg==;\(b64("text/plain text/html\n"))")
        #expect(packets[2] == "type=read:status=DONE")
        // Every generated packet uses the canonical 7-bit introducer and ST.
        #expect(!delegate.output().contains(ControlCodes.BEL))
        #expect(!delegate.output().contains(0x9c))
    }

    @Test func primaryPasteEventCarriesLocationOnlyOnTheOKPacket() {
        let (terminal, delegate) = makeTerminal(capabilities: .all)
        feed(terminal, "\(esc)[?5522h")
        let source = ScriptedSnapshotSource()
        _ = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(location: .primary, mimeTypes: ["text/plain"])))
        }
        let packets = oscPackets(delegate.output())
        #expect(packets.count == 3)
        #expect(packets.first?.contains(":loc=primary") == true)
        #expect(packets.dropFirst().allSatisfy { !$0.contains("loc=") })
    }

    @Test func pasteEventListsEveryTypeWithoutTruncation() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        let mimes = (0..<40).map { "text/x-type\($0)" }
        let source = ScriptedSnapshotSource()
        _ = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: mimes)))
        }
        let packets = oscPackets(delegate.output())
        #expect(packets.count == 3)
        let payload = packets.count == 3 ? decodedPayload(packets[1]) : ""
        #expect(payload == mimes.joined(separator: " ") + "\n")
    }

    @Test func emptyMimeListStillSendsOneEmptyDataPayload() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        let source = ScriptedSnapshotSource()
        _ = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: [])))
        }
        let packets = oscPackets(delegate.output())
        #expect(packets.count == 3)
        #expect(packets.count == 3 && packets[1].hasSuffix("mime=Lg==;"))
    }

    @Test func mode5522TakesPrecedenceOverMode2004() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?2004;5522h")
        let source = ScriptedSnapshotSource()
        let result = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"]),
                text: "plain"))
        }
        #expect(result == .eventSent)
        let bytes = delegate.output()
        #expect(!bytes.starts(with: EscapeSequences.bracketedPasteStart))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("plain"))
    }

    @Test func textAndIMEInsertionNeverCreateAPasteEvent() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        let result = withTerminal(terminal) { $0.paste(TerminalPasteRequest(text: "typed")) }
        #expect(result == .textSent)
        #expect(output(delegate) == "typed")
        #expect(delegate.state.withLock { $0.pasteEvents.isEmpty })
    }

    @Test func entropyFailureStillSendsAnEventWithoutAPassword() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        withTerminal(terminal) { $0.kittyClipboardTokenGenerator = { nil } }
        let source = ScriptedSnapshotSource(data: ["text/plain": .data(Data("value".utf8))])
        let result = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"])))
        }
        #expect(result == .eventSent)
        let packets = oscPackets(delegate.output())
        #expect(packets.count == 3)
        #expect(packets.allSatisfy { !$0.contains("pw=") })

        // No snapshot is retained, so a later read follows normal permission.
        delegate.clearSent()
        delegate.state.withLock {
            $0.available = ["text/plain"]
            $0.reads = ["text/plain": .data(Data("host".utf8))]
            $0.permission = .allow(rememberPassword: false)
        }
        feed(terminal, readRequest(password: "", name: "Paste event", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)
    }

    @Test func aRejectedEventBatchFallsBackToTextAndAnAcceptedOneDoesNot() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        delegate.state.withLock { $0.pasteDeliverySucceeds = false }
        let source = ScriptedSnapshotSource()
        let rejected = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"]),
                text: "fallback"))
        }
        #expect(rejected == .textSent)
        #expect(output(delegate) == "fallback")

        delegate.clearSent()
        delegate.state.withLock { $0.pasteDeliverySucceeds = true }
        let accepted = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"]),
                text: "fallback"))
        }
        #expect(accepted == .eventSent)
        #expect(!output(delegate).contains("fallback"))
    }

    @Test func aClipboardPasteWithoutSupportOrTextReportsFailure() {
        let (terminal, _) = makeTerminal(capabilities: [.standardRead])
        feed(terminal, "\(esc)[?5522h")
        let source = ScriptedSnapshotSource()
        let result = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"])))
        }
        #expect(result == .failed)
        #expect(result.needsTextFallback)
    }

    @Test func aPrimaryPasteWithoutPrimaryReadServiceFallsBackToText() {
        // The host serves the standard clipboard only. A `loc=primary` event
        // would hand out a token whose follow-up read answers ENOSYS, so no
        // event is started and the text path runs.
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        #expect(withTerminal(terminal) { $0.kittyPasteEventPossible(location: .standard) })
        #expect(!withTerminal(terminal) { $0.kittyPasteEventPossible(location: .primary) })

        let source = ScriptedSnapshotSource(data: ["text/plain": .data(Data("v".utf8))])
        let result = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(location: .primary, mimeTypes: ["text/plain"]),
                text: "primary text"))
        }
        #expect(result == .textSent)
        #expect(output(delegate) == "primary text")
        #expect(delegate.state.withLock { $0.pasteEvents.isEmpty })
    }

    @Test func pasteEventsNeedTheTerminalPolicyEvenWhenTheModeIsSet() {
        // DECSET stores the bit without consulting support, so the paste
        // predicate must apply the policy itself.
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock { $0.capabilities = .all }
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(kittyClipboardPolicy: []))
        feed(terminal, "\(esc)[?5522h")
        #expect(withTerminal(terminal) { $0.kittyPasteEventsEnabled })
        #expect(!withTerminal(terminal) { $0.kittyPasteEventPossible(location: .standard) })
    }

    // MARK: - 16.3 Token and permissions

    @Test func aPasteTokenAuthorizesExactlyOneReadWithoutAPrompt() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        let source = ScriptedSnapshotSource(data: ["text/plain": .data(Data("snapshot".utf8))])
        _ = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"])))
        }
        let token = passwordField(oscPackets(delegate.output())[0]) ?? ""
        #expect(!token.isEmpty)

        delegate.clearSent()
        feed(terminal, readRequest(password: token, name: "Paste event", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 0)
        #expect(output(delegate).contains(b64("snapshot")))

        // The second use is a normal, unauthorized request.
        delegate.clearSent()
        delegate.state.withLock { $0.available = ["text/plain"] }
        feed(terminal, readRequest(password: token, name: "Paste event", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)
        #expect(output(delegate).contains("EPERM"))
    }

    @Test func aTokenIsNotUsedWithoutANameOrForAnotherDirectionOrLocation() {
        let (terminal, delegate) = makeTerminal(capabilities: .all)
        feed(terminal, "\(esc)[?5522h")
        delegate.state.withLock { $0.available = ["text/plain"] }
        let source = ScriptedSnapshotSource(data: ["text/plain": .data(Data("snapshot".utf8))])
        _ = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"])))
        }
        let token = passwordField(oscPackets(delegate.output())[0]) ?? ""

        // No name.
        delegate.clearSent()
        feed(terminal, readRequest(password: token, mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)

        // Another location.
        delegate.clearSent()
        feed(terminal, readRequest(
            password: token, name: "Paste event", mimes: "text/plain", location: "primary"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 2)

        // The write direction.
        delegate.clearSent()
        feed(terminal, osc("type=write:name=\(b64("Paste event")):pw=\(b64(token))"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("x"))"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 3)

        // The token survived all three, so it still works once.
        delegate.clearSent()
        feed(terminal, readRequest(password: token, name: "Paste event", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 3)
        #expect(output(delegate).contains(b64("snapshot")))
    }

    @Test func aPasteTokenExpiresAfterThirtySeconds() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        let clock = Locked<UInt64>(1_000)
        withTerminal(terminal) { $0.kittyClipboardClock = { clock.withLock { $0 } } }
        let source = ScriptedSnapshotSource(data: ["text/plain": .data(Data("snapshot".utf8))])
        _ = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"])))
        }
        let token = passwordField(oscPackets(delegate.output())[0]) ?? ""

        clock.withLock { $0 = 1_000 + 30 * 1_000_000_000 }
        delegate.clearSent()
        delegate.state.withLock { $0.available = ["text/plain"] }
        feed(terminal, readRequest(password: token, name: "Paste event", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)
    }

    @Test func replacingTheClipboardInvalidatesTheSnapshot() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        let source = ScriptedSnapshotSource(data: ["text/plain": .data(Data("snapshot".utf8))])
        _ = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"])))
        }
        let token = passwordField(oscPackets(delegate.output())[0]) ?? ""
        source.replaceClipboard()

        delegate.clearSent()
        feed(terminal, readRequest(password: token, name: "Paste event", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("type=read:status=ENOSYS"))
    }

    @Test func risRevokesEveryTokenAndPersistentGrant() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        delegate.state.withLock {
            $0.available = ["text/plain"]
            $0.reads = ["text/plain": .data(Data("host".utf8))]
            $0.permission = .allow(rememberPassword: true)
        }
        let source = ScriptedSnapshotSource(data: ["text/plain": .data(Data("snapshot".utf8))])
        _ = withTerminal(terminal) {
            $0.paste(TerminalPasteRequest(
                snapshot: source.snapshot(mimeTypes: ["text/plain"])))
        }
        let token = passwordField(oscPackets(delegate.output())[0]) ?? ""
        feed(terminal, readRequest(password: "remembered", name: "app", mimes: "text/plain"))
        #expect(delegate.waitForSends(2))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)

        feed(terminal, "\(esc)c")
        feed(terminal, "\(esc)[?5522h")

        delegate.clearSent()
        feed(terminal, readRequest(password: "remembered", name: "app", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 2)

        delegate.clearSent()
        feed(terminal, readRequest(password: token, name: "Paste event", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 3)
    }

    @Test func persistentGrantsAreSeparateByDirectionAndLocation() {
        let (terminal, delegate) = makeTerminal(capabilities: .all)
        delegate.state.withLock {
            $0.available = ["text/plain"]
            $0.reads = ["text/plain": .data(Data("host".utf8))]
            $0.permission = .allow(rememberPassword: true)
        }
        feed(terminal, readRequest(password: "secret", name: "app", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)

        // The same password, direction, and location skips the prompt.
        feed(terminal, readRequest(password: "secret", name: "app", mimes: "text/plain"))
        #expect(delegate.waitForSends(2))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)

        // Another location still prompts.
        feed(terminal, readRequest(
            password: "secret", name: "app", mimes: "text/plain", location: "primary"))
        #expect(delegate.waitForSends(3))
        #expect(delegate.state.withLock { $0.permissionCount } == 2)

        // The write direction still prompts.
        feed(terminal, osc("type=write:name=\(b64("app")):pw=\(b64("secret"))"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("x"))"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(4))
        #expect(delegate.state.withLock { $0.permissionCount } == 3)
    }

    // MARK: - 16.4 Read protocol

    @Test func typeListRequestReturnsEveryTypeWithoutAPrompt() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        let mimes = (0..<20).map { "text/x-type\($0)" }
        delegate.state.withLock { $0.available = mimes }
        feed(terminal, osc("type=read;\(b64("."))"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 0)

        let packets = oscPackets(delegate.output())
        #expect(packets == [
            "type=read:status=OK",
            "type=read:status=DATA:mime=Lg==;\(b64(mimes.joined(separator: " ") + "\n"))",
            "type=read:status=DONE",
        ])
    }

    @Test func invalidReadRequestsAreSilent() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock { $0.available = ["text/plain"] }
        let invalid = [
            osc("type=read;\(b64(". text/plain"))"),   // `.` with another name
            osc("type=read;\(b64("text/plain ."))"),
            osc("type=read;"),                          // empty payload
            osc("type=read"),                           // no payload separator
            osc("type=read;not+base64!"),               // malformed base64
            osc("type=read;\(b64("   "))"),             // empty request list
            osc("type=read;\(b64("no-slash"))"),        // invalid MIME name
            osc("type=read:loc=other;\(b64("."))"),     // unknown location
            osc("noequals;\(b64("."))"),                // record without `=`
        ]
        for packet in invalid {
            feed(terminal, packet)
        }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(delegate.output().isEmpty)
    }

    @Test func aMultiTypeReadReturnsEveryAvailableTypeInOrder() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock {
            $0.available = ["text/plain", "text/html", "image/png"]
            $0.reads = [
                "text/plain": .data(Data("one".utf8)),
                "image/png": .data(Data()),
            ]
            $0.permission = .allow(rememberPassword: false)
        }
        // `TEXT/PLAIN` matches without case differences and echoes the
        // canonical name. `text/x-missing` is unavailable and is skipped.
        feed(terminal, osc("type=read:id=r1;\(b64("TEXT/PLAIN text/x-missing image/png text/plain"))"))
        #expect(delegate.waitForSends(1))

        #expect(oscPackets(delegate.output()) == [
            "type=read:status=OK:id=r1",
            "type=read:status=DATA:id=r1:mime=\(b64("text/plain"));\(b64("one"))",
            "type=read:status=DATA:id=r1:mime=\(b64("image/png"));",
            "type=read:status=DONE:id=r1",
        ])
    }

    @Test func noAvailableRequestedTypeReturnsENOSYS() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock {
            $0.available = ["text/html"]
            $0.permission = .allow(rememberPassword: false)
        }
        feed(terminal, osc("type=read;\(b64("text/plain"))"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=read:status=ENOSYS"])
        #expect(delegate.state.withLock { $0.permissionCount } == 0)
    }

    @Test func readErrorsMapToTheStatusTable() {
        let cases: [(KittyClipboardReadResult, String)] = [
            (.denied, "EPERM"),
            (.busy, "EBUSY"),
        ]
        for (result, status) in cases {
            let (terminal, delegate) = makeTerminal(capabilities: .standard)
            delegate.state.withLock {
                $0.available = ["text/plain"]
                $0.reads = ["text/plain": result]
                $0.permission = .allow(rememberPassword: false)
            }
            feed(terminal, osc("type=read;\(b64("text/plain"))"))
            #expect(delegate.waitForSends(1))
            #expect(oscPackets(delegate.output()) == ["type=read:status=\(status)"])
        }

        // An unavailable location, and a host that refuses the work.
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, osc("type=read:loc=primary;\(b64("."))"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=read:status=ENOSYS"])

        delegate.clearSent()
        delegate.state.withLock {
            $0.available = ["text/plain"]
            $0.readAccepted = false
            $0.permission = .allow(rememberPassword: false)
        }
        feed(terminal, osc("type=read;\(b64("text/plain"))"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=read:status=ENOSYS"])
    }

    @Test func dataChunksAreAtMost4096DecodedBytesAndPadIndependently() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        delegate.state.withLock {
            $0.available = ["application/octet-stream"]
            $0.reads = ["application/octet-stream": .data(payload)]
            $0.permission = .allow(rememberPassword: false)
        }
        feed(terminal, osc("type=read;\(b64("application/octet-stream"))"))
        #expect(delegate.waitForSends(1))

        let packets = oscPackets(delegate.output())
        #expect(packets.count == 5)
        var rebuilt = Data()
        for packet in packets.dropFirst().dropLast() {
            guard let separator = packet.firstIndex(of: ";") else {
                Issue.record("A DATA packet has no payload separator")
                continue
            }
            let encoded = String(packet[packet.index(after: separator)...])
            guard let chunk = Data(base64Encoded: encoded, options: []) else {
                Issue.record("A DATA payload is not independently padded base64")
                continue
            }
            #expect(chunk.count <= 4096)
            rebuilt.append(chunk)
        }
        #expect(rebuilt == payload)
    }

    @Test func aSanitizedIDIsEchoedAndCappedAt512Bytes() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock { $0.available = [] }
        feed(terminal, osc("type=read:id=x+y.z_-!;\(b64("."))"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == [
            "type=read:status=OK:id=x+y.z_-",
            "type=read:status=DATA:id=x+y.z_-:mime=Lg==;",
            "type=read:status=DONE:id=x+y.z_-",
        ])

        // The id is repeated in every packet, so it is bounded: the first 512
        // sanitized bytes are kept. Unsafe bytes do not count toward the cap.
        delegate.clearSent()
        let kept = String(repeating: "a", count: 512)
        feed(terminal, osc("type=read:id=\(String(repeating: "!a", count: 700));\(b64("."))"))
        #expect(delegate.waitForSends(1))
        let packets = oscPackets(delegate.output())
        #expect(packets.count == 3)
        #expect(packets.allSatisfy { $0.contains(":id=\(kept)") && !$0.contains("a" + kept) })
    }

    @Test func metadataTextFieldsAreBoundedAt4096DecodedBytes() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock {
            $0.available = ["text/plain"]
            $0.permission = .allow(rememberPassword: false)
        }
        // A 4096-byte name or password is accepted and reaches the prompt.
        let name = String(repeating: "n", count: 4096)
        let password = String(repeating: "p", count: 4096)
        feed(terminal, readRequest(password: password, name: name, mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionRequests.first?.name } == name)

        // One byte more is an invalid value: a read is silent, a write echoes
        // its id with EINVAL.
        delegate.clearSent()
        for field in ["name", "pw", "mime"] {
            let value = b64(String(repeating: "x", count: 4097))
            feed(terminal, osc("type=read:id=r:\(field)=\(value);\(b64("text/plain"))"))
        }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(delegate.output().isEmpty)
        feed(terminal, osc("type=write:id=w:name=\(b64(String(repeating: "x", count: 4097)))"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=EINVAL:id=w"])
    }

    @Test func nameListsAreBoundedBeforeTheyAreDecoded() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock {
            $0.available = ["text/plain"]
            $0.permission = .allow(rememberPassword: false)
        }
        // A read list past 64 KiB is invalid and silent, even though every
        // word in it would be a valid name.
        let huge = Array(repeating: "text/plain", count: 8_000).joined(separator: " ")
        #expect(huge.utf8.count > 64 * 1024)
        feed(terminal, osc("type=read;\(b64(huge))"))
        Thread.sleep(forTimeInterval: 0.05)
        #expect(delegate.output().isEmpty)

        // The same list as an alias payload answers EFBIG.
        feed(terminal, osc("type=write:id=a"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("x"))"))
        feed(terminal, osc("type=walias:mime=\(b64("text/plain"));\(b64(huge))"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=EFBIG:id=a"])
    }

    // MARK: - 16.5 Write protocol

    @Test func aMultiTypeWriteCommitsAtomicallyAndReturnsDONE() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
        feed(terminal, osc("type=write:id=w1"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("hello"))"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/html"));\(b64("<b>hi</b>"))"))
        feed(terminal, osc("type=walias:mime=\(b64("text/plain"));\(b64("text/x-copy"))"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))

        #expect(oscPackets(delegate.output()) == ["type=write:status=DONE:id=w1"])
        let content = delegate.state.withLock { $0.writes }
        #expect(content.count == 1)
        #expect(content.first?.representations == [
            KittyClipboardRepresentation(mimeType: "text/plain", data: Data("hello".utf8)),
            KittyClipboardRepresentation(mimeType: "text/html", data: Data("<b>hi</b>".utf8)),
        ])
        // The alias relation reaches the host; the data is not duplicated.
        #expect(content.first?.aliases == [
            KittyClipboardAlias(name: "text/x-copy", target: "text/plain")
        ])
        #expect(content.first?.flattened.count == 3)
    }

    @Test func base64FragmentsCanSplitAtEveryQuartetPosition() {
        for split in 0...8 {
            let (terminal, delegate) = makeTerminal(capabilities: .standard)
            delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
            let payload = Data("abcdef".utf8)
            let encoded = Array(payload.base64EncodedString().utf8)
            let head = String(decoding: encoded[..<min(split, encoded.count)], as: UTF8.self)
            let tail = String(decoding: encoded[min(split, encoded.count)...], as: UTF8.self)

            feed(terminal, osc("type=write"))
            feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(head)"))
            feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(tail)"))
            feed(terminal, osc("type=wdata"))
            #expect(delegate.waitForSends(1))
            #expect(oscPackets(delegate.output()) == ["type=write:status=DONE"])
            #expect(delegate.state.withLock { $0.writes.first?.representations.first?.data }
                == payload)
        }
    }

    @Test func writeTransactionErrorsReturnEINVAL() {
        let invalidSequences: [[String]] = [
            // Data after final padding.
            ["type=write", "type=wdata:mime=\(b64("text/plain"));\(b64("ab"))",
             "type=wdata:mime=\(b64("text/plain"));\(b64("cd"))", "type=wdata"],
            // A MIME type that reappears after another one started.
            ["type=write", "type=wdata:mime=\(b64("text/plain"));\(b64("a"))",
             "type=wdata:mime=\(b64("text/html"));\(b64("b"))",
             "type=wdata:mime=\(b64("text/plain"));\(b64("c"))"],
            // Invalid base64 in a data packet.
            ["type=write", "type=wdata:mime=\(b64("text/plain"));a b=="],
            // An invalid MIME name.
            ["type=write", "type=wdata:mime=\(b64("not a mime"));\(b64("a"))"],
            // An incomplete quartet at commit time.
            ["type=write", "type=wdata:mime=\(b64("text/plain"));QQ", "type=wdata"],
            // An invalid alias list.
            ["type=write", "type=wdata:mime=\(b64("text/plain"));\(b64("a"))",
             "type=walias:mime=\(b64("text/plain"));\(b64("not a mime"))"],
            // An alias packet with no payload separator.
            ["type=write", "type=walias:mime=\(b64("text/plain"))"],
            // A data packet with a MIME name but no payload separator.
            ["type=write", "type=wdata:mime=\(b64("text/plain"))"],
            // A commit packet that carries a payload separator.
            ["type=write", "type=wdata;"],
            // Malformed metadata in an active transaction.
            ["type=write", "type=wdata:mime=zz z"],
        ]
        for sequence in invalidSequences {
            let (terminal, delegate) = makeTerminal(capabilities: .standard)
            delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
            for packet in sequence {
                feed(terminal, osc(packet))
            }
            #expect(delegate.waitForSends(1))
            #expect(oscPackets(delegate.output()) == ["type=write:status=EINVAL"])
            #expect(delegate.state.withLock { $0.writes.isEmpty })
        }
    }

    @Test func anInvalidInitialWriteReturnsEINVAL() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, osc("type=write:id=a;"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=EINVAL:id=a"])

        delegate.clearSent()
        feed(terminal, osc("type=write:id=b:mime=\(b64("text/plain"))"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=EINVAL:id=b"])
    }

    @Test func aWriteWithoutHostServiceReturnsENOSYS() {
        let (terminal, delegate) = makeTerminal(capabilities: [.standardRead])
        feed(terminal, osc("type=write:id=w"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=ENOSYS:id=w"])

        delegate.clearSent()
        let (primaryTerminal, primaryDelegate) = makeTerminal(capabilities: .standard)
        feed(primaryTerminal, osc("type=write:loc=primary:id=p"))
        #expect(primaryDelegate.waitForSends(1))
        #expect(oscPackets(primaryDelegate.output()) == ["type=write:status=ENOSYS:id=p"])
    }

    @Test func countLimitsReturnEFBIGAndDiscardTheTransaction() {
        let options = TerminalOptions(
            kittyClipboardPolicy: .all,
            kittyClipboardMaximumRepresentations: 4,
            kittyClipboardMaximumAliases: 4)
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock {
            $0.capabilities = .standard
            $0.permission = .allow(rememberPassword: false)
        }
        let terminal = Terminal(delegate: delegate, options: options)

        feed(terminal, osc("type=write:id=reps"))
        for index in 0..<5 {
            feed(terminal, osc("type=wdata:mime=\(b64("text/x-t\(index)"));"))
        }
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=EFBIG:id=reps"])
        #expect(delegate.state.withLock { $0.writes.isEmpty })

        delegate.clearSent()
        feed(terminal, osc("type=write:id=aliases"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("a"))"))
        let names = (0..<5).map { "text/x-a\($0)" }.joined(separator: " ")
        feed(terminal, osc("type=walias:mime=\(b64("text/plain"));\(b64(names))"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=EFBIG:id=aliases"])
        #expect(delegate.state.withLock { $0.writes.isEmpty })
    }

    @Test func theDecodedWriteLimitIsAtLeast64MiB() {
        var options = TerminalOptions(kittyClipboardWriteLimitBytes: 1024)
        #expect(options.kittyClipboardWriteLimitBytes
            == TerminalOptions.minimumKittyClipboardWriteLimitBytes)
        #expect(TerminalOptions.minimumKittyClipboardWriteLimitBytes == 64 * 1024 * 1024)

        // The floors hold for assignment too, not only for the initializer.
        options.kittyClipboardWriteLimitBytes = 1
        options.kittyClipboardMaximumRepresentations = 0
        options.kittyClipboardMaximumAliases = -5
        #expect(options.kittyClipboardWriteLimitBytes
            == TerminalOptions.minimumKittyClipboardWriteLimitBytes)
        #expect(options.kittyClipboardMaximumRepresentations == 1)
        #expect(options.kittyClipboardMaximumAliases == 0)
        options.kittyClipboardWriteLimitBytes = 128 * 1024 * 1024
        #expect(options.kittyClipboardWriteLimitBytes == 128 * 1024 * 1024)

        // A transaction under lowered options still accepts a write.
        var terminalOptions = TerminalOptions(kittyClipboardPolicy: .all)
        terminalOptions.kittyClipboardWriteLimitBytes = 1
        terminalOptions.kittyClipboardMaximumRepresentations = 0
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock {
            $0.capabilities = .standard
            $0.permission = .allow(rememberPassword: false)
        }
        let terminal = Terminal(delegate: delegate, options: terminalOptions)
        feed(terminal, osc("type=write:id=w"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64(String(repeating: "x", count: 5000)))"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=DONE:id=w"])
    }

    @Test func aFragmentedWriteDoesNotRecopyItsAccumulatedData() {
        // 64 MiB in 3 KiB fragments, straight into the transaction. Decoding
        // is linear; a transaction that cloned its accumulated buffer for
        // every fragment would move hundreds of gigabytes and miss the bound
        // by an order of magnitude.
        var transaction = KittyClipboardWriteTransaction(
            serial: 1, location: .standard, id: "", password: "", name: "",
            byteLimit: 64 * 1024 * 1024, representationLimit: 1, aliasLimit: 0)
        let chunk = Data(repeating: 0x5a, count: 3072)
        let fragment = Array(chunk.base64EncodedString().utf8)[...]
        let fragments = (64 * 1024 * 1024) / chunk.count

        let start = Date()
        for _ in 0..<fragments {
            guard transaction.append(mime: "application/octet-stream", payload: fragment) == nil
            else {
                Issue.record("a fragment was rejected")
                return
            }
        }
        let content = transaction.commit()
        let elapsed = Date().timeIntervalSince(start)

        #expect(content?.representations.first?.data.count == fragments * chunk.count)
        #expect(elapsed < 20)
    }

    @Test func anAliasNeverShadowsAnExplicitRepresentation() {
        // An alias named after a representation that already holds its own
        // bytes is EINVAL, in either order.
        let sequences: [[String]] = [
            ["type=write:id=a", "type=wdata:mime=\(b64("text/plain"));\(b64("hello"))",
             "type=wdata:mime=\(b64("text/html"));\(b64("<b>hello</b>"))",
             "type=walias:mime=\(b64("text/html"));\(b64("text/plain"))"],
            ["type=write:id=a", "type=wdata:mime=\(b64("text/html"));\(b64("<b>hello</b>"))",
             "type=walias:mime=\(b64("text/html"));\(b64("text/plain"))",
             "type=wdata:mime=\(b64("text/plain"));\(b64("hello"))"],
        ]
        for sequence in sequences {
            let (terminal, delegate) = makeTerminal(capabilities: .standard)
            delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
            for packet in sequence {
                feed(terminal, osc(packet))
            }
            #expect(delegate.waitForSends(1))
            #expect(oscPackets(delegate.output()) == ["type=write:status=EINVAL:id=a"])
            #expect(delegate.state.withLock { $0.writes.isEmpty })
        }

        // A self-alias adds nothing and is not an error.
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
        feed(terminal, osc("type=write:id=s"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("hello"))"))
        feed(terminal, osc("type=walias:mime=\(b64("text/plain"));\(b64("text/plain text/x-copy"))"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=DONE:id=s"])
        #expect(delegate.state.withLock { $0.writes.first?.aliases }
            == [KittyClipboardAlias(name: "text/x-copy", target: "text/plain")])

        // Host-built content: `flattened` keeps the explicit bytes as well.
        let content = KittyClipboardWriteContent(
            representations: [
                KittyClipboardRepresentation(mimeType: "text/plain", data: Data("hello".utf8)),
                KittyClipboardRepresentation(mimeType: "text/html", data: Data("<b>".utf8)),
            ],
            aliases: [KittyClipboardAlias(name: "text/plain", target: "text/html")])
        #expect(content.flattened == content.representations)
    }

    @Test func aNewWriteReplacesTheActiveTransactionAndACommitAloneIsSilent() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }

        // A commit with no transaction is silent.
        feed(terminal, osc("type=wdata"))
        feed(terminal, osc("type=walias:mime=\(b64("text/plain"));\(b64("text/x-a"))"))
        Thread.sleep(forTimeInterval: 0.03)
        #expect(delegate.output().isEmpty)

        feed(terminal, osc("type=write:id=old"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("old"))"))
        feed(terminal, osc("type=write:id=new"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("new"))"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=DONE:id=new"])
        #expect(delegate.state.withLock { $0.writes.first?.representations.first?.data }
            == Data("new".utf8))
    }

    @Test func anInvalidWriteStillReplacesTheActiveTransaction() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
        feed(terminal, osc("type=write:id=old"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("STALE"))"))
        // A `write` whose own metadata is invalid still discards the old data,
        // and its EINVAL echoes the sanitized id so the client can match it.
        feed(terminal, osc("type=write:loc=bogus:id=new!"))
        feed(terminal, osc("type=wdata"))
        Thread.sleep(forTimeInterval: 0.05)

        #expect(oscPackets(delegate.output()) == ["type=write:status=EINVAL:id=new"])
        #expect(delegate.state.withLock { $0.writes.isEmpty })

        delegate.clearSent()
        feed(terminal, osc("type=write:id=w7:name=not+base64!"))
        #expect(delegate.waitForSends(1))
        #expect(oscPackets(delegate.output()) == ["type=write:status=EINVAL:id=w7"])
    }

    @Test func aSupersededWriteCannotPublishAfterItsDeferredPromptIsAllowed() {
        // The prompt for `old` is still open when `new` replaces it. Allowing
        // the old prompt must neither publish the old data nor store a grant.
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock {
            $0.permission = .allow(rememberPassword: true)
            $0.deferPermission = true
        }
        feed(terminal, osc("type=write:name=\(b64("app")):pw=\(b64("secret")):id=old"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("old"))"))
        feed(terminal, osc("type=wdata"))
        #expect(waitUntil { delegate.state.withLock { $0.permissionCount == 1 } })
        feed(terminal, osc("type=write:id=new"))
        delegate.completeDeferredPermission(.allow(rememberPassword: true))
        Thread.sleep(forTimeInterval: 0.03)
        #expect(delegate.state.withLock { $0.writes.isEmpty })
        #expect(delegate.output().isEmpty)

        // No grant was stored for the stale write, so the password prompts again.
        delegate.state.withLock { $0.permission = .deny }
        feed(terminal, osc("type=write:name=\(b64("app")):pw=\(b64("secret")):id=again"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("x"))"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 2)
        #expect(oscPackets(delegate.output()) == ["type=write:status=EPERM:id=again"])
    }

    @Test func anUnboundedSnapshotLifetimeDoesNotTrap() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        let source = ScriptedSnapshotSource(data: ["text/plain": .data(Data("v".utf8))])
        for lifetime in [Double.infinity, 1e30, .greatestFiniteMagnitude, 1] {
            delegate.clearSent()
            let result = withTerminal(terminal) {
                $0.paste(TerminalPasteRequest(
                    snapshot: source.snapshot(
                        mimeTypes: ["text/plain"], expiresAfter: lifetime)))
            }
            #expect(result == .eventSent)
        }
        // The 30-second cap still applies to a snapshot that never expires.
        let token = passwordField(oscPackets(delegate.output())[0]) ?? ""
        #expect(!token.isEmpty)
    }

    @Test func writeResultsMapToTheStatusTable() {
        let cases: [(KittyClipboardWriteResult, String)] = [
            (.success, "DONE"),
            (.ioError, "EIO"),
            (.invalidData, "EINVAL"),
            (.unsupported, "ENOSYS"),
            (.denied, "EPERM"),
            (.busy, "EBUSY"),
            (.tooLarge, "EFBIG"),
        ]
        for (result, status) in cases {
            let (terminal, delegate) = makeTerminal(capabilities: .standard)
            delegate.state.withLock {
                $0.permission = .allow(rememberPassword: false)
                $0.writeResult = result
            }
            feed(terminal, osc("type=write"))
            feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("x"))"))
            feed(terminal, osc("type=wdata"))
            #expect(delegate.waitForSends(1))
            #expect(oscPackets(delegate.output()) == ["type=write:status=\(status)"])
        }

        // A denied prompt and a host that refuses the work.
        let (denied, deniedDelegate) = makeTerminal(capabilities: .standard)
        deniedDelegate.state.withLock { $0.permission = .deny }
        feed(denied, osc("type=write"))
        feed(denied, osc("type=wdata:mime=\(b64("text/plain"));\(b64("x"))"))
        feed(denied, osc("type=wdata"))
        #expect(deniedDelegate.waitForSends(1))
        #expect(oscPackets(deniedDelegate.output()) == ["type=write:status=EPERM"])

        let (refused, refusedDelegate) = makeTerminal(capabilities: .standard)
        refusedDelegate.state.withLock {
            $0.permission = .allow(rememberPassword: false)
            $0.writeAccepted = false
        }
        feed(refused, osc("type=write"))
        feed(refused, osc("type=wdata:mime=\(b64("text/plain"));\(b64("x"))"))
        feed(refused, osc("type=wdata"))
        #expect(refusedDelegate.waitForSends(1))
        #expect(oscPackets(refusedDelegate.output()) == ["type=write:status=ENOSYS"])
    }

    // MARK: - Base64

    @Test func theStreamingDecoderRejectsNoncanonicalInput() {
        let invalid = [
            "QQ", "QQ=", "QQ=A", "QQB=", "=QQQ", "Q===", "QUJD REVG", "QUJD\nREVG",
            "QU-D", "QQ==QQ==", "QQ== ", "QQQ=Q",
        ]
        for value in invalid {
            #expect(
                KittyClipboardBase64Decoder.decode(Array(value.utf8)[...]) == nil,
                "\(value) must be rejected")
        }
        #expect(KittyClipboardBase64Decoder.decode(Array("QQ==".utf8)[...]) == Data("A".utf8))
        #expect(KittyClipboardBase64Decoder.decode(Array("QUI=".utf8)[...]) == Data("AB".utf8))
        #expect(KittyClipboardBase64Decoder.decode(Array("QUJD".utf8)[...]) == Data("ABC".utf8))
        #expect(KittyClipboardBase64Decoder.decode([]) == Data())
    }

    @Test func theStreamingDecoderBoundsItsDecodedSize() {
        var decoder = KittyClipboardBase64Decoder()
        let encoded = Array(Data(repeating: 0x41, count: 4096).base64EncodedString().utf8)
        #expect(decoder.append(encoded[...], remainingLimit: 10) == .tooLarge)
    }

    @Test func theStreamingDecoderIsLinearForLargeFragmentedInput() {
        // 16 MiB in 4 KiB fragments. A decoder that re-copied its accumulated
        // result for every fragment would be quadratic here.
        let chunk = Data(repeating: 0x5a, count: 3072)
        let fragment = Array(chunk.base64EncodedString().utf8)
        #expect(fragment.count % 4 == 0)
        var decoder = KittyClipboardBase64Decoder()
        let start = Date()
        let fragments = (16 * 1024 * 1024) / chunk.count
        for _ in 0..<fragments {
            #expect(decoder.append(fragment[...], remainingLimit: 64 * 1024 * 1024) == nil)
        }
        #expect(decoder.isComplete)
        #expect(decoder.decoded.count == fragments * chunk.count)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// Opt in with `SWIFTTERM_CLIPBOARD_STRESS=1`. A 64 MiB transaction in
    /// 4 KiB fragments must commit with linear time and bounded copying.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTTERM_CLIPBOARD_STRESS"] == "1"))
    func aSixtyFourMiBFragmentedWriteCommits() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock { $0.permission = .allow(rememberPassword: false) }
        let chunk = Data(repeating: 0x5a, count: 3072)
        let fragment = chunk.base64EncodedString()
        let fragments = (64 * 1024 * 1024) / chunk.count

        let start = Date()
        feed(terminal, osc("type=write:id=big"))
        for _ in 0..<fragments {
            feed(terminal, osc("type=wdata:mime=\(b64("application/octet-stream"));\(fragment)"))
        }
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(1, timeout: 120))
        let elapsed = Date().timeIntervalSince(start)

        #expect(oscPackets(delegate.output()) == ["type=write:status=DONE:id=big"])
        #expect(delegate.state.withLock { $0.writes.first?.representations.first?.data.count }
            == fragments * chunk.count)
        #expect(elapsed < 120)
    }

    // MARK: - 16.6 Parser, lifecycle, and concurrency

    @Test func anOversizedPacketIsConsumedThroughItsRealTerminator() {
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock { $0.capabilities = .standard }
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(maximumOscBytes: 64, kittyClipboardPolicy: .all))

        var bytes = Array("\(esc)]5522;type=read;".utf8)
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: "A"), count: 4096))
        // A UTF-8 continuation byte after the limit is not a terminator.
        bytes.append(0x9c)
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: "B"), count: 64))
        bytes.append(contentsOf: [ControlCodes.ESC, UInt8(ascii: "\\")])
        bytes.append(contentsOf: Array("Z".utf8))
        feedBytes(terminal, bytes)

        Thread.sleep(forTimeInterval: 0.05)
        #expect(delegate.output().isEmpty)
        let line = withTerminal(terminal) { $0.getLine(row: 0)?.translateToString() ?? "" }
        // The dropped payload never reaches the screen, and the byte after the
        // real terminator does.
        #expect(line.hasPrefix("Z"))
        #expect(!line.contains("A"))
        #expect(!line.contains("B"))
    }

    @Test func lateCompletionsAfterRISAndDestructionAreIgnored() {
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock {
            $0.capabilities = .standard
            $0.available = ["text/plain"]
            $0.reads = ["text/plain": .data(Data("x".utf8))]
            $0.deferPermission = true
        }
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(kittyClipboardPolicy: .all))
        feed(terminal, readRequest(password: "secret", name: "app", mimes: "text/plain"))
        #expect(waitUntil { delegate.state.withLock { $0.permissionCount == 1 } })
        feed(terminal, "\(esc)c")
        delegate.clearSent()
        delegate.completeDeferredPermission(.allow(rememberPassword: true))
        Thread.sleep(forTimeInterval: 0.05)
        #expect(delegate.output().isEmpty)

        // The grant that the late completion tried to store is gone too.
        delegate.state.withLock { $0.permission = .deny }
        feed(terminal, readRequest(password: "secret", name: "app", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(output(delegate).contains("EPERM"))
    }

    @Test func delayedCompletionAfterTerminalDestructionIsIgnored() {
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock {
            $0.capabilities = .standard
            $0.available = ["text/plain"]
            $0.deferPermission = true
        }
        var terminal: Terminal? = Terminal(
            delegate: delegate,
            options: TerminalOptions(kittyClipboardPolicy: .all))
        weak var releasedTerminal = terminal
        feed(terminal!, readRequest(password: "secret", name: "app", mimes: "text/plain"))
        #expect(waitUntil { delegate.state.withLock { $0.permissionCount == 1 } })
        delegate.clearSent()
        terminal = nil
        #expect(releasedTerminal == nil)
        delegate.completeDeferredPermission(.allow(rememberPassword: true))
        Thread.sleep(forTimeInterval: 0.05)
        #expect(delegate.output().isEmpty)
    }

    @Test func noClipboardOrPermissionCallbackRunsUnderTerminalLock() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        delegate.state.withLock {
            $0.available = ["text/plain"]
            $0.reads = ["text/plain": .data(Data("x".utf8))]
            $0.permission = .allow(rememberPassword: false)
        }
        feed(terminal, osc("type=read;\(b64("text/plain"))"))
        #expect(delegate.waitForSends(1))
        feed(terminal, osc("type=write"))
        feed(terminal, osc("type=wdata:mime=\(b64("text/plain"));\(b64("x"))"))
        feed(terminal, osc("type=wdata"))
        #expect(delegate.waitForSends(2))
        #expect(!delegate.state.withLock { $0.callbackObservedTerminalLock })
    }

    @Test func grantAndTokenTablesStayWithinTheirBounds() {
        let (terminal, delegate) = makeTerminal(capabilities: .standard)
        feed(terminal, "\(esc)[?5522h")
        let source = ScriptedSnapshotSource(data: ["text/plain": .data(Data("v".utf8))])
        var tokens: [String] = []
        for _ in 0..<40 {
            delegate.clearSent()
            _ = withTerminal(terminal) {
                $0.paste(TerminalPasteRequest(
                    snapshot: source.snapshot(mimeTypes: ["text/plain"])))
            }
            if let token = passwordField(oscPackets(delegate.output())[0]) {
                tokens.append(token)
            }
        }
        #expect(tokens.count == 40)

        // The oldest tokens were evicted; the newest ones still work.
        delegate.state.withLock { $0.available = ["text/plain"] }
        delegate.clearSent()
        feed(terminal, readRequest(password: tokens[0], name: "Paste event", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)

        delegate.clearSent()
        feed(terminal, readRequest(password: tokens[39], name: "Paste event", mimes: "text/plain"))
        #expect(delegate.waitForSends(1))
        #expect(delegate.state.withLock { $0.permissionCount } == 1)
        #expect(output(delegate).contains(b64("v")))

        var grants = KittyClipboardGrants()
        for index in 0..<(KittyClipboardGrants.maximumCount + 8) {
            grants.add(password: "p\(index)", direction: .read, location: .standard)
        }
        #expect(grants.count == KittyClipboardGrants.maximumCount)
    }

    // MARK: - MIME names

    @Test func mimeNameValidationRejectsNonMediaIdentifiers() {
        #expect(KittyClipboardMime.isValid("text/plain"))
        #expect(KittyClipboardMime.isValid("application/vnd.foo+json"))
        #expect(!KittyClipboardMime.isValid("public.utf8-plain-text"))
        #expect(!KittyClipboardMime.isValid("text/plain; charset=utf-8"))
        #expect(!KittyClipboardMime.isValid("/plain"))
        #expect(!KittyClipboardMime.isValid("text/"))
        #expect(!KittyClipboardMime.isValid("text/a/b"))
        #expect(!KittyClipboardMime.isValid("."))
        #expect(!KittyClipboardMime.isValid(""))
        #expect(KittyClipboardMime.matchKey("TEXT/Plain") == "text/plain")
    }

    // MARK: - Helpers

    private func makeTerminal(
        capabilities: KittyClipboardCapabilities
    ) -> (Terminal, ScriptedKittyClipboardDelegate) {
        let delegate = ScriptedKittyClipboardDelegate()
        delegate.state.withLock { $0.capabilities = capabilities }
        return (
            Terminal(delegate: delegate, options: TerminalOptions(kittyClipboardPolicy: .all)),
            delegate
        )
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

    private func osc(_ body: String) -> String {
        "\u{1b}]5522;\(body)\u{1b}\\"
    }

    private func readRequest(
        password: String,
        name: String = "",
        mimes: String,
        location: String = ""
    ) -> String {
        var metadata = "type=read"
        if !location.isEmpty { metadata += ":loc=\(location)" }
        if !name.isEmpty { metadata += ":name=\(b64(name))" }
        if !password.isEmpty { metadata += ":pw=\(b64(password))" }
        return osc("\(metadata);\(b64(mimes))")
    }

    private func b64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    /// The decoded `pw` value of one packet body.
    private func passwordField(_ packet: String) -> String? {
        for record in packet.split(separator: ";")[0].split(separator: ":") {
            guard record.hasPrefix("pw=") else { continue }
            let encoded = String(record.dropFirst(3))
            guard let data = Data(base64Encoded: encoded) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// The decoded payload of one packet body.
    private func decodedPayload(_ packet: String) -> String {
        guard let separator = packet.firstIndex(of: ";") else { return "" }
        let encoded = String(packet[packet.index(after: separator)...])
        guard let data = Data(base64Encoded: encoded) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Splits the delegate output into OSC 5522 packet bodies. Every packet
    /// must use the 7-bit introducer and the `ESC \` terminator.
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
            while end + 1 < bytes.count,
                  !(bytes[end] == ControlCodes.ESC && bytes[end + 1] == UInt8(ascii: "\\"))
            {
                end += 1
            }
            packets.append(String(decoding: bytes[start..<end], as: UTF8.self))
            index = end + 2
        }
        return packets
    }
}
