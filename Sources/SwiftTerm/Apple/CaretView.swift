//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/16/23.
//

import Foundation
import CoreText

extension CaretView {
    func drawCursor (in context: CGContext, hasFocus: Bool) {
        guard let ctline else {
            return
        }
        guard let terminal else {
            return
        }
        context.saveGState()
        context.clip(to: [bounds])
        context.setFillColor(TTColor.clear.cgColor)
        context.fill ([bounds])
        let cursorColor = renderCursorColor
        
        if !hasFocus {
            context.setStrokeColor(cursorColor.cgColor)
            context.setLineWidth(3)
            context.stroke(bounds)
            return
        }
        context.setFillColor(cursorColor.cgColor)
        let region: CGRect
        switch style {
        case .blinkBar, .steadyBar:
            region = CGRect (x: 0, y: 0, width: 2, height: bounds.height)
        case .blinkBlock, .steadyBlock:
            region = bounds
        case .blinkUnderline, .steadyUnderline:
            region = CGRect (x: 0, y: 0, width: bounds.width, height: 2)
        }
        context.fill([region])

        let normalFont = renderNormalFont ?? terminal.fontSet.normal
        let lineDescent = CTFontGetDescent(normalFont)
        let lineLeading = CTFontGetLeading(normalFont)
        let yOffset = ceil(lineDescent+lineLeading)
        
        guard style == .steadyBlock || style  == .blinkBlock else {
            return
        }
        let caretFG = renderTextColor
        context.setFillColor(caretFG.cgColor)
        if let powerlineCodePoint,
           PowerlineRenderer.shouldRender(codePoint: powerlineCodePoint,
                                          customGlyphsEnabled: renderCustomBlockGlyphs) {
            PowerlineRenderer.draw(codePoint: powerlineCodePoint,
                                   in: context,
                                   cellRect: bounds,
                                   scaleX: terminal.backingScaleFactor(),
                                   scaleY: terminal.backingScaleFactor(),
                                   color: caretFG.cgColor)
            context.restoreGState()
            return
        }
        for run in CTLineGetGlyphRuns(ctline) as? [CTRun] ?? [] {
            let runGlyphsCount = CTRunGetGlyphCount(run)
            let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            let runFont = (runAttributes[.font] as? TTFont) ?? normalFont
            let ctRunFont = runFont as CTFont

            let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { (bufferPointer, count) in
                CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                count = runGlyphsCount
            }

            // Center full-width (CJK) glyphs within the caret the same way as the
            // surrounding text so the character doesn't shift under the cursor,
            // and scale an oversized glyph down to match (drawTerminalContents
            // does the same via CTFontCreateCopyWithAttributes). The caret bounds
            // span `glyphColumnWidth` cells, so the centered glyph isn't clipped.
            let glyphPolicy = runAttributes[SwiftTermGlyphPolicyKey] as? TerminalGlyphPlacementPolicy
            let fits = runGlyphs.map { glyph in
                if let glyphPolicy {
                    return terminal.glyphSlotFit(font: ctRunFont, glyph: glyph,
                                                 columnWidth: glyphColumnWidth,
                                                 policy: glyphPolicy)
                }
                return terminal.glyphSlotFit(font: ctRunFont, glyph: glyph, columnWidth: glyphColumnWidth)
            }
            var positions = fits.map { CGPoint(x: $0.dx, y: yOffset + $0.dy) }
            if fits.contains(where: { $0.scaleX != 1 || $0.scaleY != 1 }) {
                for i in 0..<runGlyphsCount {
                    let fit = fits[i]
                    var g = runGlyphs[i]
                    var p = positions[i]
                    if fit.isUniform {
                        let s = fit.scale
                        let drawFont: CTFont = s == 1
                            ? ctRunFont
                            : CTFontCreateCopyWithAttributes(ctRunFont, CTFontGetSize(ctRunFont) * s, nil, nil)
                        CTFontDrawGlyphs(drawFont, &g, &p, 1, context)
                    } else {
                        context.saveGState()
                        context.translateBy(x: p.x, y: p.y)
                        context.scaleBy(x: fit.scaleX, y: fit.scaleY)
                        var origin = CGPoint.zero
                        CTFontDrawGlyphs(ctRunFont, &g, &origin, 1, context)
                        context.restoreGState()
                    }
                }
            } else {
                CTFontDrawGlyphs(runFont, runGlyphs, &positions, positions.count, context)
            }
        }
        context.restoreGState()
    }
}
