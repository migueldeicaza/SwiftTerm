//
//  ColorContrast+Apple.swift
//
//  Keeps a native color readable on its background.
//
#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Holds the color Powerline separators, box drawing, and block elements are drawn in: the text color before
/// `minimumContrastRatio` adjusts it, since those characters draw shapes, such as pixel art, whose colors are meant
/// to blend in.
let SwiftTermShapeColorKey = NSAttributedString.Key("SwiftTermShapeColor")

extension TTColor {
    /// This color, darkened or lightened as little as possible to reach `minimumRatio` against `background`.
    func withContrast(atLeast minimumRatio: CGFloat, against background: TTColor) -> TTColor {
        guard minimumRatio > 1,
              let (foreground, alpha) = contrastComponents,
              let (backgroundComponents, _) = background.contrastComponents else {
            return self
        }
        let adjusted = ColorContrast.adjusted(foreground, toReach: Double(minimumRatio), against: backgroundComponents)
        guard adjusted != foreground else { return self }
        return TTColor.make(red: CGFloat(adjusted.red), green: CGFloat(adjusted.green), blue: CGFloat(adjusted.blue), alpha: alpha)
    }

    private var contrastComponents: (ColorContrast.RGB, CGFloat)? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        #if os(macOS)
        guard let color = usingColorSpace(.sRGB) else { return nil }
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #endif
        return (ColorContrast.RGB(red: Double(red), green: Double(green), blue: Double(blue)), alpha)
    }
}
#endif
#endif
