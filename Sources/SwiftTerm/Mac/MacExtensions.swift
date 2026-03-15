//
//  MacExtensions.swift
//  
//
//  Created by Miguel de Icaza on 6/29/21.
//

#if os(macOS)
import Foundation
import AppKit

extension NSColor {
    func getTerminalColor () -> Color {
        guard let color = self.usingColorSpace(.deviceRGB) else {
            return Color.defaultForeground
        }
        
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Color(red: UInt16(red*65535), green: UInt16(green*65535), blue: UInt16(blue*65535))
    }
    func inverseColor() -> NSColor {
        guard let color = self.usingColorSpace(.deviceRGB) else {
            return self
        }

        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return NSColor(calibratedRed: 1.0 - red, green: 1.0 - green, blue: 1.0 - blue, alpha: alpha)
    }

    /// Returns a dimmed version of the color (SGR 2 faint/dim attribute) by
    /// blending 50 % toward `background`. The result is fully opaque so that
    /// adjacent box-drawing characters tile without visible seams.
    func dimmedColor (towards background: NSColor) -> NSColor {
        guard let fg = self.usingColorSpace(.deviceRGB),
              let bg = background.usingColorSpace(.deviceRGB) else {
            return self
        }
        var fRed: CGFloat = 0.0, fGreen: CGFloat = 0.0, fBlue: CGFloat = 0.0, fAlpha: CGFloat = 1.0
        fg.getRed(&fRed, green: &fGreen, blue: &fBlue, alpha: &fAlpha)
        var bRed: CGFloat = 0.0, bGreen: CGFloat = 0.0, bBlue: CGFloat = 0.0, bAlpha: CGFloat = 1.0
        bg.getRed(&bRed, green: &bGreen, blue: &bBlue, alpha: &bAlpha)
        return NSColor (deviceRed: (fRed + bRed) * 0.5,
                        green: (fGreen + bGreen) * 0.5,
                        blue: (fBlue + bBlue) * 0.5,
                        alpha: fAlpha)
    }

    static func make (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> NSColor
    {
        return NSColor (deviceRed: red, green: green, blue: blue, alpha: alpha)
    }
    
    static func make (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) -> TTColor
    {
        return NSColor (
            calibratedHue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: alpha)
    }

    static func make (color: Color) -> NSColor
    {
        return NSColor (deviceRed: CGFloat (color.red) / 65535.0,
                        green: CGFloat (color.green) / 65535.0,
                        blue: CGFloat (color.blue) / 65535.0,
                        alpha: 1.0)
    }
    
    static func transparent () -> NSColor {
        return NSColor (calibratedWhite: 0, alpha: 0)
    }
}

extension NSBezierPath {
    func addLine(to: CGPoint)
    {
        self.line (to: to)
    }
}

extension NSView {
    func rectsBeingDrawn() -> [CGRect] {
       var rectsPtr: UnsafePointer<CGRect>? = nil
       var count: Int = 0
       self.getRectsBeingDrawn(&rectsPtr, count: &count)

       return Array(UnsafeBufferPointer(start: rectsPtr, count: count))
     }
    
    public func pending(_ msg: String = "PENDING RECTS") {
        print (msg)
        for x in rectsBeingDrawn() {
            print ("   -> \(x)")
        }
    }
}
extension NSAttributedString {
    func fuzzyHasSelectionBackground (_ ignored: Bool) -> Bool
    {
        return attributeKeys.contains(NSAttributedString.Key.selectionBackgroundColor.rawValue)
    }
}
#endif
