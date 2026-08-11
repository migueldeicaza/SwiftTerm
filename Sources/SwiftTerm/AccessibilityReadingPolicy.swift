//
//  AccessibilityReadingPolicy.swift
//  SwiftTerm
//
//  Small, platform-neutral calculations shared by the UIKit reading-content
//  adapter. Keeping these independent of UIView makes the boundary cases
//  testable on every SwiftPM host.
//

import Foundation

enum AccessibilityReadingPolicy {
    static func lineNumber(
        atContentY contentY: Double,
        lineHeight: Double,
        lineCount: Int
    ) -> Int? {
        guard contentY >= 0, lineHeight > 0, lineCount > 0 else {
            return nil
        }
        let line = Int(floor(contentY / lineHeight))
        return line < lineCount ? line : nil
    }

    static func visibleLines(
        contentOffsetY: Double,
        viewportHeight: Double,
        lineHeight: Double,
        lineCount: Int
    ) -> ClosedRange<Int>? {
        guard viewportHeight > 0, lineHeight > 0, lineCount > 0 else {
            return nil
        }

        let maximumOffset = max(0, Double(lineCount) * lineHeight - viewportHeight)
        let offset = min(max(0, contentOffsetY), maximumOffset)
        let first = max(0, Int(floor(offset / lineHeight)))
        let last = min(
            lineCount - 1,
            max(first, Int(ceil((offset + viewportHeight) / lineHeight)) - 1)
        )
        return first...last
    }
}
