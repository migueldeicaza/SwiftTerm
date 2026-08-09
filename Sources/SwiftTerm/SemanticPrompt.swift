//
//  SemanticPrompt.swift
//  SwiftTerm
//
//  OSC 133 semantic-prompt types shared by the terminal core and views.
//
//  The model stores only what the shell said: zero-width marks from OSC 133
//  `A` and `P`, and one line-level continuation bit written by the line-feed
//  handler. Everything else — row classification, click eligibility, logical
//  offsets — is derived on demand.
//

import Foundation

/// The shell-defined role of content written to the terminal by OSC 133.
/// Values are attached to cells as they are written and survive scrollback.
public enum SemanticContent: Equatable, CustomStringConvertible {
    /// No OSC 133 role has been assigned to this cell.
    case none
    /// A shell prompt, optionally qualified by its kind.
    case prompt(SemanticPromptKind)
    /// Editable shell input following an OSC 133 `B` or `I` marker.
    case input
    /// Command output following an OSC 133 `C` or `D` marker.
    case output

    public var description: String {
        switch self {
        case .none: return "none"
        case .prompt(let kind): return "prompt(\(kind))"
        case .input: return "input"
        case .output: return "output"
        }
    }
}

/// The kind of shell prompt described by OSC 133's `k` option.
public enum SemanticPromptKind: Equatable, CustomStringConvertible {
    /// The normal primary prompt (`k=i`, or the default).
    case initial
    /// A right-side prompt (`k=r`).
    case right
    /// A continuation row. Never stored as a mark: this value is only
    /// produced by the derived row classification (`semanticRowKind`).
    case continuation
    /// A secondary/PS2 prompt (`k=s`).
    case secondary

    /// A stable serialization of the prompt kind, matching the protocol's
    /// `k=` option values.
    public var tagName: String {
        switch self {
        case .initial: return "i"
        case .right: return "r"
        case .continuation: return "c"
        case .secondary: return "s"
        }
    }

    public var description: String {
        switch self {
        case .initial: return "initial"
        case .right: return "right"
        case .continuation: return "continuation"
        case .secondary: return "secondary"
        }
    }
}

/// A zero-width OSC 133 prompt marker in the terminal buffer.
public struct SemanticPromptAnchor: Equatable {
    /// The marker position, relative to the start of the buffer.
    public let position: Position

    /// The prompt kind supplied by the shell.
    public let kind: SemanticPromptKind

    public init(position: Position, kind: SemanticPromptKind) {
        self.position = position
        self.kind = kind
    }
}

/// A shell-authored mark stored on a buffer line: the `k=` kind and column
/// of an OSC 133 `A` or `P` action. There is at most one mark per kind per
/// line; re-marking replaces.
///
/// `group` is the prompt-group ID active when the mark was written (0 when no
/// group is active). Row-kind derivation (R5) follows a hard-continuation link
/// only when the line's epoch matches the origin mark's `group`, which is what
/// isolates a new prompt from an old group's stranded continuation rows.
struct SemanticMark: Equatable {
    let kind: SemanticPromptKind
    var column: Int
    var group: UInt64 = 0
}

/// The per-buffer input lifetime state machine (R4). Authoritative
/// transitions come from the pty stream; heuristics only ever move toward
/// `submitted`, never toward `armed`.
enum SemanticInputState: Equatable {
    /// No OSC 133 activity, or a full reset.
    case idle
    /// Between `A`/`N` and `B`/`I`: prompt cells are being written.
    case prompt
    /// Between `B`/`I` and the end of input: cells are tagged `.input` and
    /// clicks are eligible.
    case armed
    /// Input ended (`C`/`D`, a submission heuristic, or an alternate-screen
    /// switch): clicks are ineligible until the next `B`/`I`.
    case submitted
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
    /// Route an eligible primary click only when no modifiers are held. This is the default.
    case enabled
    /// Route an eligible click only when the exact specified modifiers are held.
    case requireModifier(SemanticPromptClickModifiers)
}

/// The gesture state a view captured at pointer-press time, before any
/// handler mutated it. The shared arbiter uses it to decide whether a
/// completed primary click may be routed to the semantic prompt.
public struct SemanticPromptPointerSnapshot: Equatable {
    /// Whether a selection was active when the press began; the click that
    /// dismisses a selection is not a prompt click.
    public var selectionWasActive: Bool
    /// Whether the press turned into a drag before release.
    public var didDrag: Bool
    /// The click count reported for the press.
    public var clickCount: Int
    /// Whether application mouse reporting did not consume the press.
    public var pressWasSemanticEligible: Bool

    public init(selectionWasActive: Bool, didDrag: Bool, clickCount: Int,
                pressWasSemanticEligible: Bool) {
        self.selectionWasActive = selectionWasActive
        self.didDrag = didDrag
        self.clickCount = clickCount
        self.pressWasSemanticEligible = pressWasSemanticEligible
    }
}
