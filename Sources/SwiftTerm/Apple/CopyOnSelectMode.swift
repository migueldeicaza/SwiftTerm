//
//  CopyOnSelectMode.swift
//
#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)

/// Where ``TerminalView`` copies the selected text when the user completes a
/// selection gesture. See ``TerminalView/copyOnSelect``.
public enum CopyOnSelectMode: Sendable {
    /// The view does not copy. This is the default.
    case off
    /// The view copies to the system clipboard, the one that the Copy and
    /// Paste commands use.
    case clipboard
    /// The view copies to the primary selection, the one that
    /// `pastePrimarySelection()` reads. The system clipboard does not change.
    ///
    /// iOS and visionOS have no primary selection, thus the view copies
    /// nothing there.
    case primarySelection
    /// The view copies to the system clipboard and to the primary selection.
    ///
    /// On iOS and visionOS this is the same as ``clipboard``.
    case both
}

#endif
#endif
