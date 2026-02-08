#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum BlockAlpha: CGFloat {
    case full = 1.0
    case dark = 0.75
    case medium = 0.5
    case light = 0.25
}

struct BlockElementRect {
    let x0: UInt8
    let x1: UInt8
    let y0: UInt8
    let y1: UInt8
    let alpha: BlockAlpha

    func rect(in cellOrigin: CGPoint, xEighth: CGFloat, yEighth: CGFloat, cellHeight: CGFloat) -> CGRect {
        let left = cellOrigin.x + CGFloat(x0) * xEighth
        let right = cellOrigin.x + CGFloat(x1) * xEighth
        let top = cellOrigin.y + cellHeight - CGFloat(y0) * yEighth
        let bottom = cellOrigin.y + cellHeight - CGFloat(y1) * yEighth
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

struct BlockElementMapping {
    static func rects(for codePoint: UInt32) -> [BlockElementRect]? {
        return mapping[codePoint]
    }

    private static let fullBlock = BlockElementRect(x0: 0, x1: 8, y0: 0, y1: 8, alpha: .full)
    private static let quadrantUL = BlockElementRect(x0: 0, x1: 4, y0: 0, y1: 4, alpha: .full)
    private static let quadrantUR = BlockElementRect(x0: 4, x1: 8, y0: 0, y1: 4, alpha: .full)
    private static let quadrantLL = BlockElementRect(x0: 0, x1: 4, y0: 4, y1: 8, alpha: .full)
    private static let quadrantLR = BlockElementRect(x0: 4, x1: 8, y0: 4, y1: 8, alpha: .full)

    private static func upperBlock(_ num: UInt8) -> [BlockElementRect] {
        [BlockElementRect(x0: 0, x1: 8, y0: 0, y1: num, alpha: .full)]
    }

    private static func lowerBlock(_ num: UInt8) -> [BlockElementRect] {
        [BlockElementRect(x0: 0, x1: 8, y0: 8 - num, y1: 8, alpha: .full)]
    }

    private static func leftBlock(_ num: UInt8) -> [BlockElementRect] {
        [BlockElementRect(x0: 0, x1: num, y0: 0, y1: 8, alpha: .full)]
    }

    private static func rightBlock(_ num: UInt8) -> [BlockElementRect] {
        [BlockElementRect(x0: 8 - num, x1: 8, y0: 0, y1: 8, alpha: .full)]
    }

    static let lowerBoundary = 0x2580
    static let upperBoundary = 0x259F
    private static let mapping: [UInt32: [BlockElementRect]] = [
        0x2580: upperBlock(4),
        0x2581: lowerBlock(1),
        0x2582: lowerBlock(2),
        0x2583: lowerBlock(3),
        0x2584: lowerBlock(4),
        0x2585: lowerBlock(5),
        0x2586: lowerBlock(6),
        0x2587: lowerBlock(7),
        0x2588: [fullBlock],
        0x2589: leftBlock(7),
        0x258A: leftBlock(6),
        0x258B: leftBlock(5),
        0x258C: leftBlock(4),
        0x258D: leftBlock(3),
        0x258E: leftBlock(2),
        0x258F: leftBlock(1),
        0x2590: rightBlock(4),
        0x2591: [BlockElementRect(x0: 0, x1: 8, y0: 0, y1: 8, alpha: .light)],
        0x2592: [BlockElementRect(x0: 0, x1: 8, y0: 0, y1: 8, alpha: .medium)],
        0x2593: [BlockElementRect(x0: 0, x1: 8, y0: 0, y1: 8, alpha: .dark)],
        0x2594: upperBlock(1),
        0x2595: rightBlock(1),
        0x2596: [quadrantLL],
        0x2597: [quadrantLR],
        0x2598: [quadrantUL],
        0x2599: [quadrantUL, quadrantLL, quadrantLR],
        0x259A: [quadrantUL, quadrantLR],
        0x259B: [quadrantUL, quadrantUR, quadrantLL],
        0x259C: [quadrantUL, quadrantUR, quadrantLR],
        0x259D: [quadrantUR],
        0x259E: [quadrantUR, quadrantLL],
        0x259F: [quadrantUR, quadrantLL, quadrantLR]
    ]
}

struct BlockElementRenderItem {
    let column: Int
    let columnWidth: Int
    let rects: [BlockElementRect]
    let foregroundColor: TTColor
}
#endif
