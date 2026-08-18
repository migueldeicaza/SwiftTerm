//
//  BellPolicy.swift
//  SwiftTerm
//
//  Decides whether a BEL should reach the view layer at all.
//
//  Motivation, from a measured run: `cat` of 256 MB of random bytes contains a
//  0x07 roughly every 256 bytes, so the terminal produced 1 053 159 bell
//  callbacks in 13 seconds. Each one hopped to the main queue before looking at
//  `bellStyle` — which the host had set to `.none`. The main queue could not
//  drain a million blocks, so the app produced 11 frames in 13 seconds and the
//  main thread stalled for over 3 seconds at p99.
//
//  Two rules fix that, and both are needed:
//   1. Do not marshal at all when the style is `.none`.
//   2. Rate limit what remains. A thousand beeps a second is not a feature at
//      any style setting, and the marshalling cost is the same whether or not
//      anybody wanted the sound.
//

import Foundation

/// Thread-safe gate for bell delivery. Consulted on the parse thread, so it
/// keeps its own state rather than reading view properties across threads.
final class BellPolicy {
    /// Shortest gap between two delivered bells. Terminals conventionally
    /// coalesce bursts; this is short enough that a human still perceives a
    /// deliberate double bell.
    static let minimumIntervalNs: UInt64 = 100_000_000   // 100 ms

    private let lock = NSLock()
    private var style: BellStyle = .sound
    private var lastDeliveryNs: UInt64 = 0
    private var suppressedCount = 0

    /// Mirrors the view's `bellStyle` so the parse thread never reads a
    /// property that the main thread owns.
    ///
    /// Changing the style clears the throttle. A style change is a deliberate
    /// configuration event, and the next bell after one is the host verifying
    /// its new setting; swallowing that as part of a burst would make the API
    /// feel broken even though the throttle is doing its job on real bursts.
    func setStyle (_ newStyle: BellStyle) {
        lock.lock()
        if newStyle != style {
            style = newStyle
            lastDeliveryNs = 0
        }
        lock.unlock()
    }

    var currentStyle: BellStyle {
        lock.lock()
        defer { lock.unlock() }
        return style
    }

    /// Number of bells dropped by the gate since the last reset. Diagnostics
    /// only; a large value is expected when binary data is displayed.
    var suppressed: Int {
        lock.lock()
        defer { lock.unlock() }
        return suppressedCount
    }

    func resetCounters () {
        lock.lock()
        suppressedCount = 0
        lock.unlock()
    }

    /// True when this bell should be delivered to the view layer.
    ///
    /// - Parameter now: current uptime in nanoseconds, injectable for tests.
    func shouldDeliver (now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if style == .none {
            suppressedCount += 1
            return false
        }
        // First bell always passes: lastDeliveryNs of 0 means nothing has been
        // delivered yet, and `now` is monotonic and never 0 in practice.
        if lastDeliveryNs != 0 && now &- lastDeliveryNs < Self.minimumIntervalNs {
            suppressedCount += 1
            return false
        }
        lastDeliveryNs = now
        return true
    }
}
