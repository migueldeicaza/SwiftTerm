//
//  LocalProcessKittyClipboardTests.swift
//
//  LocalProcessTerminalView is its own TerminalViewDelegate, so the Kitty
//  clipboard hooks must reach the host through the processDelegate. Without
//  the forwarding, DEC private mode 5522 reports as unrecognized for every
//  host that embeds the local-process view, however the host is configured.
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
private final class ClipboardHost: LocalProcessTerminalViewDelegate {
    let capabilities: KittyClipboardCapabilities
    var permissionRequests = 0

    init(capabilities: KittyClipboardCapabilities) {
        self.capabilities = capabilities
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        capabilities
    }

    func kittyClipboardRequestPermission(
        source: TerminalView,
        request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult {
        permissionRequests += 1
        return .allow(rememberPassword: false)
    }
}

/// A host that only implements the four process hooks gets the defaults.
@MainActor
private final class MinimalHost: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

/// Captures what the core sends to the process instead of writing to a PTY.
private final class CapturingLocalProcessTerminalView: LocalProcessTerminalView {
    var sent: [UInt8] = []

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }
}

@Suite struct LocalProcessKittyClipboardTests {
    private let esc = "\u{1b}"

    @MainActor
    private func makeView() -> CapturingLocalProcessTerminalView {
        CapturingLocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 160),
            options: TerminalOptions(cols: 80, rows: 25, kittyClipboardPolicy: .all))
    }

    /// The view hands core responses to its delegate on the main queue.
    @MainActor
    private func decrqm5522(_ view: CapturingLocalProcessTerminalView) async -> String {
        view.sent.removeAll()
        view.feed(text: "\(esc)[?5522$p")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        return String(decoding: view.sent, as: UTF8.self)
    }

    @MainActor @Test func processDelegateCapabilitiesReachTheCore() async {
        let view = makeView()
        // No host yet: the view answers for itself and serves nothing.
        #expect(view.kittyClipboardCapabilities(source: view.terminal) == [])
        #expect(await decrqm5522(view) == "\(esc)[?5522;0$y")

        let host = ClipboardHost(capabilities: .standard)
        view.processDelegate = host
        #expect(view.kittyClipboardCapabilities(source: view.terminal) == .standard)
        #expect(await decrqm5522(view) == "\(esc)[?5522;2$y")
    }

    @MainActor @Test func partialHostKeepsModeUnsupported() async {
        let view = makeView()
        let host = ClipboardHost(capabilities: .standardWrite)
        view.processDelegate = host
        #expect(await decrqm5522(view) == "\(esc)[?5522;0$y")
    }

    @MainActor @Test func replacingTheHostRefreshesTheCachedCapabilities() async {
        let view = makeView()
        let full = ClipboardHost(capabilities: .standard)
        view.processDelegate = full
        #expect(await decrqm5522(view) == "\(esc)[?5522;2$y")

        let none = ClipboardHost(capabilities: [])
        view.processDelegate = none
        #expect(view.kittyClipboardCapabilities(source: view.terminal) == [])
        #expect(await decrqm5522(view) == "\(esc)[?5522;0$y")
    }

    @MainActor @Test func defaultHostDeniesEverything() async {
        let view = makeView()
        let host = MinimalHost()
        view.processDelegate = host
        #expect(view.kittyClipboardCapabilities(source: view.terminal) == [])
        #expect(await decrqm5522(view) == "\(esc)[?5522;0$y")
        let request = KittyClipboardPermissionRequest(
            direction: .read, location: .standard, name: "test",
            mimeTypes: ["text/plain"], canRememberPassword: false)
        guard case .deny = view.kittyClipboardRequestPermission(source: view, request: request) else {
            Issue.record("the default host must deny a permission request")
            return
        }
    }
}
#endif
