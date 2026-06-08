//
//  SyncDebug.swift
//  A lightweight, no-op tracing hook for the synchronized-output / DEC-2026
//  buffering path. The upstream "Simplifies the DEC 2026 buffering support"
//  commit added `SyncDebug.log(...)` call sites in Terminal.swift and
//  AppleTerminalView.swift but never committed the definition, which broke the
//  build. This restores compilation; logging is off by default (flip `enabled`
//  to trace the BSU/ESU/paint flow). `@autoclosure` keeps the message cost zero
//  when disabled.
//

import Foundation

enum SyncDebug {
    static let enabled = false

    @inline(__always)
    static func log(_ message: @autoclosure () -> String) {
        if enabled { print("[sync] \(message())") }
    }
}
