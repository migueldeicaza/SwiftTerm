import Testing
@testable import SwiftTerm

@Suite("Accessibility reading policy")
struct AccessibilityReadingPolicyTests {
    @Test("Line lookup rejects empty and out-of-range content")
    func lineLookupBounds() {
        #expect(AccessibilityReadingPolicy.lineNumber(
            atContentY: -1, lineHeight: 20, lineCount: 10
        ) == nil)
        #expect(AccessibilityReadingPolicy.lineNumber(
            atContentY: 200, lineHeight: 20, lineCount: 10
        ) == nil)
        #expect(AccessibilityReadingPolicy.lineNumber(
            atContentY: 0, lineHeight: 0, lineCount: 10
        ) == nil)
        #expect(AccessibilityReadingPolicy.lineNumber(
            atContentY: 0, lineHeight: 20, lineCount: 0
        ) == nil)
    }

    @Test("Line lookup maps content coordinates to rows")
    func lineLookup() {
        #expect(AccessibilityReadingPolicy.lineNumber(
            atContentY: 0, lineHeight: 20, lineCount: 10
        ) == 0)
        #expect(AccessibilityReadingPolicy.lineNumber(
            atContentY: 39.9, lineHeight: 20, lineCount: 10
        ) == 1)
        #expect(AccessibilityReadingPolicy.lineNumber(
            atContentY: 199.9, lineHeight: 20, lineCount: 10
        ) == 9)
    }

    @Test("Visible page includes partial edge rows")
    func partialRows() {
        #expect(AccessibilityReadingPolicy.visibleLines(
            contentOffsetY: 10,
            viewportHeight: 40,
            lineHeight: 20,
            lineCount: 10
        ) == 0...2)
    }

    @Test("Visible page clamps offsets and the final row")
    func pageBounds() {
        #expect(AccessibilityReadingPolicy.visibleLines(
            contentOffsetY: -100,
            viewportHeight: 40,
            lineHeight: 20,
            lineCount: 10
        ) == 0...1)
        #expect(AccessibilityReadingPolicy.visibleLines(
            contentOffsetY: 10_000,
            viewportHeight: 40,
            lineHeight: 20,
            lineCount: 10
        ) == 8...9)
        #expect(AccessibilityReadingPolicy.visibleLines(
            contentOffsetY: 0,
            viewportHeight: 400,
            lineHeight: 20,
            lineCount: 3
        ) == 0...2)
    }

    @Test("Visible page rejects invalid geometry")
    func invalidPageGeometry() {
        #expect(AccessibilityReadingPolicy.visibleLines(
            contentOffsetY: 0, viewportHeight: 0, lineHeight: 20, lineCount: 10
        ) == nil)
        #expect(AccessibilityReadingPolicy.visibleLines(
            contentOffsetY: 0, viewportHeight: 40, lineHeight: 0, lineCount: 10
        ) == nil)
        #expect(AccessibilityReadingPolicy.visibleLines(
            contentOffsetY: 0, viewportHeight: 40, lineHeight: 20, lineCount: 0
        ) == nil)
    }
}
