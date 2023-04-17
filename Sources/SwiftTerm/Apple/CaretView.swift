//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/16/23.
//

import Foundation
import UIKit
import CoreText

extension CaretView {
    func drawCursor (in context: CGContext) {
        guard let ctline else {
            return
        }
        guard let terminal else {
            return
        }
        let lineDescent = CTFontGetDescent(terminal.fontSet.normal)
        let lineLeading = CTFontGetLeading(terminal.fontSet.normal)
        let yOffset = ceil(lineDescent+lineLeading)
        
        context.setFillColor(TTColor.clear.cgColor)
        context.fill ([bounds])
        
        context.setFillColor(bgColor)
        let region: CGRect
        switch style {
        case .blinkBar, .steadyBar:
            region = CGRect (x: 0, y: 0, width: bounds.width, height: 2)
        case .blinkBlock, .steadyBlock:
            region = bounds
        case .blinkUnderline, .steadyUnderline:
            region = CGRect (x: 0, y: 0, width: bounds.width, height: 2)
        }
        context.fill([region])

        guard style == .steadyBlock || style  == .blinkBlock else {
            return
        }
        context.setFillColor(TTColor.black.cgColor)
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
    }

}
