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
        
        if !hasFocus {
            context.setStrokeColor(bgColor)
            context.setLineWidth(3)
            context.stroke(bounds)
            return
        }
        context.setFillColor(bgColor)
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

        let lineDescent = CTFontGetDescent(terminal.fontSet.normal)
        let lineLeading = CTFontGetLeading(terminal.fontSet.normal)
        let yOffset = ceil(lineDescent+lineLeading)
        
        guard style == .steadyBlock || style  == .blinkBlock else {
            return
        }
        let caretFG = caretTextColor ?? terminal.nativeForegroundColor
        context.setFillColor(caretFG.cgColor)
        for run in CTLineGetGlyphRuns(ctline) as? [CTRun] ?? [] {
            let runGlyphsCount = CTRunGetGlyphCount(run)
            let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            let runFont = runAttributes[.font] as! TTFont

            let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { (bufferPointer, count) in
                CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                count = runGlyphsCount
            }

            var positions = runGlyphs.enumerated().map { (i: Int, glyph: CGGlyph) -> CGPoint in
                CGPoint(x: 0, y: yOffset)
            }
            CTFontDrawGlyphs(runFont, runGlyphs, &positions, positions.count, context)
        }
        context.restoreGState()
    }
}
