/*
 * Adapted from Ghostty's untrusted URL policy and alert.
 * https://github.com/ghostty-org/ghostty/commit/77537c8065f3055d214144caab7d137543a6e133
 *
 * MIT License
 *
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
#if os(macOS) && !SWIFTTERM_EMBEDDED
import AppKit

/// Keeps terminal output out of Launch Services until the target is checked.
@MainActor
enum TerminalLinkOpening {
    typealias Presentation = @MainActor (
        NSAlert, NSWindow?, @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> Void

    static func request(
        _ target: UntrustedTerminalLink,
        window: NSWindow?,
        presentAlert: @escaping Presentation = present,
        open: @escaping @MainActor (URL) -> Void
    ) {
        switch target.decision {
        case .allow(let url):
            open(url)
        case .confirm(let url):
            // Queue alerts after input handling releases the terminal lock.
            DispatchQueue.main.async {
                let alert = confirmationAlert(for: url, displayString: target.displayString)
                presentAlert(alert, window) { response in
                    guard response == .alertSecondButtonReturn else { return }
                    open(url)
                }
            }
        case .deny(let reason):
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Link blocked"
                alert.informativeText = reason.message
                alert.accessoryView = targetView(target.displayString)
                alert.addButton(withTitle: "OK")
                presentAlert(alert, window) { _ in }
            }
        }
    }

    static func confirmationAlert(for url: URL, displayString: String) -> NSAlert {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
            .map { $0.deletingPathExtension().lastPathComponent }
            ?? "the default application"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open link from terminal output?"
        alert.informativeText = "This link will open in \(handler). Open it only if you trust the destination."
        alert.accessoryView = targetView(displayString)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Link")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return alert
    }

    static func present(
        _ alert: NSAlert,
        window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private static func targetView(_ target: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = target
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }
}

extension TerminalView {
    /// Explicit OSC 8 targets must have a scheme. Detected paths can become file URLs.
    nonisolated static func defaultLinkTarget(
        _ link: String,
        isExplicit: Bool,
        pathBase: LinkPathBase = .processDirectory,
        fileManager: FileManager = .default
    ) -> UntrustedTerminalLink {
        guard !isExplicit,
              !UntrustedTerminalLink.containsUnsafeCharacters(link),
              !hasURLScheme(link),
              let url = defaultLinkURL(link, pathBase: pathBase, fileManager: fileManager) else {
            return UntrustedTerminalLink(link)
        }
        return UntrustedTerminalLink(url.absoluteString)
    }

    /// Gives the link to the delegate as the terminal output has it.
    func activateLink(
        _ link: String,
        params: [String: String],
        isExplicit: Bool,
        presentAlert: @escaping TerminalLinkOpening.Presentation = TerminalLinkOpening.present,
        open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        guard allowsLink(isExplicit: isExplicit) else { return }
        let policy = TerminalLinkPolicy(check: { [weak self] link, approved in
            self?.checkLink(link, isExplicit: isExplicit, presentAlert: presentAlert, approved: approved)
        }, open: open)
        let request = TerminalLinkRequest(link: link, params: params, isExplicit: isExplicit, policy: policy)
        terminalDelegate?.requestOpenLink(source: self, request: request)
    }

    /// OSC 8 links work only while they are enabled.
    func allowsLink(isExplicit: Bool) -> Bool {
        !isExplicit || enableOsc8Hyperlinks
    }

    /// Checks a link with SwiftTerm's policy and gives the approved URL to `approved`.
    func checkLink(
        _ link: String,
        isExplicit: Bool,
        presentAlert: @escaping TerminalLinkOpening.Presentation,
        approved: @escaping @MainActor (URL) -> Void
    ) {
        // A host can open a kept request from a callback that holds the terminal lock.
        if terminal.terminalLock.isLockedByCurrentThread {
            DispatchQueue.main.async { [weak self] in
                self?.checkLink(link, isExplicit: isExplicit, presentAlert: presentAlert, approved: approved)
            }
            return
        }
        guard allowsLink(isExplicit: isExplicit) else { return }
        var pathBase = Self.linkPathBase(hostCurrentDirectory: withTerminal { $0.hostCurrentDirectory })
        // Only the host can tell that the session is local. A remote host in
        // OSC 7 still blocks local paths.
        if !resolvesLinksAgainstShellDirectory, pathBase != .remote {
            pathBase = .processDirectory
        }
        let target = Self.defaultLinkTarget(link, isExplicit: isExplicit, pathBase: pathBase)
        TerminalLinkOpening.request(target, window: window, presentAlert: presentAlert) { [weak self] url in
            guard let self, allowsLink(isExplicit: isExplicit) else { return }
            approved(url)
        }
    }

    /// A checked URL, and how to open it, for the deprecated delegate method.
    struct ApprovedLink {
        let url: URL
        let open: @MainActor (URL) -> Void
    }

    /// Checks the link, then calls the deprecated delegate method with the approved URL.
    func requestOpenLinkWithCheckedURL(_ request: TerminalLinkRequest, delegate: TerminalViewDelegate) {
        let policy = request.effectivePolicy
        // An approval goes only to the delegate that the view still uses.
        let isViewDelegate = terminalDelegate === delegate
        policy.check(request.link) { [weak self, weak delegate] url in
            guard let self, let delegate, !isViewDelegate || terminalDelegate === delegate else { return }
            let previous = approvedLinkForDelegate
            approvedLinkForDelegate = ApprovedLink(url: url, open: policy.open)
            defer { approvedLinkForDelegate = previous }
            delegate.requestOpenLinkWithoutDeprecationWarning(
                source: self, link: url.absoluteString, params: request.params)
        }
    }

    /// The default delegate consumes the checked target without a second prompt.
    func openLinkFromDelegate(_ link: String) {
        if let approved = approvedLinkForDelegate, approved.url.absoluteString == link {
            approved.open(approved.url)
        } else {
            Self.openDefaultLink(link)
        }
    }
}

extension TerminalLinkRequest {
    /// The policy of the view that made the request. A request from the public
    /// initializer uses the OSC 8 rules of `isExplicit`, shows alerts for the
    /// application, and opens links with `NSWorkspace`.
    @MainActor
    var effectivePolicy: TerminalLinkPolicy {
        if let policy {
            return policy
        }
        let isExplicit = isExplicit
        return TerminalLinkPolicy(check: { link, approved in
            let target = TerminalView.defaultLinkTarget(link, isExplicit: isExplicit)
            TerminalLinkOpening.request(target, window: nil, open: approved)
        }, open: { NSWorkspace.shared.open($0) })
    }

    /// Checks a link with SwiftTerm's policy, then opens it with its default handler.
    ///
    /// Unsafe local files are blocked, and custom URL schemes need confirmation.
    /// For an OSC 8 link, the target must have a scheme. A detected relative
    /// path resolves against the shell's directory from OSC 7, when the shell
    /// reports one and the view's `resolvesLinksAgainstShellDirectory` is true.
    /// Alerts show as a sheet on the window of the view.
    ///
    /// You can call this method after `requestOpenLink(source:request:)` returns,
    /// for example after an async step. A relative path then resolves against
    /// the shell's directory at the time of that call. Nothing opens if the
    /// view is gone or if OSC 8 links were disabled.
    /// - Parameter link: the link to open. Nil opens ``link``. Give a rewrite of
    ///   ``link`` to open a different target.
    @MainActor
    public func openDefault(_ link: String? = nil) {
        let policy = effectivePolicy
        policy.check(link ?? self.link, policy.open)
    }
}
#endif
