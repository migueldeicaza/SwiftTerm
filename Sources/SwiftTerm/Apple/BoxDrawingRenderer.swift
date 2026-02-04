#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum LineStyle {
    case none
    case light
    case heavy
    case double
}

struct Lines {
    var up: LineStyle = .none
    var right: LineStyle = .none
    var down: LineStyle = .none
    var left: LineStyle = .none
}

enum Corner {
    case tl
    case tr
    case bl
    case br
}

struct BoxDrawingCanvas {
    let context: CGContext
    let origin: CGPoint
    let cellWidthPx: Int
    let cellHeightPx: Int
    let scale: CGFloat
    let cellSize: CGSize
    let minStrokeThicknessPx: Int

    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        let clampedX0 = max(0, min(cellWidthPx, x0))
        let clampedX1 = max(0, min(cellWidthPx, x1))
        let clampedY0 = max(0, min(cellHeightPx, y0))
        let clampedY1 = max(0, min(cellHeightPx, y1))
        if clampedX1 <= clampedX0 || clampedY1 <= clampedY0 {
            return
        }
        let x = origin.x + CGFloat(clampedX0) / scale
        let y = origin.y + cellSize.height - CGFloat(clampedY1) / scale
        let width = CGFloat(clampedX1 - clampedX0) / scale
        let height = CGFloat(clampedY1 - clampedY0) / scale
        context.fill(CGRect(x: x, y: y, width: width, height: height))
    }

    func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(x) / scale,
                y: origin.y + cellSize.height - CGFloat(y) / scale)
    }

    func line(from start: CGPoint, to end: CGPoint, thicknessPx: Int) {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        context.addPath(path)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        let strokePx = max(thicknessPx, minStrokeThicknessPx)
        context.setLineWidth(CGFloat(strokePx) / scale)
        context.setLineCap(.butt)
        context.strokePath()
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
    }
}

struct BoxDrawingRenderer {
    static let lowerBoundary: Int32 = 0x2500
    static let upperBoundary: Int32 = 0x257F

    static func draw(codePoint: UInt32,
                     in context: CGContext,
                     cellOrigin: CGPoint,
                     cellSize: CGSize,
                     scale: CGFloat,
                     color: TTColor,
                     baseThicknessPx: Int) {
        let cellWidthPx = max(1, Int(round(cellSize.width * scale)))
        let cellHeightPx = max(1, Int(round(cellSize.height * scale)))
        let minStrokePx = max(1, Int(round(scale)))
        let canvas = BoxDrawingCanvas(context: context,
                                      origin: cellOrigin,
                                      cellWidthPx: cellWidthPx,
                                      cellHeightPx: cellHeightPx,
                                      scale: scale,
                                      cellSize: cellSize,
                                      minStrokeThicknessPx: minStrokePx)

        let lightPx = max(1, max(baseThicknessPx, minStrokePx))
        let heavyPx = max(1, lightPx * 2)

        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)

        switch codePoint {
        case 0x2500: linesChar(lines: Lines(up: .none, right: .light, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2501: linesChar(lines: Lines(up: .none, right: .heavy, down: .none, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2502: linesChar(lines: Lines(up: .light, right: .none, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2503: linesChar(lines: Lines(up: .heavy, right: .none, down: .heavy, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2504: dashHorizontal(count: 3, thicknessPx: lightPx, desiredGapPx: max(4, lightPx), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2505: dashHorizontal(count: 3, thicknessPx: heavyPx, desiredGapPx: max(4, lightPx), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2506: dashVertical(count: 3, thicknessPx: lightPx, desiredGapPx: max(4, lightPx), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2507: dashVertical(count: 3, thicknessPx: heavyPx, desiredGapPx: max(4, lightPx), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2508: dashHorizontal(count: 4, thicknessPx: lightPx, desiredGapPx: max(4, lightPx), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2509: dashHorizontal(count: 4, thicknessPx: heavyPx, desiredGapPx: max(4, lightPx), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x250a: dashVertical(count: 4, thicknessPx: lightPx, desiredGapPx: max(4, lightPx), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x250b: dashVertical(count: 4, thicknessPx: heavyPx, desiredGapPx: max(4, lightPx), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x250c: linesChar(lines: Lines(up: .none, right: .light, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x250d: linesChar(lines: Lines(up: .none, right: .heavy, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x250e: linesChar(lines: Lines(up: .none, right: .light, down: .heavy, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x250f: linesChar(lines: Lines(up: .none, right: .heavy, down: .heavy, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2510: linesChar(lines: Lines(up: .none, right: .none, down: .light, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2511: linesChar(lines: Lines(up: .none, right: .none, down: .light, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2512: linesChar(lines: Lines(up: .none, right: .none, down: .heavy, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2513: linesChar(lines: Lines(up: .none, right: .none, down: .heavy, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2514: linesChar(lines: Lines(up: .light, right: .light, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2515: linesChar(lines: Lines(up: .light, right: .heavy, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2516: linesChar(lines: Lines(up: .heavy, right: .light, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2517: linesChar(lines: Lines(up: .heavy, right: .heavy, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2518: linesChar(lines: Lines(up: .light, right: .none, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2519: linesChar(lines: Lines(up: .light, right: .none, down: .none, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x251a: linesChar(lines: Lines(up: .heavy, right: .none, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x251b: linesChar(lines: Lines(up: .heavy, right: .none, down: .none, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x251c: linesChar(lines: Lines(up: .light, right: .light, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x251d: linesChar(lines: Lines(up: .light, right: .heavy, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x251e: linesChar(lines: Lines(up: .heavy, right: .light, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x251f: linesChar(lines: Lines(up: .light, right: .light, down: .heavy, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2520: linesChar(lines: Lines(up: .heavy, right: .light, down: .heavy, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2521: linesChar(lines: Lines(up: .heavy, right: .heavy, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2522: linesChar(lines: Lines(up: .light, right: .heavy, down: .heavy, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2523: linesChar(lines: Lines(up: .heavy, right: .heavy, down: .heavy, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2524: linesChar(lines: Lines(up: .light, right: .none, down: .light, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2525: linesChar(lines: Lines(up: .light, right: .none, down: .light, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2526: linesChar(lines: Lines(up: .heavy, right: .none, down: .light, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2527: linesChar(lines: Lines(up: .light, right: .none, down: .heavy, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2528: linesChar(lines: Lines(up: .heavy, right: .none, down: .heavy, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2529: linesChar(lines: Lines(up: .heavy, right: .none, down: .light, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x252a: linesChar(lines: Lines(up: .light, right: .none, down: .heavy, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x252b: linesChar(lines: Lines(up: .heavy, right: .none, down: .heavy, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x252c: linesChar(lines: Lines(up: .none, right: .light, down: .light, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x252d: linesChar(lines: Lines(up: .none, right: .light, down: .light, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x252e: linesChar(lines: Lines(up: .none, right: .heavy, down: .light, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x252f: linesChar(lines: Lines(up: .none, right: .heavy, down: .light, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2530: linesChar(lines: Lines(up: .none, right: .light, down: .heavy, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2531: linesChar(lines: Lines(up: .none, right: .light, down: .heavy, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2532: linesChar(lines: Lines(up: .none, right: .heavy, down: .heavy, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2533: linesChar(lines: Lines(up: .none, right: .heavy, down: .heavy, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2534: linesChar(lines: Lines(up: .light, right: .light, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2535: linesChar(lines: Lines(up: .light, right: .light, down: .none, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2536: linesChar(lines: Lines(up: .light, right: .heavy, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2537: linesChar(lines: Lines(up: .light, right: .heavy, down: .none, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2538: linesChar(lines: Lines(up: .heavy, right: .light, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2539: linesChar(lines: Lines(up: .heavy, right: .light, down: .none, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x253a: linesChar(lines: Lines(up: .heavy, right: .heavy, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x253b: linesChar(lines: Lines(up: .heavy, right: .heavy, down: .none, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x253c: linesChar(lines: Lines(up: .light, right: .light, down: .light, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x253d: linesChar(lines: Lines(up: .light, right: .light, down: .light, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x253e: linesChar(lines: Lines(up: .light, right: .heavy, down: .light, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x253f: linesChar(lines: Lines(up: .light, right: .heavy, down: .light, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2540: linesChar(lines: Lines(up: .heavy, right: .light, down: .light, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2541: linesChar(lines: Lines(up: .light, right: .light, down: .heavy, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2542: linesChar(lines: Lines(up: .heavy, right: .light, down: .heavy, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2543: linesChar(lines: Lines(up: .heavy, right: .light, down: .light, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2544: linesChar(lines: Lines(up: .heavy, right: .heavy, down: .light, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2545: linesChar(lines: Lines(up: .light, right: .light, down: .heavy, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2546: linesChar(lines: Lines(up: .light, right: .heavy, down: .heavy, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2547: linesChar(lines: Lines(up: .heavy, right: .heavy, down: .light, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2548: linesChar(lines: Lines(up: .light, right: .heavy, down: .heavy, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2549: linesChar(lines: Lines(up: .heavy, right: .light, down: .heavy, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x254a: linesChar(lines: Lines(up: .heavy, right: .heavy, down: .heavy, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x254b: linesChar(lines: Lines(up: .heavy, right: .heavy, down: .heavy, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x254c: dashHorizontal(count: 2, thicknessPx: lightPx, desiredGapPx: lightPx, canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x254d: dashHorizontal(count: 2, thicknessPx: heavyPx, desiredGapPx: heavyPx, canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x254e: dashVertical(count: 2, thicknessPx: lightPx, desiredGapPx: heavyPx, canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x254f: dashVertical(count: 2, thicknessPx: heavyPx, desiredGapPx: heavyPx, canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2550: linesChar(lines: Lines(up: .none, right: .double, down: .none, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2551: linesChar(lines: Lines(up: .double, right: .none, down: .double, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2552: linesChar(lines: Lines(up: .none, right: .double, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2553: linesChar(lines: Lines(up: .none, right: .light, down: .double, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2554: linesChar(lines: Lines(up: .none, right: .double, down: .double, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2555: linesChar(lines: Lines(up: .none, right: .none, down: .light, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2556: linesChar(lines: Lines(up: .none, right: .none, down: .double, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2557: linesChar(lines: Lines(up: .none, right: .none, down: .double, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2558: linesChar(lines: Lines(up: .light, right: .double, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2559: linesChar(lines: Lines(up: .double, right: .light, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x255a: linesChar(lines: Lines(up: .double, right: .double, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x255b: linesChar(lines: Lines(up: .light, right: .none, down: .none, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x255c: linesChar(lines: Lines(up: .double, right: .none, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x255d: linesChar(lines: Lines(up: .double, right: .none, down: .none, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x255e: linesChar(lines: Lines(up: .light, right: .double, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x255f: linesChar(lines: Lines(up: .double, right: .light, down: .double, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2560: linesChar(lines: Lines(up: .double, right: .double, down: .double, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2561: linesChar(lines: Lines(up: .light, right: .none, down: .light, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2562: linesChar(lines: Lines(up: .double, right: .none, down: .double, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2563: linesChar(lines: Lines(up: .double, right: .none, down: .double, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2564: linesChar(lines: Lines(up: .none, right: .double, down: .light, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2565: linesChar(lines: Lines(up: .none, right: .light, down: .double, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2566: linesChar(lines: Lines(up: .none, right: .double, down: .double, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2567: linesChar(lines: Lines(up: .light, right: .double, down: .none, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2568: linesChar(lines: Lines(up: .double, right: .light, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2569: linesChar(lines: Lines(up: .double, right: .double, down: .none, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x256a: linesChar(lines: Lines(up: .light, right: .double, down: .light, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x256b: linesChar(lines: Lines(up: .double, right: .light, down: .double, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x256c: linesChar(lines: Lines(up: .double, right: .double, down: .double, left: .double), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x256d: arc(corner: .br, thicknessPx: lightPx, canvas: canvas)
        case 0x256e: arc(corner: .bl, thicknessPx: lightPx, canvas: canvas)
        case 0x256f: arc(corner: .tl, thicknessPx: lightPx, canvas: canvas)
        case 0x2570: arc(corner: .tr, thicknessPx: lightPx, canvas: canvas)
        case 0x2571: lightDiagonalUpperRightToLowerLeft(thicknessPx: lightPx, canvas: canvas)
        case 0x2572: lightDiagonalUpperLeftToLowerRight(thicknessPx: lightPx, canvas: canvas)
        case 0x2573: lightDiagonalCross(thicknessPx: lightPx, canvas: canvas)
        case 0x2574: linesChar(lines: Lines(up: .none, right: .none, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2575: linesChar(lines: Lines(up: .light, right: .none, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2576: linesChar(lines: Lines(up: .none, right: .light, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2577: linesChar(lines: Lines(up: .none, right: .none, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2578: linesChar(lines: Lines(up: .none, right: .none, down: .none, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x2579: linesChar(lines: Lines(up: .heavy, right: .none, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x257a: linesChar(lines: Lines(up: .none, right: .heavy, down: .none, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x257b: linesChar(lines: Lines(up: .none, right: .none, down: .heavy, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x257c: linesChar(lines: Lines(up: .none, right: .heavy, down: .none, left: .light), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x257d: linesChar(lines: Lines(up: .light, right: .none, down: .heavy, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x257e: linesChar(lines: Lines(up: .none, right: .light, down: .none, left: .heavy), canvas: canvas, baseThicknessPx: baseThicknessPx)
        case 0x257f: linesChar(lines: Lines(up: .heavy, right: .none, down: .light, left: .none), canvas: canvas, baseThicknessPx: baseThicknessPx)
        default:
            break
        }
    }
}

private func subClamped(_ value: Int, _ subtract: Int) -> Int {
    max(0, value - subtract)
}

private func addClamped(_ value: Int, _ add: Int, _ maxValue: Int) -> Int {
    min(maxValue, value + add)
}

private func linesChar(lines: Lines, canvas: BoxDrawingCanvas, baseThicknessPx: Int) {
    let lightPx = max(1, max(baseThicknessPx, canvas.minStrokeThicknessPx))
    let heavyPx = max(1, lightPx * 2)

    let hLightTop = subClamped(canvas.cellHeightPx, lightPx) / 2
    let hLightBottom = addClamped(hLightTop, lightPx, canvas.cellHeightPx)

    let hHeavyTop = subClamped(canvas.cellHeightPx, heavyPx) / 2
    let hHeavyBottom = addClamped(hHeavyTop, heavyPx, canvas.cellHeightPx)

    let hDoubleTop = subClamped(hLightTop, lightPx)
    let hDoubleBottom = addClamped(hLightBottom, lightPx, canvas.cellHeightPx)

    let vLightLeft = subClamped(canvas.cellWidthPx, lightPx) / 2
    let vLightRight = addClamped(vLightLeft, lightPx, canvas.cellWidthPx)

    let vHeavyLeft = subClamped(canvas.cellWidthPx, heavyPx) / 2
    let vHeavyRight = addClamped(vHeavyLeft, heavyPx, canvas.cellWidthPx)

    let vDoubleLeft = subClamped(vLightLeft, lightPx)
    let vDoubleRight = addClamped(vLightRight, lightPx, canvas.cellWidthPx)

    let upBottom: Int
    if lines.left == .heavy || lines.right == .heavy {
        upBottom = hHeavyBottom
    } else if lines.left != lines.right || lines.down == lines.up {
        if lines.left == .double || lines.right == .double {
            upBottom = hDoubleBottom
        } else {
            upBottom = hLightBottom
        }
    } else if lines.left == .none && lines.right == .none {
        upBottom = hLightBottom
    } else {
        upBottom = hLightTop
    }

    let downTop: Int
    if lines.left == .heavy || lines.right == .heavy {
        downTop = hHeavyTop
    } else if lines.left != lines.right || lines.up == lines.down {
        if lines.left == .double || lines.right == .double {
            downTop = hDoubleTop
        } else {
            downTop = hLightTop
        }
    } else if lines.left == .none && lines.right == .none {
        downTop = hLightTop
    } else {
        downTop = hLightBottom
    }

    let leftRight: Int
    if lines.up == .heavy || lines.down == .heavy {
        leftRight = vHeavyRight
    } else if lines.up != lines.down || lines.left == lines.right {
        if lines.up == .double || lines.down == .double {
            leftRight = vDoubleRight
        } else {
            leftRight = vLightRight
        }
    } else if lines.up == .none && lines.down == .none {
        leftRight = vLightRight
    } else {
        leftRight = vLightLeft
    }

    let rightLeft: Int
    if lines.up == .heavy || lines.down == .heavy {
        rightLeft = vHeavyLeft
    } else if lines.up != lines.down || lines.right == lines.left {
        if lines.up == .double || lines.down == .double {
            rightLeft = vDoubleLeft
        } else {
            rightLeft = vLightLeft
        }
    } else if lines.up == .none && lines.down == .none {
        rightLeft = vLightLeft
    } else {
        rightLeft = vLightRight
    }

    switch lines.up {
    case .none:
        break
    case .light:
        canvas.box(vLightLeft, 0, vLightRight, upBottom)
    case .heavy:
        canvas.box(vHeavyLeft, 0, vHeavyRight, upBottom)
    case .double:
        let leftBottom = lines.left == .double ? hLightTop : upBottom
        let rightBottom = lines.right == .double ? hLightTop : upBottom
        canvas.box(vDoubleLeft, 0, vLightLeft, leftBottom)
        canvas.box(vLightRight, 0, vDoubleRight, rightBottom)
    }

    switch lines.right {
    case .none:
        break
    case .light:
        canvas.box(rightLeft, hLightTop, canvas.cellWidthPx, hLightBottom)
    case .heavy:
        canvas.box(rightLeft, hHeavyTop, canvas.cellWidthPx, hHeavyBottom)
    case .double:
        let topLeft = lines.up == .double ? vLightRight : rightLeft
        let bottomLeft = lines.down == .double ? vLightRight : rightLeft
        canvas.box(topLeft, hDoubleTop, canvas.cellWidthPx, hLightTop)
        canvas.box(bottomLeft, hLightBottom, canvas.cellWidthPx, hDoubleBottom)
    }

    switch lines.down {
    case .none:
        break
    case .light:
        canvas.box(vLightLeft, downTop, vLightRight, canvas.cellHeightPx)
    case .heavy:
        canvas.box(vHeavyLeft, downTop, vHeavyRight, canvas.cellHeightPx)
    case .double:
        let leftTop = lines.left == .double ? hLightBottom : downTop
        let rightTop = lines.right == .double ? hLightBottom : downTop
        canvas.box(vDoubleLeft, leftTop, vLightLeft, canvas.cellHeightPx)
        canvas.box(vLightRight, rightTop, vDoubleRight, canvas.cellHeightPx)
    }

    switch lines.left {
    case .none:
        break
    case .light:
        canvas.box(0, hLightTop, leftRight, hLightBottom)
    case .heavy:
        canvas.box(0, hHeavyTop, leftRight, hHeavyBottom)
    case .double:
        let topRight = lines.up == .double ? vLightLeft : leftRight
        let bottomRight = lines.down == .double ? vLightLeft : leftRight
        canvas.box(0, hDoubleTop, topRight, hLightTop)
        canvas.box(0, hLightBottom, bottomRight, hDoubleBottom)
    }
}

private func hlineMiddle(canvas: BoxDrawingCanvas, thicknessPx: Int) {
    let y = subClamped(canvas.cellHeightPx, thicknessPx) / 2
    hline(canvas: canvas, x1: 0, x2: canvas.cellWidthPx, y: y, thicknessPx: thicknessPx)
}

private func vlineMiddle(canvas: BoxDrawingCanvas, thicknessPx: Int) {
    let x = subClamped(canvas.cellWidthPx, thicknessPx) / 2
    vline(canvas: canvas, y1: 0, y2: canvas.cellHeightPx, x: x, thicknessPx: thicknessPx)
}

private func hline(canvas: BoxDrawingCanvas, x1: Int, x2: Int, y: Int, thicknessPx: Int) {
    canvas.box(x1, y, x2, y + thicknessPx)
}

private func vline(canvas: BoxDrawingCanvas, y1: Int, y2: Int, x: Int, thicknessPx: Int) {
    canvas.box(x, y1, x + thicknessPx, y2)
}

private func dashHorizontal(count: Int, thicknessPx: Int, desiredGapPx: Int, canvas: BoxDrawingCanvas, baseThicknessPx: Int) {
    guard count >= 2 && count <= 4 else {
        return
    }
    let gapCount = count
    if canvas.cellWidthPx < count + gapCount {
        hlineMiddle(canvas: canvas, thicknessPx: max(1, baseThicknessPx))
        return
    }

    let gapWidth = min(desiredGapPx, canvas.cellWidthPx / (2 * count))
    let totalGapWidth = gapCount * gapWidth
    let totalDashWidth = canvas.cellWidthPx - totalGapWidth
    let dashWidth = totalDashWidth / count
    let remaining = totalDashWidth % count

    let y = subClamped(canvas.cellHeightPx, thicknessPx) / 2
    var x = gapWidth / 2
    var extra = remaining

    for _ in 0..<count {
        var x1 = x + dashWidth
        if extra > 0 {
            extra -= 1
            x1 += 1
        }
        hline(canvas: canvas, x1: x, x2: x1, y: y, thicknessPx: thicknessPx)
        x = x1 + gapWidth
    }
}

private func dashVertical(count: Int, thicknessPx: Int, desiredGapPx: Int, canvas: BoxDrawingCanvas, baseThicknessPx: Int) {
    guard count >= 2 && count <= 4 else {
        return
    }
    let gapCount = count
    if canvas.cellHeightPx < count + gapCount {
        vlineMiddle(canvas: canvas, thicknessPx: max(1, baseThicknessPx))
        return
    }

    let gapHeight = min(desiredGapPx, canvas.cellHeightPx / (2 * count))
    let totalGapHeight = gapCount * gapHeight
    let totalDashHeight = canvas.cellHeightPx - totalGapHeight
    let dashHeight = totalDashHeight / count
    let remaining = totalDashHeight % count

    let x = subClamped(canvas.cellWidthPx, thicknessPx) / 2
    var y = 0
    var extra = remaining

    for _ in 0..<count {
        var y1 = y + dashHeight
        if extra > 0 {
            extra -= 1
            y1 += 1
        }
        vline(canvas: canvas, y1: y, y2: y1, x: x, thicknessPx: thicknessPx)
        y = y1 + gapHeight
    }
}

private func diagonalStrokePx(_ thicknessPx: Int, minStroke: Int) -> Int {
    let base = max(thicknessPx, minStroke)
    if base <= 1 {
        return base
    }
    return base + 1
}

private func lightDiagonalUpperRightToLowerLeft(thicknessPx: Int, canvas: BoxDrawingCanvas) {
    let width = Double(canvas.cellWidthPx)
    let height = Double(canvas.cellHeightPx)
    let slopeX = min(1.0, width / height)
    let slopeY = min(1.0, height / width)
    let strokePx = diagonalStrokePx(thicknessPx, minStroke: canvas.minStrokeThicknessPx)

    let p0 = canvas.point(x: width + 0.5 * slopeX, y: -0.5 * slopeY)
    let p1 = canvas.point(x: -0.5 * slopeX, y: height + 0.5 * slopeY)
    canvas.line(from: p0, to: p1, thicknessPx: strokePx)
}

private func lightDiagonalUpperLeftToLowerRight(thicknessPx: Int, canvas: BoxDrawingCanvas) {
    let width = Double(canvas.cellWidthPx)
    let height = Double(canvas.cellHeightPx)
    let slopeX = min(1.0, width / height)
    let slopeY = min(1.0, height / width)
    let strokePx = diagonalStrokePx(thicknessPx, minStroke: canvas.minStrokeThicknessPx)

    let p0 = canvas.point(x: -0.5 * slopeX, y: -0.5 * slopeY)
    let p1 = canvas.point(x: width + 0.5 * slopeX, y: height + 0.5 * slopeY)
    canvas.line(from: p0, to: p1, thicknessPx: strokePx)
}

private func lightDiagonalCross(thicknessPx: Int, canvas: BoxDrawingCanvas) {
    lightDiagonalUpperRightToLowerLeft(thicknessPx: thicknessPx, canvas: canvas)
    lightDiagonalUpperLeftToLowerRight(thicknessPx: thicknessPx, canvas: canvas)
}

private func arc(corner: Corner, thicknessPx: Int, canvas: BoxDrawingCanvas) {
    let thickPx = max(1, thicknessPx)
    let vlineX = subClamped(canvas.cellWidthPx, thickPx) / 2
    let hlineY = subClamped(canvas.cellHeightPx, thickPx) / 2
    let centerX = Double(vlineX) + (Double(thickPx) / 2.0)
    let centerY = Double(hlineY) + (Double(thickPx) / 2.0)

    let arcThicknessPx = Double(thickPx)
    let halfThick = arcThicknessPx / 2.0
    let minDim = Double(min(canvas.cellWidthPx, canvas.cellHeightPx))
    let radiusScale = 0.30
    let maxCenterRadius = max(0.0, (minDim / 2.0) - halfThick)
    let rCenter = min(maxCenterRadius, minDim * radiusScale)
    let rxCenter = rCenter
    let ryCenter = rCenter
    let rxOuter = rxCenter + halfThick
    let ryOuter = ryCenter + halfThick
    let rxInner = max(0.0, rxCenter - halfThick)
    let ryInner = max(0.0, ryCenter - halfThick)

    let stemTop = min(canvas.cellHeightPx, max(0, Int(ceil(centerY - ryCenter))))
    let stemBottom = min(canvas.cellHeightPx, max(0, Int(floor(centerY + ryCenter))))
    let stemLeft = min(canvas.cellWidthPx, max(0, Int(ceil(centerX - rxCenter))))
    let stemRight = min(canvas.cellWidthPx, max(0, Int(floor(centerX + rxCenter))))

    switch corner {
    case .tl:
        vline(canvas: canvas, y1: 0, y2: stemTop, x: vlineX, thicknessPx: thickPx)
        hline(canvas: canvas, x1: 0, x2: stemLeft, y: hlineY, thicknessPx: thickPx)
    case .tr:
        vline(canvas: canvas, y1: 0, y2: stemTop, x: vlineX, thicknessPx: thickPx)
        hline(canvas: canvas, x1: stemRight, x2: canvas.cellWidthPx, y: hlineY, thicknessPx: thickPx)
    case .bl:
        vline(canvas: canvas, y1: stemBottom, y2: canvas.cellHeightPx, x: vlineX, thicknessPx: thickPx)
        hline(canvas: canvas, x1: 0, x2: stemLeft, y: hlineY, thicknessPx: thickPx)
    case .br:
        vline(canvas: canvas, y1: stemBottom, y2: canvas.cellHeightPx, x: vlineX, thicknessPx: thickPx)
        hline(canvas: canvas, x1: stemRight, x2: canvas.cellWidthPx, y: hlineY, thicknessPx: thickPx)
    }

    let arcCenterX: Double
    let arcCenterY: Double
    let arcCorner: Corner
    switch corner {
    case .br:
        arcCenterX = centerX + rxCenter
        arcCenterY = centerY + ryCenter
        arcCorner = .tl
    case .bl:
        arcCenterX = centerX - rxCenter
        arcCenterY = centerY + ryCenter
        arcCorner = .tr
    case .tl:
        arcCenterX = centerX - rxCenter
        arcCenterY = centerY - ryCenter
        arcCorner = .br
    case .tr:
        arcCenterX = centerX + rxCenter
        arcCenterY = centerY - ryCenter
        arcCorner = .bl
    }

    fillArcQuarter(corner: arcCorner,
                   centerX: arcCenterX,
                   centerY: arcCenterY,
                   rxOuter: rxOuter,
                   ryOuter: ryOuter,
                   rxInner: rxInner,
                   ryInner: ryInner,
                   canvas: canvas)
}

private func fillArcQuarter(corner: Corner,
                            centerX: Double,
                            centerY: Double,
                            rxOuter: Double,
                            ryOuter: Double,
                            rxInner: Double,
                            ryInner: Double,
                            canvas: BoxDrawingCanvas) {
    guard rxOuter > 0.0, ryOuter > 0.0 else {
        return
    }
    let context = canvas.context
    context.saveGState()
    context.translateBy(x: canvas.origin.x, y: canvas.origin.y + canvas.cellSize.height)
    context.scaleBy(x: 1.0 / canvas.scale, y: -1.0 / canvas.scale)
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    let maxX = Double(canvas.cellWidthPx)
    let maxY = Double(canvas.cellHeightPx)
    let clipRect: CGRect
    switch corner {
    case .tl:
        clipRect = CGRect(x: 0, y: 0, width: centerX, height: centerY)
    case .tr:
        clipRect = CGRect(x: centerX, y: 0, width: max(0.0, maxX - centerX), height: centerY)
    case .bl:
        clipRect = CGRect(x: 0, y: centerY, width: centerX, height: max(0.0, maxY - centerY))
    case .br:
        clipRect = CGRect(x: centerX, y: centerY, width: max(0.0, maxX - centerX), height: max(0.0, maxY - centerY))
    }
    context.clip(to: clipRect)

    let outerRect = CGRect(x: centerX - rxOuter,
                           y: centerY - ryOuter,
                           width: rxOuter * 2.0,
                           height: ryOuter * 2.0)
    let path = CGMutablePath()
    path.addEllipse(in: outerRect)
    if rxInner > 0.0 && ryInner > 0.0 {
        let innerRect = CGRect(x: centerX - rxInner,
                               y: centerY - ryInner,
                               width: rxInner * 2.0,
                               height: ryInner * 2.0)
        path.addEllipse(in: innerRect)
        context.addPath(path)
        context.drawPath(using: .eoFill)
    } else {
        context.addPath(path)
        context.fillPath()
    }
    context.restoreGState()
}

struct BoxDrawingRenderItem {
    let column: Int
    let columnWidth: Int
    let codePoint: UInt32
    let foregroundColor: TTColor
}
#endif
