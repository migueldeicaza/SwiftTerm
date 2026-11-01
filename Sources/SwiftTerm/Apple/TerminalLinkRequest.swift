//
//  TerminalLinkRequest.swift
//
#if !SWIFTTERM_EMBEDDED
#if os(iOS) || os(visionOS) || os(macOS)
import Foundation

/// A link that the user activated in a ``TerminalView``.
///
/// SwiftTerm sends this value to
/// ``TerminalViewDelegate/requestOpenLink(source:request:)``.
public struct TerminalLinkRequest {
    /// The link text from the terminal output, unchanged.
    ///
    /// It is untrusted: it can be a relative path, a path with a `:line` or
    /// `:line:column` suffix, or a URL with any scheme.
    public let link: String

    /// The key/value pairs of an OSC 8 hyperlink. Empty for detected links.
    public let params: [String: String]

    /// True when the link is an OSC 8 hyperlink. The program chose its target,
    /// and the target can be different from the visible text.
    /// False when SwiftTerm detected the link in the visible text.
    public let isExplicit: Bool

    /// How the view that made the request checks and opens links.
    /// Nil for a request that a host made with the public initializer.
    let policy: TerminalLinkPolicy?

    public init(link: String, params: [String: String], isExplicit: Bool) {
        self.init(link: link, params: params, isExplicit: isExplicit, policy: nil)
    }

    init(link: String, params: [String: String], isExplicit: Bool, policy: TerminalLinkPolicy?) {
        self.link = link
        self.params = params
        self.isExplicit = isExplicit
        self.policy = policy
    }
}

/// How a view checks and opens the links of its requests.
struct TerminalLinkPolicy {
    /// Checks a link and gives the approved URL to the second argument.
    let check: @MainActor (String, @escaping @MainActor (URL) -> Void) -> Void
    /// Opens an approved URL.
    let open: @MainActor (URL) -> Void
}

extension TerminalViewDelegate {
    /// Calls the deprecated method from the default implementation of the new one.
    func requestOpenLinkWithoutDeprecationWarning(source: TerminalView, link: String, params: [String: String]) {
        // The cast hides the deprecated conformance, so SwiftTerm builds without a warning.
        (DeprecatedLinkDelegate.self as Any as! DeprecatedLinkDelegateCall.Type)
            .requestOpenLink(self, source: source, link: link, params: params)
    }
}

fileprivate protocol DeprecatedLinkDelegateCall {
    @MainActor
    static func requestOpenLink(
        _ delegate: TerminalViewDelegate, source: TerminalView, link: String, params: [String: String])
}

fileprivate enum DeprecatedLinkDelegate {}

@available(*, deprecated)
extension DeprecatedLinkDelegate: DeprecatedLinkDelegateCall {
    @MainActor
    static func requestOpenLink(
        _ delegate: TerminalViewDelegate, source: TerminalView, link: String, params: [String: String]
    ) {
        delegate.requestOpenLink(source: source, link: link, params: params)
    }
}
#endif
#endif // !SWIFTTERM_EMBEDDED
