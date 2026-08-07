//
//  ColorBridge.swift
//  SwiftTerm
//
//  Public bridges between the terminal Color type and the platform native
//  color types. Both platforms share the same conversion path (the internal
//  getTerminalColor/make helpers, which clamp to sRGB); only the property
//  names differ, matching each platform's conventions.
//
#if os(macOS)
import AppKit

public extension Color {
    /// Creates a terminal color from an `NSColor`; the color is converted to sRGB
    /// (components clamped to the sRGB range), and the alpha component is
    /// discarded, as terminal colors carry no alpha
    convenience init (nsColor: NSColor)
    {
        let source = nsColor.getTerminalColor ()
        self.init (red: source.red, green: source.green, blue: source.blue)
    }

    /// Returns the color as an `NSColor` in the sRGB color space
    var nsColor: NSColor {
        return NSColor.make (color: self)
    }
}
#elseif os(iOS) || os(visionOS)
import UIKit

public extension Color {
    /// Creates a terminal color from a `UIColor`; the color is converted to sRGB
    /// (components clamped to the sRGB range), and the alpha component is
    /// discarded, as terminal colors carry no alpha
    convenience init (uiColor: UIColor)
    {
        let source = uiColor.getTerminalColor ()
        self.init (red: source.red, green: source.green, blue: source.blue)
    }

    /// Returns the color as a `UIColor`
    var uiColor: UIColor {
        return UIColor.make (color: self)
    }
}
#endif
