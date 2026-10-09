//
//  ColorContrast.swift
//
//  Contrast between sRGB colors as WCAG 2 defines it, used to keep text readable on its background.
//
#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

enum ColorContrast {
    /// An sRGB color with components from 0 to 1.
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)
    }

    static func relativeLuminance(_ color: RGB) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// From 1, for two colors of the same luminance, to 21, for black and white.
    static func ratio(_ first: RGB, _ second: RGB) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05) / (min(firstLuminance, secondLuminance) + 0.05)
    }

    /// `foreground` itself when it already reaches `minimumRatio` against `background`. Otherwise it moves toward
    /// black when it is darker than the background, or toward white when it is lighter, just far enough to reach the
    /// ratio. When that side can't reach it, the other side is tried, and the color with more contrast is returned.
    static func adjusted(_ foreground: RGB, toReach minimumRatio: Double, against background: RGB) -> RGB {
        guard ratio(foreground, background) < minimumRatio else { return foreground }
        let isDarkerThanBackground = relativeLuminance(foreground) <= relativeLuminance(background)
        let sameSide = isDarkerThanBackground ? RGB.black : RGB.white
        let otherSide = isDarkerThanBackground ? RGB.white : RGB.black
        let sameSideColor = nearestMix(of: foreground, toward: sameSide, reaching: minimumRatio, against: background)
        if ratio(sameSideColor, background) >= minimumRatio { return sameSideColor }
        let otherSideColor = nearestMix(of: foreground, toward: otherSide, reaching: minimumRatio, against: background)
        return ratio(sameSideColor, background) >= ratio(otherSideColor, background) ? sameSideColor : otherSideColor
    }

    /// The least mix of `color` toward `target` that reaches `minimumRatio`, or `target` when even it falls short.
    /// Along the mix, contrast either only grows or first shrinks to 1 and then grows, so once a fraction reaches
    /// the ratio every larger one does too, and a binary search finds the least.
    private static func nearestMix(of color: RGB, toward target: RGB, reaching minimumRatio: Double, against background: RGB) -> RGB {
        guard ratio(target, background) >= minimumRatio else { return target }
        var tooLittle = 0.0
        var enough = 1.0
        for _ in 0..<20 {
            let fraction = (tooLittle + enough) / 2
            if ratio(mix(color, target, fraction: fraction), background) >= minimumRatio {
                enough = fraction
            } else {
                tooLittle = fraction
            }
        }
        return mix(color, target, fraction: enough)
    }

    private static func mix(_ first: RGB, _ second: RGB, fraction: Double) -> RGB {
        RGB(
            red: first.red + (second.red - first.red) * fraction,
            green: first.green + (second.green - first.green) * fraction,
            blue: first.blue + (second.blue - first.blue) * fraction
        )
    }
}
#endif
#endif
