//
//  SemanticPrompt.swift
//  SwiftTerm
//
//  OSC 133 semantic-prompt types shared by the terminal core and views.
//

import Foundation

/// The shell-defined role of content written to the terminal by OSC 133.
/// Values are attached to cells as they are written and survive scrollback.
public enum SemanticContent: Equatable {
    /// No OSC 133 role has been assigned to this cell.
    case none
    /// A shell prompt, optionally qualified by its kind.
    case prompt(SemanticPromptKind)
    /// Editable shell input following an OSC 133 `B` or `I` marker.
    case input
    /// Command output following an OSC 133 `C` or `D` marker.
    case output
}

/// The kind of shell prompt described by OSC 133's `k` option.
public enum SemanticPromptKind: Equatable {
    /// The normal primary prompt (`k=i`, or the default).
    case initial
    /// A right-side prompt (`k=r`).
    case right
    /// A continuation prompt (`k=c`).
    case continuation
    /// A secondary/PS2 prompt (`k=s`).
    case secondary
}

/// How the shell requested OSC 133 prompt clicks to be delivered.
public enum SemanticPromptClickMode: Equatable {
    case none
    case clickEventsAbsolute
    case clickEventsRelative
    case cursorKeys(SemanticPromptCursorClickMode)
}

/// Cursor navigation strategy selected by OSC 133's `cl` option.
public enum SemanticPromptCursorClickMode: Equatable {
    case line
    case multiple
    case conservativeVertical
    case smartVertical
}

/// Cross-platform modifiers supplied with a pointer event.
public struct SemanticPromptClickModifiers: OptionSet, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = SemanticPromptClickModifiers(rawValue: 1 << 0)
    public static let control = SemanticPromptClickModifiers(rawValue: 1 << 1)
    public static let option = SemanticPromptClickModifiers(rawValue: 1 << 2)
    public static let command = SemanticPromptClickModifiers(rawValue: 1 << 3)
}

/// Controls whether an eligible primary click is routed to the active OSC 133 shell prompt.
public enum SemanticPromptClickBehavior: Equatable {
    /// Preserve normal view click handling.
    case disabled
    /// Route every eligible primary click to the shell. This is the default.
    case enabled
    /// Route an eligible click only when all specified modifiers are held.
    case requireModifier(SemanticPromptClickModifiers)
}

enum SemanticPromptRedrawBehavior: Equatable {
    case enabled
    case disabled
    case lastLine
}
