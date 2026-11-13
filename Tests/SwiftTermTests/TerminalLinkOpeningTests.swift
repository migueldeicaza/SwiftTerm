#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite("Terminal link dispatch")
struct TerminalLinkOpeningTests {
    // The test delegates conform directly. A subclass cannot override a
    // requestOpenLink that a base class gets from the protocol extension.
    fileprivate protocol StubDelegate: TerminalViewDelegate {}

    private final class Delegate: StubDelegate {
        var requests: [TerminalLinkRequest] = []
        var handle: (TerminalLinkRequest) -> Void = { _ in }
        func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
            requests.append(request)
            handle(request)
        }
    }

    // Implements only the deprecated method.
    private final class LegacyDelegate: StubDelegate {
        var links: [String] = []
        var approvedDuringCall: [URL?] = []
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            links.append(link)
            approvedDuringCall.append(source.approvedLinkForDelegate?.url)
        }
    }

    // Uses the default requestOpenLink.
    private final class DefaultDelegate: StubDelegate {}

    private func rewritingDelegate(_ rewrite: @escaping (String) -> String) -> Delegate {
        let delegate = Delegate()
        delegate.handle = { $0.openDefault(rewrite($0.link)) }
        return delegate
    }

    private func makeTemporaryFile() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("main.txt")
        try Data("x".utf8).write(to: file)
        return (directory, file)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test(arguments: [
        ("Sources/App/main.swift:12", false),
        ("/abs/Sources/App/main.swift:12:4", false),
        ("main.swift:12", true),
        ("file:///System/Applications/Calculator.app", false),
        ("file:///System/Applications/Calculator.app", true),
        ("ssh://example.com", true),
    ])
    func customDelegateReceivesTheOriginalLink(link: String, isExplicit: Bool) {
        let view = TerminalView(frame: .zero)
        view.localLinkResolver = { _ in
            Issue.record("No resolution before a custom delegate")
            return nil
        }
        let delegate = Delegate()
        view.terminalDelegate = delegate
        withExtendedLifetime(delegate) {
            view.activateLink(link, params: ["id": "test"], isExplicit: isExplicit) { _, _, _ in
                Issue.record("No alert before a custom delegate")
            } open: { _ in
                Issue.record("Nothing opens without openDefault")
            }
        }
        #expect(delegate.requests.map(\.link) == [link])
        #expect(delegate.requests.map(\.params) == [["id": "test"]])
        #expect(delegate.requests.map(\.isExplicit) == [isExplicit])
    }

    @Test func legacyDelegateReceivesTheCheckedURL() throws {
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = LegacyDelegate()
        view.terminalDelegate = delegate
        withExtendedLifetime(delegate) {
            view.activateLink(file.path + ":12", params: [:], isExplicit: false) { _, _, _ in
                Issue.record("A plain local file needs no alert")
            } open: { _ in
                Issue.record("The legacy delegate opens the link")
            }
        }
        #expect(delegate.links.map { URL(string: $0)?.resolvingSymlinksInPath() }
                == [file.resolvingSymlinksInPath()])
        #expect(delegate.approvedDuringCall.map(\.?.absoluteString) == delegate.links)
        #expect(view.approvedLinkForDelegate?.url == nil)
    }

    @Test func publicRequestReachesTheLegacyDelegate() {
        let view = TerminalView(frame: .zero)
        let delegate = LegacyDelegate()
        let request = TerminalLinkRequest(link: "https://example.com", params: ["id": "x"], isExplicit: true)
        delegate.requestOpenLink(source: view, request: request)
        #expect(delegate.links == ["https://example.com"])
    }

    @Test func approvalDoesNotReachAReplacedDelegate() async {
        let view = TerminalView(frame: .zero)
        let delegate = LegacyDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        var alerts = 0
        view.activateLink("ssh://example.com", params: [:], isExplicit: true) { _, _, completion in
            alerts += 1
            view.terminalDelegate = nil
            completion(.alertSecondButtonReturn)
        } open: { _ in
            Issue.record("The legacy delegate opens the link")
        }
        await waitUntil { alerts == 1 }
        #expect(delegate.links.isEmpty)
    }

    @Test(arguments: [true, false])
    func legacyDelegateDoesNotReceiveADeniedLink(isExplicit: Bool) async {
        let view = TerminalView(frame: .zero)
        let delegate = LegacyDelegate()
        view.terminalDelegate = delegate
        var alerts = 0
        defer { withExtendedLifetime(delegate) {} }
        view.activateLink("file:///System/Applications/Calculator.app", params: [:], isExplicit: isExplicit) {
            alert, _, completion in
            alerts += 1
            #expect(alert.buttons.map(\.title) == ["OK"])
            completion(.alertFirstButtonReturn)
        }
        await waitUntil { alerts == 1 }
        #expect(delegate.links.isEmpty)
    }

    @Test func explicitLinkDoesNotReachTheDelegateWhileOsc8IsDisabled() {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.enableOsc8Hyperlinks = false
        withExtendedLifetime(delegate) {
            view.activateLink("https://example.com", params: [:], isExplicit: true)
        }
        #expect(delegate.requests.isEmpty)
    }

    @Test(arguments: [true, false])
    func defaultDelegateOpensAnAllowedLink(isExplicit: Bool) {
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        var opened: [URL] = []
        withExtendedLifetime(delegate) {
            view.activateLink("https://example.com", params: [:], isExplicit: isExplicit) { _, _, _ in
                Issue.record("An allowed link needs no alert")
            } open: { opened.append($0) }
        }
        #expect(opened == [URL(string: "https://example.com")!])
        #expect(view.approvedLinkForDelegate?.url == nil)
    }

    @Test(arguments: [
        ("file:///System/Applications/Calculator.app", true),
        ("file:///System/Applications/Calculator.app", false),
    ])
    func defaultDelegateBlocksADeniedLink(link: String, isExplicit: Bool) async {
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        var alerts = 0
        var opened: [URL] = []
        defer { withExtendedLifetime(delegate) {} }
        view.activateLink(link, params: [:], isExplicit: isExplicit) { alert, _, completion in
            alerts += 1
            #expect(alert.buttons.map(\.title) == ["OK"])
            completion(.alertFirstButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { alerts == 1 }
        #expect(opened.isEmpty)
    }

    @Test func defaultDelegateDeniesAnOsc8TargetWithoutAScheme() async throws {
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        var alerts = 0
        var opened: [URL] = []
        defer { withExtendedLifetime(delegate) {} }
        // The same path opens as a detected link.
        view.activateLink(file.path, params: [:], isExplicit: false) { _, _, _ in
            Issue.record("A plain local file needs no alert")
        } open: { opened.append($0) }
        #expect(opened.count == 1)

        view.activateLink(file.path, params: [:], isExplicit: true) { alert, _, completion in
            alerts += 1
            #expect(alert.buttons.map(\.title) == ["OK"])
            completion(.alertFirstButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { alerts == 1 }
        #expect(opened.count == 1)
    }

    @Test(arguments: [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn])
    func customSchemesNeedExplicitConfirmation(_ response: NSApplication.ModalResponse) async {
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        var alerts = 0
        var opened: [URL] = []
        defer { withExtendedLifetime(delegate) {} }
        view.activateLink("ssh://example.com", params: [:], isExplicit: true) { _, _, completion in
            alerts += 1
            #expect(opened.isEmpty)
            completion(response)
        } open: { opened.append($0) }
        #expect(opened.isEmpty)
        await waitUntil { alerts == 1 }
        #expect(opened == (response == .alertSecondButtonReturn ? [URL(string: "ssh://example.com")!] : []))
    }

    @Test func disablingOsc8WhileConfirmationIsOpenPreventsOpening() async {
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        var alerts = 0
        var opened: [URL] = []
        defer { withExtendedLifetime(delegate) {} }
        view.activateLink("ssh://example.com", params: [:], isExplicit: true) { _, _, completion in
            alerts += 1
            view.enableOsc8Hyperlinks = false
            completion(.alertSecondButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { alerts == 1 }
        #expect(opened.isEmpty)
    }

    @Test(arguments: [true, false])
    func deferredOpenDefaultKeepsThePolicy(disableOsc8: Bool) {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        var opened: [URL] = []
        withExtendedLifetime(delegate) {
            view.activateLink("https://example.com", params: [:], isExplicit: true) { _, _, _ in
                Issue.record("An allowed link needs no alert")
            } open: { opened.append($0) }
        }
        #expect(opened.isEmpty)

        view.enableOsc8Hyperlinks = !disableOsc8
        delegate.requests.first?.openDefault()
        #expect(opened == (disableOsc8 ? [] : [URL(string: "https://example.com")!]))
    }

    @Test func localProcessViewUsesTheDefaultCheck() async {
        let view = LocalProcessTerminalView(frame: .zero)
        var alerts = 0
        var opened: [URL] = []
        view.activateLink("file:///System/Applications/Calculator.app", params: [:],
                          isExplicit: false) { _, _, completion in
            alerts += 1
            completion(.alertFirstButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { alerts == 1 }
        #expect(opened.isEmpty)

        view.activateLink("https://example.com", params: [:], isExplicit: false) { _, _, _ in
            Issue.record("An allowed link needs no alert")
        } open: { opened.append($0) }
        #expect(opened == [URL(string: "https://example.com")!])
    }

    @Test func rewrittenDetectedPathOpensAsAFile() throws {
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = rewritingDelegate { directory.path + "/" + $0 }
        view.terminalDelegate = delegate
        var opened: [URL] = []
        withExtendedLifetime(delegate) {
            view.activateLink("main.txt:12", params: [:], isExplicit: false) { _, _, _ in
                Issue.record("A plain local file needs no alert")
            } open: { opened.append($0) }
        }
        #expect(opened.map { $0.resolvingSymlinksInPath() } == [file.resolvingSymlinksInPath()])
    }

    @Test func rewrittenOsc8TargetKeepsTheOsc8Rules() async throws {
        let (directory, _) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = rewritingDelegate { directory.path + "/" + $0 }
        view.terminalDelegate = delegate
        var alerts = 0
        var opened: [URL] = []
        defer { withExtendedLifetime(delegate) {} }
        view.activateLink("main.txt:12", params: [:], isExplicit: true) { alert, _, completion in
            alerts += 1
            #expect(alert.buttons.map(\.title) == ["OK"])
            completion(.alertFirstButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { alerts == 1 }
        #expect(opened.isEmpty)
    }

    @Test func openDefaultWhileTheTerminalLockIsHeldWaitsForTheLock() async {
        let view = TerminalView(frame: .zero)
        let delegate = Delegate()
        view.terminalDelegate = delegate
        var opened: [URL] = []
        withExtendedLifetime(delegate) {
            view.activateLink("https://example.com", params: [:], isExplicit: true) { _, _, _ in
                Issue.record("An allowed link needs no alert")
            } open: { opened.append($0) }
        }
        view.terminal.terminalLock.withLock {
            delegate.requests.first?.openDefault()
        }
        #expect(opened.isEmpty)
        await waitUntil { opened.count == 1 }
    }

    @Test func detectedRelativePathResolvesAgainstTheShellDirectory() throws {
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        view.resolvesLinksAgainstShellDirectory = true
        view.feed(text: "\u{1b}]7;file://localhost\(directory.path)\u{07}")
        var opened: [URL] = []
        withExtendedLifetime(delegate) {
            view.activateLink("main.txt:12", params: [:], isExplicit: false) { _, _, _ in
                Issue.record("A plain local file needs no alert")
            } open: { opened.append($0) }
        }
        #expect(opened.map { $0.resolvingSymlinksInPath() } == [file.resolvingSymlinksInPath()])
    }

    @Test func withoutTheHostGateOsc7IsNotTheBase() async throws {
        let (directory, _) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        #expect(!view.resolvesLinksAgainstShellDirectory)
        // A remote program can claim that its directory is on this Mac.
        view.feed(text: "\u{1b}]7;file://localhost\(directory.path)\u{07}")
        var alerts = 0
        var opened: [URL] = []
        view.activateLink("main.txt:12", params: [:], isExplicit: false) { alert, _, completion in
            alerts += 1
            #expect(alert.buttons.map(\.title) == ["OK"])
            completion(.alertFirstButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { alerts == 1 }
        #expect(opened.isEmpty)
    }

    @Test func localProcessViewResolvesAgainstTheShellDirectory() {
        #expect(LocalProcessTerminalView(frame: .zero).resolvesLinksAgainstShellDirectory)
    }

    @Test(arguments: [true, false])
    func localResolverUsesTheHostSessionContext(isExplicit: Bool) throws {
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        var resolved: [String] = []
        view.localLinkResolver = { link in
            resolved.append(link)
            return file
        }
        let links = ["main.txt", "main.txt:12:4", "/project/main.txt"]
        var opened: [URL] = []
        for link in links {
            view.activateLink(link, params: [:], isExplicit: isExplicit) { _, _, _ in
                Issue.record("A resolved plain file needs no alert")
            } open: { opened.append($0) }
        }
        #expect(resolved == links)
        #expect(opened == Array(repeating: file.resolvingSymlinksInPath(), count: links.count))
    }

    @Test(arguments: [true, false], [nil, URL(string: "https://example.com")] as [URL?])
    func unresolvedLocalLinksDoNotFallBack(isExplicit: Bool, result: URL?) async throws {
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        view.resolvesLinksAgainstShellDirectory = true
        view.feed(text: "\u{1b}]7;file://localhost\(directory.path)\u{07}")
        var resolved: [String] = []
        view.localLinkResolver = { link in
            resolved.append(link)
            return result
        }
        var alerts = 0
        var opened: [URL] = []
        let links = [file.path, "main.txt"]
        for link in links {
            view.activateLink(link, params: [:], isExplicit: isExplicit) { alert, _, completion in
                alerts += 1
                #expect(alert.buttons.map(\.title) == ["OK"])
                #expect(alert.informativeText == UntrustedTerminalLink.DenialReason.inaccessibleFile.message)
                completion(.alertFirstButtonReturn)
            } open: { opened.append($0) }
        }
        await waitUntil { alerts == links.count }
        #expect(resolved == links)
        #expect(opened.isEmpty)
    }

    @Test(arguments: [true, false])
    func resolvedLocalFilesStillPassTheSafetyChecks(isExplicit: Bool) async throws {
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsafeFile = directory.appendingPathComponent("payload.command")
        try FileManager.default.moveItem(at: file, to: unsafeFile)
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        view.localLinkResolver = { _ in unsafeFile }
        var alerts = 0
        var opened: [URL] = []
        view.activateLink("payload.command", params: [:], isExplicit: isExplicit) { alert, _, completion in
            alerts += 1
            #expect(alert.informativeText == UntrustedTerminalLink.DenialReason.unsafeFile.message)
            completion(.alertFirstButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { alerts == 1 }
        #expect(opened.isEmpty)
    }

    @Test(arguments: [true, false])
    func unsafePathsDoNotReachTheLocalResolver(isExplicit: Bool) async {
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        view.localLinkResolver = { _ in
            Issue.record("Unsafe characters must be checked before resolution")
            return nil
        }
        var alerts = 0
        view.activateLink("main\u{202E}.txt", params: [:], isExplicit: isExplicit) { alert, _, completion in
            alerts += 1
            #expect(alert.informativeText == UntrustedTerminalLink.DenialReason.unsafeCharacters.message)
            completion(.alertFirstButtonReturn)
        } open: { _ in Issue.record("An unsafe path must not open") }
        await waitUntil { alerts == 1 }
    }

    @Test(arguments: ["README:12", "README", "~/main.txt", "src/main.txt:3:1"], [true, false])
    func pathsWithoutAnExtensionUseOnlyTheLocalResolver(link: String, isExplicit: Bool) async throws {
        // A file with this name in the shell directory must not open when the resolver says no.
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent("README"))
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        view.resolvesLinksAgainstShellDirectory = true
        view.feed(text: "\u{1b}]7;file://localhost\(directory.path)\u{07}")
        var resolved: [String] = []
        view.localLinkResolver = { link in
            resolved.append(link)
            return nil
        }
        var alerts = 0
        view.activateLink(link, params: [:], isExplicit: isExplicit) { alert, _, completion in
            alerts += 1
            if link == "README:12" {
                // Without a file, this text is also a URL with the scheme "README",
                // as it is without a resolver. Cancel is the default.
                #expect(alert.buttons.map(\.title) == ["Cancel", "Open Link"])
            } else {
                #expect(alert.informativeText == UntrustedTerminalLink.DenialReason.inaccessibleFile.message)
            }
            completion(.alertFirstButtonReturn)
        } open: { _ in Issue.record("An unresolved path must not open") }
        await waitUntil { alerts == 1 }
        #expect(resolved == [link])
    }

    @Test(arguments: ["custom:123", "vscode:123"], [true, false])
    func unresolvedSchemeLikeNamesStayURLs(link: String, isExplicit: Bool) async throws {
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        var resolved: [String] = []
        view.localLinkResolver = { link in
            resolved.append(link)
            return nil
        }
        var opened: [URL] = []
        view.activateLink(link, params: [:], isExplicit: isExplicit) { alert, _, completion in
            #expect(alert.buttons.map(\.title) == ["Cancel", "Open Link"])
            completion(.alertSecondButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { opened.count == 1 }
        #expect(resolved == [link])
        #expect(opened == [URL(string: link)!])
    }

    @Test(arguments: ["https://example.com", "tel:5551234"], [true, false])
    func urlsDoNotReachTheLocalResolver(link: String, isExplicit: Bool) async throws {
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        view.resolvesLinksAgainstShellDirectory = true
        view.feed(text: "\u{1b}]7;file://localhost\(directory.path)\u{07}")
        view.localLinkResolver = { _ in
            Issue.record("A URL must not be resolved as a local path")
            return file
        }
        var prompts = 0
        var opened: [URL] = []
        view.activateLink(link, params: [:], isExplicit: isExplicit) { alert, _, completion in
            prompts += 1
            #expect(alert.buttons.map(\.title) == ["Cancel", "Open Link"])
            completion(.alertSecondButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { opened.count == 1 }
        #expect(prompts == (link.hasPrefix("https:") ? 0 : 1))
        #expect(opened == [URL(string: link)!])
    }

    @Test(arguments: [true, false])
    func detectedPathFromARemoteShellIsDenied(resolvesAgainstShellDirectory: Bool) async throws {
        let (directory, file) = try makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = TerminalView(frame: .zero)
        let delegate = DefaultDelegate()
        view.terminalDelegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        view.resolvesLinksAgainstShellDirectory = resolvesAgainstShellDirectory
        view.localLinkResolver = { _ in
            Issue.record("A remote path must not be resolved locally")
            return file
        }
        view.feed(text: "\u{1b}]7;file://remote.example.com\(directory.path)\u{07}")
        var alerts = 0
        var opened: [URL] = []
        view.activateLink(file.path, params: [:], isExplicit: false) { alert, _, completion in
            alerts += 1
            #expect(alert.buttons.map(\.title) == ["OK"])
            completion(.alertFirstButtonReturn)
        } open: { opened.append($0) }
        await waitUntil { alerts == 1 }
        #expect(opened.isEmpty)
    }
}

extension TerminalLinkOpeningTests.StubDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
