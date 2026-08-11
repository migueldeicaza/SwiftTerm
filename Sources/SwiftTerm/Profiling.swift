//
//  Profiling.swift
//  SwiftTerm
//
//  Signpost instrumentation for the IO and frame pipeline (io-gaps.md C0.1).
//
//  Everything here is inert unless SWIFTTERM_PROFILE=1 is set in the
//  environment, and compiles to nothing on platforms without `os`. The flag is
//  the same one the Metal renderer already uses, so one environment variable
//  turns on the whole picture: pty read, parse, lock, frame, draw.
//
//  Usage:
//      let interval = Profiling.begin(.ioBatch)
//      ...
//      interval.end("bytes=%d", count)
//
//  Recording a trace:
//      SWIFTTERM_PROFILE=1 xcrun xctrace record --template 'Blank' \
//          --instrument os_signpost --launch -- <binary>
//

import Foundation

#if canImport(os)
import os
#endif

/// Signpost names used by the IO and frame pipeline. Kept in one place so a
/// trace template can enumerate them and so names cannot drift between sites.
enum ProfilingEvent {
    /// A batch delivered from the pty gather ring to the parse thread.
    case ioBatch
    /// `Terminal.feed` for one batch, measured inside the terminal lock.
    case ioParse
    /// Time spent waiting to acquire the terminal lock.
    case lockWait
    /// Time the terminal lock is held, from acquisition to release.
    case lockHold
    /// One frame tick, from the display link callback to the draw request.
    case frameTick
    /// `TerminalSnapshot.refresh`, the copy out of live terminal state.
    case frameRefresh

    var name: StaticString {
        switch self {
        case .ioBatch: return "IO.Batch"
        case .ioParse: return "IO.Parse"
        case .lockWait: return "Lock.Wait"
        case .lockHold: return "Lock.Hold"
        case .frameTick: return "Frame.Tick"
        case .frameRefresh: return "Frame.Refresh"
        }
    }
}

/// Which subsystem is asking for the terminal lock. The traces are much harder
/// to read without this: a 3 ms hold is expected from the parse thread and is a
/// bug on the main thread.
///
/// The tag is derived from the calling thread rather than passed in by every
/// call site, so instrumenting the lock costs no API churn. Derivation only
/// runs while profiling is enabled.
enum ProfilingOwner: UInt8 {
    case main = 0
    case parse = 1
    case timer = 2
    case other = 3

    /// Name assigned to the pipeline's parse thread. `TerminalIOPipeline` sets
    /// the same string as the `Thread.name`, which is what this reads.
    static let parseThreadName = "swiftterm-io-reader"

    static var current: ProfilingOwner {
        if Thread.isMainThread {
            return .main
        }
        guard let name = Thread.current.name, !name.isEmpty else {
            return .other
        }
        if name == parseThreadName {
            return .parse
        }
        if name.hasPrefix("swiftterm-io-timers") {
            return .timer
        }
        return .other
    }

    /// Trace-visible name. A `String` rather than a `StaticString` because the
    /// os_log format for it is `%{public}@`, which takes an object argument.
    /// Literal strings need no heap allocation, so this stays cheap.
    var tag: String {
        switch self {
        case .main: return "main"
        case .parse: return "parse"
        case .timer: return "timer"
        case .other: return "other"
        }
    }
}

/// An in-flight signpost interval. A zero-cost value when profiling is off:
/// `isActive` is false and every method returns immediately.
struct ProfilingInterval {
    fileprivate let event: ProfilingEvent
#if canImport(os)
    fileprivate let id: OSSignpostID
#endif
    fileprivate let isActive: Bool

    fileprivate init(inactive event: ProfilingEvent) {
        self.event = event
#if canImport(os)
        self.id = .invalid
#endif
        self.isActive = false
    }

#if canImport(os)
    fileprivate init(event: ProfilingEvent, id: OSSignpostID) {
        self.event = event
        self.id = id
        self.isActive = true
    }
#endif

    func end() {
        guard isActive else { return }
#if canImport(os)
        os_signpost(.end, log: Profiling.log, name: event.name, signpostID: id)
#endif
    }

    // Swift cannot forward variadic arguments, so the metadata overloads are
    // spelled out for the arities the pipeline actually uses.

    func end(_ format: StaticString, _ a: CVarArg) {
        guard isActive else { return }
#if canImport(os)
        os_signpost(.end, log: Profiling.log, name: event.name, signpostID: id, format, a)
#endif
    }

    func end(_ format: StaticString, _ a: CVarArg, _ b: CVarArg) {
        guard isActive else { return }
#if canImport(os)
        os_signpost(.end, log: Profiling.log, name: event.name, signpostID: id, format, a, b)
#endif
    }
}

enum Profiling {
    /// Master switch. Read once at load: toggling it mid-process is not
    /// supported, and a stored property keeps the hot-path check to one load.
    static let enabled: Bool = {
        ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE"] == "1"
    }()

#if canImport(os)
    static let log = OSLog(subsystem: "org.tirania.SwiftTerm", category: "IOProfile")
#endif

    @inline(__always)
    static func begin(_ event: ProfilingEvent) -> ProfilingInterval {
        guard enabled else { return ProfilingInterval(inactive: event) }
#if canImport(os)
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: event.name, signpostID: id)
        return ProfilingInterval(event: event, id: id)
#else
        return ProfilingInterval(inactive: event)
#endif
    }

    @inline(__always)
    static func begin(_ event: ProfilingEvent, _ format: StaticString, _ a: CVarArg) -> ProfilingInterval {
        guard enabled else { return ProfilingInterval(inactive: event) }
#if canImport(os)
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: event.name, signpostID: id, format, a)
        return ProfilingInterval(event: event, id: id)
#else
        return ProfilingInterval(inactive: event)
#endif
    }
}
