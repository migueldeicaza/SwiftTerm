//
//  IOTimerQueue.swift
//  SwiftTerm
//
//  The queue SwiftTerm's own timers run on.
//
//  Deliberately not the main queue. The timers that live here are safety
//  valves — the synchronized-output reset above all — and the main thread is
//  precisely the thread most likely to be blocked when a valve is needed
//  (io-gaps.md G5c). An application that sets DECSET 2026 and never clears it
//  freezes the display until the reset fires; scheduling that reset behind the
//  frozen thread is the wrong choice.
//
//  Not every timer belongs here. A timer whose handler is main-thread work —
//  selection auto-scroll, text blink — gains nothing from moving and pays a
//  cross-thread hop. See the G5c notes in io-gaps.md.
//

import Foundation

enum IOTimerQueue {
    /// Serial on purpose: the handlers take the terminal lock, and one at a
    /// time removes any question of ordering between them.
    ///
    /// The label matters beyond debugging — `ProfilingOwner.current` matches on
    /// it to attribute lock holds and waits to `.timer` rather than `.other`.
    static let shared = DispatchQueue(label: "swiftterm-io-timers", qos: .utility)
}
