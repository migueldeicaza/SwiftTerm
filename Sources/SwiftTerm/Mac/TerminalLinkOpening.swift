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
        fileManager: FileManager = .default
    ) -> UntrustedTerminalLink {
        guard !isExplicit,
              !UntrustedTerminalLink.containsUnsafeCharacters(link),
              URL(string: link)?.scheme == nil,
              let url = defaultLinkURL(link, fileManager: fileManager) else {
            return UntrustedTerminalLink(link)
        }
        return UntrustedTerminalLink(url.absoluteString)
    }

    /// Checks the target before calling a host delegate, including custom delegates.
    func activateLink(
        _ link: String,
        params: [String: String],
        isExplicit: Bool,
        presentAlert: @escaping TerminalLinkOpening.Presentation = TerminalLinkOpening.present
    ) {
        let target = Self.defaultLinkTarget(link, isExplicit: isExplicit)
        TerminalLinkOpening.request(target, window: window, presentAlert: presentAlert) { [weak self] url in
            guard let self, !isExplicit || enableOsc8Hyperlinks else { return }
            let previous = approvedLinkForDelegate
            approvedLinkForDelegate = url
            defer { approvedLinkForDelegate = previous }
            terminalDelegate?.requestOpenLink(source: self, link: url.absoluteString, params: params)
        }
    }

    /// The default delegate consumes the checked target without a second prompt.
    func openLinkFromDelegate(_ link: String) {
        if let url = approvedLinkForDelegate, url.absoluteString == link {
            NSWorkspace.shared.open(url)
        } else {
            Self.openDefaultLink(link)
        }
    }
}
#endif
