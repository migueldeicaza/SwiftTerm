//
//  MarkedTextOverlayTestSupport.swift
//
//  Helpers shared by the tests of the IME / dictation marked-text overlay.
//
#if os(macOS)
import AppKit
@testable import SwiftTerm

extension TerminalView {
    static func makeForMarkedTextTests() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
    }

    /// Sets `text` as the marked text with the selection at its end, as an IME does while composing.
    func setMarkedText(_ text: String) {
        setMarkedText(text,
                      selectedRange: NSRange(location: (text as NSString).length, length: 0),
                      replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    var dictationOverlay: DictationOverlayTextView? {
        subviews.lazy.compactMap { $0 as? DictationOverlayTextView }.first
    }
}
#endif
