//
//  BellStyle.swift
//  SwiftTerm
//
//  How a terminal view responds to the BEL (0x07) control character.
//
#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

/// How the terminal view responds to the bell (BEL, 0x07).
///
/// Like ``CursorStyle``, this enum only adopts CaseIterable; naming is
/// provided by members (`tagName`, `displayName`, ``init(tagName:)``) so
/// that client retroactive conformances (Codable and friends) keep working.
public enum BellStyle: CaseIterable {
    /// The bell is ignored
    case none
    /// The `TerminalViewDelegate.bell` method is invoked (the default
    /// implementation beeps on macOS, produces haptic feedback on iOS)
    case sound
    /// The terminal view flashes briefly
    case visual
    /// Both the sound and the visual flash
    case soundAndVisual

    /// A stable, machine-readable name, suitable for persisting settings;
    /// the inverse of ``init(tagName:)``
    public var tagName: String {
        switch self {
        case .none: return "none"
        case .sound: return "sound"
        case .visual: return "visual"
        case .soundAndVisual: return "soundAndVisual"
        }
    }

    /// A human-readable name, for use in user interfaces
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .sound: return "Sound"
        case .visual: return "Visual"
        case .soundAndVisual: return "Sound and Visual"
        }
    }

    /// Creates a bell style from the stable name returned by ``tagName``
    public init? (tagName: String) {
        guard let match = BellStyle.allCases.first (where: { $0.tagName == tagName }) else {
            return nil
        }
        self = match
    }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
