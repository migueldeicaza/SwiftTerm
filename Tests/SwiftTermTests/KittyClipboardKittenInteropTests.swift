#if os(macOS)
import Darwin
import Foundation
import Testing

@testable import SwiftTerm

private let kittenInteropExecutable: String? = {
    guard let path = ProcessInfo.processInfo.environment["SWIFTTERM_KITTEN"],
          !path.isEmpty,
          FileManager.default.isExecutableFile(atPath: path)
    else {
        return nil
    }
    return path
}()

private enum KittenClipboardAuthorizationPolicy: Sendable {
    case autoGrant
    case deny
    case grantWithRemember
}

private final class KittenClipboardDelegate: TerminalDelegate, @unchecked Sendable {
    struct State {
        var clipboard: [KittyClipboardRepresentation] = []
        var primary: [KittyClipboardRepresentation] = []
        var readRequests: [KittyClipboardReadRequest] = []
        var writeRequests: [KittyClipboardWriteRequest] = []
        var replyBytes: [UInt8] = []
        var sendErrors: [String] = []
        var masterFD: Int32 = -1
    }

    let state = Locked(State())
    let authorizationPolicy: KittenClipboardAuthorizationPolicy
    let supportsPrimary: Bool

    init(
        authorizationPolicy: KittenClipboardAuthorizationPolicy,
        supportsPrimary: Bool = true
    ) {
        self.authorizationPolicy = authorizationPolicy
        self.supportsPrimary = supportsPrimary
    }

    func attach(masterFD: Int32) {
        state.withLock {
            $0.masterFD = masterFD
            $0.replyBytes.removeAll(keepingCapacity: true)
            $0.sendErrors.removeAll(keepingCapacity: true)
        }
    }

    func detach(masterFD: Int32) {
        state.withLock {
            if $0.masterFD == masterFD {
                $0.masterFD = -1
            }
        }
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        let fd = state.withLock { state -> Int32 in
            state.replyBytes.append(contentsOf: bytes)
            return state.masterFD
        }
        guard fd >= 0 else {
            state.withLock { $0.sendErrors.append("reply has no active PTY") }
            return
        }

        var writeError: Int32?
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count == -1 && errno == EINTR {
                    continue
                } else {
                    writeError = errno
                    break
                }
            }
        }
        if let writeError {
            state.withLock {
                $0.sendErrors.append("PTY reply write failed: errno \(writeError)")
            }
        }
    }

    func kittyClipboardRead(
        source: Terminal,
        request: KittyClipboardReadRequest,
        completion: @escaping @Sendable (KittyClipboardReadResult) -> Void
    ) {
        let result = state.withLock { state -> KittyClipboardReadResult in
            state.readRequests.append(request)
            guard request.location != .primary || supportsPrimary else {
                return .unsupported
            }
            guard authorizationPolicy != .deny else {
                return .denied
            }

            let store = request.location == .primary ? state.primary : state.clipboard
            let representations = Self.selectRepresentations(
                from: store,
                requestedTypes: request.types)
            let remember = authorizationPolicy == .grantWithRemember
                && request.authorization == .required
                && request.canRemember
            return .success(KittyClipboardReadSuccess(
                representations: representations,
                availableTypes: store.map(\.type),
                remember: remember))
        }
        completion(result)
    }

    func kittyClipboardWrite(
        source: Terminal,
        request: KittyClipboardWriteRequest,
        completion: @escaping @Sendable (KittyClipboardWriteResult) -> Void
    ) {
        let result = state.withLock { state -> KittyClipboardWriteResult in
            state.writeRequests.append(request)
            guard request.location != .primary || supportsPrimary else {
                return .unsupported
            }
            guard authorizationPolicy != .deny else {
                return .denied
            }

            if request.location == .primary {
                state.primary = request.representations
            } else {
                state.clipboard = request.representations
            }
            let remember = authorizationPolicy == .grantWithRemember
                && request.authorization == .required
                && request.canRemember
            return .success(KittyClipboardWriteSuccess(remember: remember))
        }
        completion(result)
    }

    func kittyClipboardPasteEventsSupported(source: Terminal) -> Bool {
        true
    }

    func preload(
        _ representations: [KittyClipboardRepresentation],
        location: KittyClipboardLocation = .clipboard
    ) {
        state.withLock {
            if location == .primary {
                $0.primary = representations
            } else {
                $0.clipboard = representations
            }
        }
    }

    func representations(at location: KittyClipboardLocation) -> [KittyClipboardRepresentation] {
        state.withLock { location == .primary ? $0.primary : $0.clipboard }
    }

    var readRequests: [KittyClipboardReadRequest] {
        state.withLock { $0.readRequests }
    }

    var writeRequests: [KittyClipboardWriteRequest] {
        state.withLock { $0.writeRequests }
    }

    private static func selectRepresentations(
        from store: [KittyClipboardRepresentation],
        requestedTypes: [String]
    ) -> [KittyClipboardRepresentation] {
        let requestedTypes = requestedTypes.filter { $0 != "." }
        guard !requestedTypes.isEmpty else { return store }

        var selected: [KittyClipboardRepresentation] = []
        for requestedType in requestedTypes {
            for representation in store
            where type(representation.type, matches: requestedType)
                && !selected.contains(where: { $0.type == representation.type })
            {
                selected.append(representation)
            }
        }
        return selected
    }

    private static func type(_ type: String, matches pattern: String) -> Bool {
        if pattern == "*" || pattern == "*/*" || pattern == type {
            return true
        }
        if pattern.hasSuffix("/*") {
            return type.hasPrefix(pattern.dropLast())
        }
        return false
    }
}

private struct KittenInvocationResult {
    let waitStatus: Int32
    let transcript: [UInt8]
    let replies: [UInt8]
    let sendErrors: [String]

    var exitCode: Int? {
        guard waitStatus & 0x7f == 0 else { return nil }
        return Int((waitStatus >> 8) & 0xff)
    }

    var diagnostic: String {
        let outcome = exitCode.map { "exit \($0)" }
            ?? "wait status \(waitStatus)"
        let errors = sendErrors.isEmpty
            ? ""
            : "; send errors: \(sendErrors.joined(separator: ", "))"
        return "\(outcome)\(errors); transcript tail: \(Self.shortText(transcript))"
    }

    private static func shortText(_ bytes: [UInt8]) -> String {
        let suffix = bytes.suffix(2_048)
        return String(decoding: suffix, as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}", with: "<ESC>")
            .replacingOccurrences(of: "\u{7}", with: "<BEL>")
    }
}

private enum KittenInteropHarnessError: Error, CustomStringConvertible {
    case launchFailed
    case waitFailed(errno: Int32)
    case timedOut(transcript: String)
    case readerDidNotStop

    var description: String {
        switch self {
        case .launchFailed:
            return "forkpty or exec setup failed"
        case .waitFailed(let error):
            return "waitpid failed with errno \(error)"
        case .timedOut(let transcript):
            return "kitten timed out; transcript tail: \(transcript)"
        case .readerDidNotStop:
            return "the PTY reader did not stop after child exit"
        }
    }
}

private final class KittenInteropHarness {
    let delegate: KittenClipboardDelegate
    private let terminalAccess: LockedTerminalTestAccess

    init(
        authorizationPolicy: KittenClipboardAuthorizationPolicy = .autoGrant,
        supportsPrimary: Bool = true
    ) {
        let delegate = KittenClipboardDelegate(
            authorizationPolicy: authorizationPolicy,
            supportsPrimary: supportsPrimary)
        self.delegate = delegate
        terminalAccess = LockedTerminalTestAccess(Terminal(delegate: delegate))
    }

    func run(
        _ clipboardArguments: [String],
        currentDirectory: URL,
        fragmentTerminalInput: Bool = false,
        timeout: TimeInterval = 45
    ) throws -> KittenInvocationResult {
        guard let executable = kittenInteropExecutable else {
            throw KittenInteropHarnessError.launchFailed
        }

        var windowSize = winsize(
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 640,
            ws_ypixel: 384)
        let processEnvironment = ProcessInfo.processInfo.environment
        var environment = [
            "TERM=xterm-kitty",
            "PATH=\(processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")",
            "HOME=\(processEnvironment["HOME"] ?? NSTemporaryDirectory())",
        ]
        if let language = processEnvironment["LANG"] {
            environment.append("LANG=\(language)")
        }

        let arguments = [executable, "clipboard"] + clipboardArguments
        guard let child = PseudoTerminalHelpers.fork(
            andExec: executable,
            args: arguments,
            env: environment,
            currentDirectory: currentDirectory.path,
            desiredWindowSize: &windowSize)
        else {
            throw KittenInteropHarnessError.launchFailed
        }

        let transcript = Locked<[UInt8]>([])
        let readerDone = DispatchSemaphore(value: 0)
        delegate.attach(masterFD: child.masterFd)

        let terminalAccess = terminalAccess
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(child.masterFd, rawBuffer.baseAddress, rawBuffer.count)
                }
                if count > 0 {
                    let bytes = Array(buffer[..<count])
                    transcript.withLock { $0.append(contentsOf: bytes) }
                    if fragmentTerminalInput {
                        for byte in bytes {
                            terminalAccess.withLock { terminal in
                                let oneByte = [byte]
                                terminal.feed(buffer: oneByte[...])
                            }
                        }
                    } else {
                        terminalAccess.withLock { terminal in
                            terminal.feed(buffer: bytes[...])
                        }
                    }
                } else if count == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            readerDone.signal()
        }
        reader.name = "swiftterm-kitten-pty-reader"
        reader.start()

        var waitStatus: Int32 = 0
        var waitError: Int32?
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let waited = Darwin.waitpid(child.pid, &waitStatus, WNOHANG)
            if waited == child.pid {
                break
            }
            if waited == -1 {
                if errno == EINTR { continue }
                waitError = errno
                break
            }
            if Date() >= deadline {
                timedOut = true
                _ = Darwin.kill(child.pid, SIGKILL)
                repeat {
                    errno = 0
                } while Darwin.waitpid(child.pid, &waitStatus, 0) == -1 && errno == EINTR
                break
            }
            Darwin.usleep(10_000)
        }

        var readerStopped = readerDone.wait(timeout: .now() + 2) == .success
        if !readerStopped {
            delegate.detach(masterFD: child.masterFd)
            Darwin.close(child.masterFd)
            readerStopped = readerDone.wait(timeout: .now() + 2) == .success
        } else {
            delegate.detach(masterFD: child.masterFd)
            Darwin.close(child.masterFd)
        }

        let capturedTranscript = transcript.withLock { $0 }
        let replyState = delegate.state.withLock { ($0.replyBytes, $0.sendErrors) }
        if timedOut {
            let tail = String(decoding: capturedTranscript.suffix(2_048), as: UTF8.self)
            throw KittenInteropHarnessError.timedOut(transcript: tail)
        }
        if let waitError {
            throw KittenInteropHarnessError.waitFailed(errno: waitError)
        }
        guard readerStopped else {
            throw KittenInteropHarnessError.readerDidNotStop
        }
        return KittenInvocationResult(
            waitStatus: waitStatus,
            transcript: capturedTranscript,
            replies: replyState.0,
            sendErrors: replyState.1)
    }
}

@Suite(
    .serialized,
    .enabled(if: kittenInteropExecutable != nil)
)
struct KittyClipboardKittenInteropTests {
    @Test func writesTextFileAndHandlesByteFragmentedPTYInput() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = KittenInteropHarness()

        let text = Data("kitten writes plain text".utf8)
        let textFile = try Self.write(text, named: "file.txt", in: directory)
        let normal = try harness.run([textFile.path], currentDirectory: directory)
        #expect(normal.exitCode == 0, "\(normal.diagnostic)")
        #expect(Self.data(for: "text/plain", in: harness.delegate.representations(at: .clipboard)) == text)

        let fragmentedText = Data("one byte at a time".utf8)
        let fragmentedFile = try Self.write(
            fragmentedText,
            named: "fragmented.txt",
            in: directory)
        let fragmented = try harness.run(
            [fragmentedFile.path],
            currentDirectory: directory,
            fragmentTerminalInput: true)
        #expect(fragmented.exitCode == 0, "\(fragmented.diagnostic)")
        #expect(Self.data(
            for: "text/plain",
            in: harness.delegate.representations(at: .clipboard)) == fragmentedText)
    }

    @Test func writesMultipleMIMETypesAndAlias() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = KittenInteropHarness()

        let text = Data("two typed inputs".utf8)
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let textFile = try Self.write(text, named: "multi.txt", in: directory)
        let pngFile = try Self.write(png, named: "pixel.png", in: directory)
        let multiple = try harness.run(
            [textFile.path, pngFile.path],
            currentDirectory: directory)
        #expect(multiple.exitCode == 0, "\(multiple.diagnostic)")
        let multipleStore = harness.delegate.representations(at: .clipboard)
        #expect(Self.data(for: "text/plain", in: multipleStore) == text)
        #expect(Self.data(for: "image/png", in: multipleStore) == png)

        let alias = "text/x-swiftterm-interop"
        let aliased = try harness.run(
            ["--alias", "text/plain=\(alias)", textFile.path],
            currentDirectory: directory)
        #expect(aliased.exitCode == 0, "\(aliased.diagnostic)")
        let aliasStore = harness.delegate.representations(at: .clipboard)
        #expect(Self.data(for: "text/plain", in: aliasStore) == text)
        #expect(Self.data(for: alias, in: aliasStore) == text)
    }

    @Test func readsPayloadAndListsAvailableTypes() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = KittenInteropHarness()
        let payload = Data("exact kitten clipboard payload".utf8)
        harness.delegate.preload([
            KittyClipboardRepresentation(type: "text/plain", data: payload),
            KittyClipboardRepresentation(type: "text/html", data: Data("<b>payload</b>".utf8)),
        ])

        let read = try harness.run(
            ["--get-clipboard", "/dev/stdout"],
            currentDirectory: directory)
        #expect(read.exitCode == 0, "\(read.diagnostic)")
        #expect(Self.contains(payload, in: read.transcript), "\(read.diagnostic)")

        let listing = try harness.run(
            ["--get-clipboard", "--mime", ".", "/dev/stdout"],
            currentDirectory: directory)
        #expect(listing.exitCode == 0, "\(listing.diagnostic)")
        let listingText = String(decoding: listing.transcript, as: UTF8.self)
        #expect(listingText.contains("text/plain"), "\(listing.diagnostic)")
        #expect(listingText.contains("text/html"), "\(listing.diagnostic)")
    }

    @Test func usesPrimaryAndReportsUnsupportedPrimary() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("primary selection".utf8)
        let file = try Self.write(payload, named: "primary.txt", in: directory)

        let supported = KittenInteropHarness(supportsPrimary: true)
        let supportedResult = try supported.run(
            ["--use-primary", file.path],
            currentDirectory: directory)
        #expect(supportedResult.exitCode == 0, "\(supportedResult.diagnostic)")
        #expect(supported.delegate.representations(at: .clipboard).isEmpty)
        #expect(Self.data(
            for: "text/plain",
            in: supported.delegate.representations(at: .primary)) == payload)

        let unsupported = KittenInteropHarness(supportsPrimary: false)
        let unsupportedResult = try unsupported.run(
            ["--use-primary", file.path],
            currentDirectory: directory)
        let unsupportedText = String(
            decoding: unsupportedResult.transcript + unsupportedResult.replies,
            as: UTF8.self)
        #expect(
            unsupportedResult.exitCode != 0 || unsupportedText.contains("ENOSYS"),
            "\(unsupportedResult.diagnostic)")
        #expect(unsupported.delegate.representations(at: .clipboard).isEmpty)
        #expect(unsupported.delegate.representations(at: .primary).isEmpty)
    }

    @Test func passwordDenialAndRememberedGrant() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("authorized clipboard write".utf8)
        let file = try Self.write(payload, named: "authorized.txt", in: directory)
        let arguments = [
            "--password", "text:swiftterm-kitten-secret",
            "--human-name", "SwiftTerm kitten interop",
            file.path,
        ]

        let denied = KittenInteropHarness(authorizationPolicy: .deny)
        let deniedResult = try denied.run(arguments, currentDirectory: directory)
        let deniedText = String(
            decoding: deniedResult.transcript + deniedResult.replies,
            as: UTF8.self)
        #expect(
            deniedResult.exitCode != 0 || deniedText.contains("EPERM"),
            "\(deniedResult.diagnostic)")
        #expect(denied.delegate.representations(at: .clipboard).isEmpty)
        let deniedRequest = try #require(denied.delegate.writeRequests.last)
        #expect(deniedRequest.authorization == .required)
        #expect(deniedRequest.canRemember)
        #expect(deniedRequest.applicationName == "SwiftTerm kitten interop")

        let granted = KittenInteropHarness(authorizationPolicy: .grantWithRemember)
        let first = try granted.run(arguments, currentDirectory: directory)
        #expect(first.exitCode == 0, "\(first.diagnostic)")
        let firstRequest = try #require(granted.delegate.writeRequests.first)
        #expect(firstRequest.authorization == .required)
        #expect(firstRequest.canRemember)

        let second = try granted.run(arguments, currentDirectory: directory)
        #expect(second.exitCode == 0, "\(second.diagnostic)")
        let secondRequest = try #require(granted.delegate.writeRequests.last)
        #expect(secondRequest.authorization == .granted)
        #expect(!secondRequest.canRemember)
        #expect(Self.data(
            for: "text/plain",
            in: granted.delegate.representations(at: .clipboard)) == payload)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftTerm-kitten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        return directory
    }

    private static func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try data.write(to: file, options: .atomic)
        return file
    }

    private static func data(
        for type: String,
        in representations: [KittyClipboardRepresentation]
    ) -> Data? {
        representations.first { $0.type == type }?.data
    }

    private static func contains(_ needle: Data, in haystack: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        return haystack.withUnsafeBufferPointer { haystackBuffer in
            needle.withUnsafeBytes { needleBuffer in
                guard let needleBase = needleBuffer.baseAddress else { return true }
                let needleBytes = needleBase.assumingMemoryBound(to: UInt8.self)
                guard haystackBuffer.count >= needleBuffer.count else { return false }
                for offset in 0...(haystackBuffer.count - needleBuffer.count) {
                    if memcmp(
                        haystackBuffer.baseAddress!.advanced(by: offset),
                        needleBytes,
                        needleBuffer.count) == 0
                    {
                        return true
                    }
                }
                return false
            }
        }
    }
}
#endif
