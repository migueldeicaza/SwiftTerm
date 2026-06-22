import Testing
import Foundation
@testable import SwiftTerm

// Benchmark for PR #555 (defer buffer reflow during live-resize).
//
// Quantifies the cost the fix avoids. During a live-resize drag the column count
// changes once per cell-width of mouse travel — each change is a real terminal.resize
// → a full-scrollback reflow. This measures, at several scrollback depths:
//   • "drag (N reflows)"  — the sum of incremental resizes across a 120→80 sweep
//                           (today's behavior: one reflow per column step), and
//   • "deferred (1 reflow)" — a single 120→80 resize (the fix: reflow once, at the end).
// The ratio is the wasted work the deferral removes. Direct Terminal.resize calls, so
// the number is independent of the macOS view layer / which branch this runs on.
@Suite("PR#555 live-resize reflow cost")
struct LiveResizeReflowBenchmark {

    // A wrapped log-style line (~180 chars) so resizing re-wraps it across the sweep.
    static let line = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 4)

    private static func filledTerminal(cols: Int, rows: Int, scrollback: Int) -> Terminal {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: scrollback)
        var feed = ""
        for i in 0..<(scrollback + rows) { feed += "\(i): \(line)\r\n" }
        terminal.feed(text: feed)
        return terminal
    }

    private static func ms(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
    }

    @Test func reflowCostByScrollbackDepth() {
        let rows = 40, startCols = 120, endCols = 80   // a 40-column drag
        print("\nPR#555 — live-resize reflow cost (120→80 col drag, \(rows) rows)")
        print("scrollback | reflows/drag | drag total ms | worst tick ms | deferred(1) ms | wasted×")
        print("-----------|--------------|---------------|---------------|----------------|--------")
        for depth in [1_000, 5_000, 10_000] {
            // today: one resize per column step
            let dragT = Self.filledTerminal(cols: startCols, rows: rows, scrollback: depth)
            var total = 0.0, worst = 0.0, count = 0
            for c in stride(from: startCols - 1, through: endCols, by: -1) {
                let dt = Self.ms { dragT.resize(cols: c, rows: rows) }
                total += dt; worst = max(worst, dt); count += 1
            }
            // the fix: a single resize to the final size
            let defT = Self.filledTerminal(cols: startCols, rows: rows, scrollback: depth)
            let deferred = Self.ms { defT.resize(cols: endCols, rows: rows) }
            print(String(format: "%10d | %12d | %13.1f | %13.2f | %14.2f | %6.1f×",
                         depth, count, total, worst, deferred, deferred > 0 ? total / deferred : 0))
        }
        print("")
    }
}
