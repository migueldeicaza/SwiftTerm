/*
 * BlockDrawing.swift
 * Programmatic rendering for Unicode block elements (U+2580-U+259F)
 * to eliminate anti-aliasing artifacts at cell boundaries.
 *
 * Based on the approach used by Kitty terminal emulator.
 */

import CoreGraphics
#if os(macOS)
import AppKit
public typealias TTColorBlock = NSColor
#else
import UIKit
public typealias TTColorBlock = UIColor
#endif

public struct BlockDrawing {
    /// Check if character should be drawn programmatically
    public static func isBlockCharacter(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let value = scalar.value
        // Block Elements: U+2580-U+259F
        return value >= 0x2580 && value <= 0x259F
    }

    /// Check if a Unicode scalar is a block character
    public static func isBlockCharacter(_ value: UInt32) -> Bool {
        return value >= 0x2580 && value <= 0x259F
    }

    /// Draw a block character into the given context
    /// - Parameters:
    ///   - value: Unicode scalar value of the character
    ///   - context: CGContext to draw into
    ///   - cellRect: Rectangle representing the cell
    ///   - foregroundColor: Color to use for filling
    public static func draw(
        unicodeValue value: UInt32,
        in context: CGContext,
        cellRect: CGRect,
        foregroundColor: CGColor
    ) {
        context.saveGState()
        context.setShouldAntialias(false)
        context.setFillColor(foregroundColor)

        let width = cellRect.width
        let height = cellRect.height
        let x = cellRect.origin.x
        let y = cellRect.origin.y

        switch value {
        // Full block
        case 0x2588: // █ Full block
            context.fill(cellRect)

        // Half blocks
        case 0x2580: // ▀ Upper half block
            context.fill(CGRect(x: x, y: y + height/2, width: width, height: height/2))

        case 0x2584: // ▄ Lower half block
            context.fill(CGRect(x: x, y: y, width: width, height: height/2))

        case 0x258C: // ▌ Left half block
            context.fill(CGRect(x: x, y: y, width: width/2, height: height))

        case 0x2590: // ▐ Right half block
            context.fill(CGRect(x: x + width/2, y: y, width: width/2, height: height))

        // Vertical eighth blocks (lower)
        case 0x2581: // ▁ Lower 1/8
            context.fill(CGRect(x: x, y: y, width: width, height: height/8))
        case 0x2582: // ▂ Lower 2/8
            context.fill(CGRect(x: x, y: y, width: width, height: height*2/8))
        case 0x2583: // ▃ Lower 3/8
            context.fill(CGRect(x: x, y: y, width: width, height: height*3/8))
        case 0x2585: // ▅ Lower 5/8
            context.fill(CGRect(x: x, y: y, width: width, height: height*5/8))
        case 0x2586: // ▆ Lower 6/8
            context.fill(CGRect(x: x, y: y, width: width, height: height*6/8))
        case 0x2587: // ▇ Lower 7/8
            context.fill(CGRect(x: x, y: y, width: width, height: height*7/8))

        // Upper eighth block
        case 0x2594: // ▔ Upper 1/8
            context.fill(CGRect(x: x, y: y + height*7/8, width: width, height: height/8))

        // Horizontal eighth blocks (left)
        case 0x258F: // ▏ Left 1/8
            context.fill(CGRect(x: x, y: y, width: width/8, height: height))
        case 0x258E: // ▎ Left 2/8
            context.fill(CGRect(x: x, y: y, width: width*2/8, height: height))
        case 0x258D: // ▍ Left 3/8
            context.fill(CGRect(x: x, y: y, width: width*3/8, height: height))
        case 0x258B: // ▋ Left 5/8
            context.fill(CGRect(x: x, y: y, width: width*5/8, height: height))
        case 0x258A: // ▊ Left 6/8
            context.fill(CGRect(x: x, y: y, width: width*6/8, height: height))
        case 0x2589: // ▉ Left 7/8
            context.fill(CGRect(x: x, y: y, width: width*7/8, height: height))

        // Right eighth block
        case 0x2595: // ▕ Right 1/8
            context.fill(CGRect(x: x + width*7/8, y: y, width: width/8, height: height))

        // Shade characters
        case 0x2591: // ░ Light shade (25%)
            drawShade(context: context, rect: cellRect, density: 0.25, color: foregroundColor)
        case 0x2592: // ▒ Medium shade (50%)
            drawShade(context: context, rect: cellRect, density: 0.50, color: foregroundColor)
        case 0x2593: // ▓ Dark shade (75%)
            drawShade(context: context, rect: cellRect, density: 0.75, color: foregroundColor)

        // Quadrant characters
        case 0x2596: // ▖ Lower left
            context.fill(CGRect(x: x, y: y, width: width/2, height: height/2))
        case 0x2597: // ▗ Lower right
            context.fill(CGRect(x: x + width/2, y: y, width: width/2, height: height/2))
        case 0x2598: // ▘ Upper left
            context.fill(CGRect(x: x, y: y + height/2, width: width/2, height: height/2))
        case 0x259D: // ▝ Upper right
            context.fill(CGRect(x: x + width/2, y: y + height/2, width: width/2, height: height/2))

        // Combined quadrants
        case 0x2599: // ▙ Lower left + lower right + upper left
            context.fill(CGRect(x: x, y: y, width: width/2, height: height)) // left column
            context.fill(CGRect(x: x + width/2, y: y, width: width/2, height: height/2)) // lower right
        case 0x259A: // ▚ Upper left + lower right (diagonal)
            context.fill(CGRect(x: x, y: y + height/2, width: width/2, height: height/2))
            context.fill(CGRect(x: x + width/2, y: y, width: width/2, height: height/2))
        case 0x259B: // ▛ Upper left + upper right + lower left
            context.fill(CGRect(x: x, y: y + height/2, width: width, height: height/2)) // top row
            context.fill(CGRect(x: x, y: y, width: width/2, height: height/2)) // lower left
        case 0x259C: // ▜ Upper left + upper right + lower right
            context.fill(CGRect(x: x, y: y + height/2, width: width, height: height/2)) // top row
            context.fill(CGRect(x: x + width/2, y: y, width: width/2, height: height/2)) // lower right
        case 0x259E: // ▞ Upper right + lower left (diagonal)
            context.fill(CGRect(x: x + width/2, y: y + height/2, width: width/2, height: height/2))
            context.fill(CGRect(x: x, y: y, width: width/2, height: height/2))
        case 0x259F: // ▟ Upper right + lower left + lower right
            context.fill(CGRect(x: x + width/2, y: y, width: width/2, height: height)) // right column
            context.fill(CGRect(x: x, y: y, width: width/2, height: height/2)) // lower left

        default:
            break
        }

        context.restoreGState()
    }

    /// Draw a shade pattern (checkerboard-like pattern)
    private static func drawShade(context: CGContext, rect: CGRect, density: CGFloat, color: CGColor) {
        // For shades, we draw a pattern of dots/squares
        // Light = 25%, Medium = 50%, Dark = 75%

        let dotSize: CGFloat = 2
        let cols = Int(ceil(rect.width / dotSize))
        let rows = Int(ceil(rect.height / dotSize))

        context.setFillColor(color)

        for row in 0..<rows {
            for col in 0..<cols {
                let shouldFill: Bool
                if density <= 0.25 {
                    // Light: only every 4th cell in checkerboard
                    shouldFill = (row % 2 == 0) && (col % 2 == 0) && ((row/2 + col/2) % 2 == 0)
                } else if density <= 0.50 {
                    // Medium: standard checkerboard
                    shouldFill = (row + col) % 2 == 0
                } else {
                    // Dark: inverse of light pattern
                    shouldFill = !((row % 2 == 0) && (col % 2 == 0) && ((row/2 + col/2) % 2 == 0))
                }

                if shouldFill {
                    let x = rect.origin.x + CGFloat(col) * dotSize
                    let y = rect.origin.y + CGFloat(row) * dotSize
                    let w = min(dotSize, rect.maxX - x)
                    let h = min(dotSize, rect.maxY - y)
                    context.fill(CGRect(x: x, y: y, width: w, height: h))
                }
            }
        }
    }
}
