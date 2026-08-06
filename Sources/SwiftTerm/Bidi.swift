//
//  Bidi.swift
//  SwiftTerm
//
//  Public state for the terminal-wg bidirectional text protocol.
//

import Foundation

/// Selects which side performs bidirectional text processing.
public enum BidiSupportMode: Sendable, Hashable {
    /// SwiftTerm processes logical text for display.
    case implicit
    /// The application supplies text in display order.
    case explicit
}

/// Selects the paragraph base direction.
public enum BidiDirection: Sendable, Hashable {
    case leftToRight
    case rightToLeft
}

/// The six effective presentation modes in the terminal-wg specification.
public enum BidiPresentationMode: Sendable, Hashable {
    case implicitLeftToRight
    case implicitRightToLeft
    case implicitAutoLeftToRight
    case implicitAutoRightToLeft
    case explicitLeftToRight
    case explicitRightToLeft
}

/// The bidirectional presentation state stored with each terminal paragraph.
public struct BidiPresentationState: Sendable, Hashable {
    public var supportMode: BidiSupportMode
    public var autodetectDirection: Bool
    public var fallbackDirection: BidiDirection
    public var boxMirroring: Bool

    public init(supportMode: BidiSupportMode = .implicit,
                autodetectDirection: Bool = true,
                fallbackDirection: BidiDirection = .leftToRight,
                boxMirroring: Bool = false) {
        self.supportMode = supportMode
        self.autodetectDirection = autodetectDirection
        self.fallbackDirection = fallbackDirection
        self.boxMirroring = boxMirroring
    }

    public static let `default` = BidiPresentationState()

    /// Returns the effective mode without discarding stored state.
    public var presentationMode: BidiPresentationMode {
        switch (supportMode, autodetectDirection, fallbackDirection) {
        case (.implicit, true, .leftToRight):
            return .implicitAutoLeftToRight
        case (.implicit, true, .rightToLeft):
            return .implicitAutoRightToLeft
        case (.implicit, false, .leftToRight):
            return .implicitLeftToRight
        case (.implicit, false, .rightToLeft):
            return .implicitRightToLeft
        case (.explicit, _, .leftToRight):
            return .explicitLeftToRight
        case (.explicit, _, .rightToLeft):
            return .explicitRightToLeft
        }
    }
}

/// Selects how an Apple terminal view applies terminal BiDi state.
public enum BidiHostPolicy: Sendable, Hashable {
    /// Apply the state that the terminal protocol stores with each paragraph.
    case respectTerminal
    /// Draw all cells in logical left-to-right order.
    case legacyLeftToRight
}
