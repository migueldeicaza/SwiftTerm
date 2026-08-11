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
enum ProfilingEvent: Int, CaseIterable {
    /// A batch delivered from the pty gather ring to the parse thread.
    case ioBatch = 0
    /// `Terminal.feed` for one batch, measured inside the terminal lock.
    case ioParse = 1
    /// Time spent waiting to acquire the terminal lock.
    case lockWait = 2
    /// Time the terminal lock is held, from acquisition to release.
    case lockHold = 3
    /// One frame tick, from the display link callback to the draw request.
    case frameTick = 4
    /// `TerminalSnapshot.refresh`, the copy out of live terminal state.
    case frameRefresh = 5
    /// The Core Graphics draw, from the snapshot, with no lock held.
    case frameDraw = 6

    var index: Int { rawValue }

    /// Lock intervals are recorded per owner; the rest have a single bucket.
    var isOwnerTagged: Bool {
        self == .lockWait || self == .lockHold
    }

    var name: StaticString {
        switch self {
        case .ioBatch: return "IO.Batch"
        case .ioParse: return "IO.Parse"
        case .lockWait: return "Lock.Wait"
        case .lockHold: return "Lock.Hold"
        case .frameTick: return "Frame.Tick"
        case .frameRefresh: return "Frame.Refresh"
        case .frameDraw: return "Frame.Draw"
        }
    }

    var nameString: String {
        switch self {
        case .ioBatch: return "IO.Batch"
        case .ioParse: return "IO.Parse"
        case .lockWait: return "Lock.Wait"
        case .lockHold: return "Lock.Hold"
        case .frameTick: return "Frame.Tick"
        case .frameRefresh: return "Frame.Refresh"
        case .frameDraw: return "Frame.Draw"
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

/// An in-flight interval. A zero-cost value when profiling is off: `isActive`
/// is false and every method returns immediately.
struct ProfilingInterval {
    fileprivate let event: ProfilingEvent
    fileprivate let owner: ProfilingOwner?
    fileprivate let startNs: UInt64
#if canImport(os)
    fileprivate let id: OSSignpostID
#endif
    fileprivate let isActive: Bool

    fileprivate init(inactive event: ProfilingEvent) {
        self.event = event
        self.owner = nil
        self.startNs = 0
#if canImport(os)
        self.id = .invalid
#endif
        self.isActive = false
    }

#if canImport(os)
    fileprivate init(event: ProfilingEvent, owner: ProfilingOwner?, startNs: UInt64, id: OSSignpostID) {
        self.event = event
        self.owner = owner
        self.startNs = startNs
        self.id = id
        self.isActive = true
    }
#else
    fileprivate init(event: ProfilingEvent, owner: ProfilingOwner?, startNs: UInt64) {
        self.event = event
        self.owner = owner
        self.startNs = startNs
        self.isActive = true
    }
#endif

    private func recordDuration() {
        guard ProfilingStats.enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        ProfilingStats.shared.record(event, owner: event.isOwnerTagged ? owner : nil,
                                     nanoseconds: now &- startNs)
    }

    func end() {
        guard isActive else { return }
        recordDuration()
#if canImport(os)
        if Profiling.signpostsEnabled {
            os_signpost(.end, log: Profiling.log, name: event.name, signpostID: id)
        }
#endif
    }

    // Swift cannot forward variadic arguments, so the metadata overloads are
    // spelled out for the arities the pipeline actually uses.

    func end(_ format: StaticString, _ a: CVarArg) {
        guard isActive else { return }
        recordDuration()
#if canImport(os)
        if Profiling.signpostsEnabled {
            os_signpost(.end, log: Profiling.log, name: event.name, signpostID: id, format, a)
        }
#endif
    }

    func end(_ format: StaticString, _ a: CVarArg, _ b: CVarArg) {
        guard isActive else { return }
        recordDuration()
#if canImport(os)
        if Profiling.signpostsEnabled {
            os_signpost(.end, log: Profiling.log, name: event.name, signpostID: id, format, a, b)
        }
#endif
    }
}

/// In-process duration recorder.
///
/// Signposts are the right tool for a timeline, but `log stream` drops events
/// under exactly the load worth measuring: a bidi flood produced 3 500 batches
/// and the capture paired 678, with every interval's maximum truncated to the
/// same ~0.1 ms. Percentiles from a lossy capture are worse than no
/// percentiles, because they look authoritative.
///
/// This records every sample in process, so the distributions are complete.
/// Enabled by `SWIFTTERM_PROFILE_STATS=1`, independently of the signposts.
final class ProfilingStats {
    static let shared = ProfilingStats()

    static let enabled: Bool = {
        ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE_STATS"] == "1"
    }()

    /// Samples per bucket before recording stops for that bucket. A flood
    /// produces a few hundred thousand batches; capping bounds the memory at a
    /// few MB and the early samples are representative.
    private static let capacity = 500_000
    private static let ownerCount = 4

    private let lock = NSLock()
    private var samples: [[UInt64]]
    private var dropped: [Int]

    private init() {
        let buckets = 8 * Self.ownerCount
        samples = Array(repeating: [], count: buckets)
        dropped = Array(repeating: 0, count: buckets)
    }

    private func bucket(_ event: ProfilingEvent, _ owner: ProfilingOwner?) -> Int {
        event.index * Self.ownerCount + Int(owner?.rawValue ?? 0)
    }

    func record(_ event: ProfilingEvent, owner: ProfilingOwner?, nanoseconds: UInt64) {
        let index = bucket(event, owner)
        lock.lock()
        if samples[index].count < Self.capacity {
            samples[index].append(nanoseconds)
        } else {
            dropped[index] += 1
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        for index in samples.indices {
            samples[index].removeAll(keepingCapacity: true)
            dropped[index] = 0
        }
        lock.unlock()
    }

    /// A markdown table of the recorded distributions, or an empty string when
    /// nothing was recorded.
    func report() -> String {
        lock.lock()
        let snapshot = samples
        let drops = dropped
        lock.unlock()

        var rows: [String] = []
        for event in ProfilingEvent.allCases {
            for ownerRaw in 0..<Self.ownerCount {
                let index = event.index * Self.ownerCount + ownerRaw
                var values = snapshot[index]
                guard !values.isEmpty else { continue }
                values.sort()
                func ms(_ ns: UInt64) -> Double { Double(ns) / 1_000_000.0 }
                func percentile(_ q: Double) -> Double {
                    ms(values[min(values.count - 1, Int((Double(values.count - 1) * q).rounded()))])
                }
                let total = values.reduce(UInt64(0), &+)
                var label = "\(event.nameString)"
                if event.isOwnerTagged, let owner = ProfilingOwner(rawValue: UInt8(ownerRaw)) {
                    label += " owner=\(owner.tag)"
                }
                if drops[index] > 0 {
                    label += " (+\(drops[index]) dropped)"
                }
                rows.append(String(format: "| %@ | %d | %.3f | %.3f | %.3f | %.3f | %.1f |",
                                   label, values.count,
                                   percentile(0.50), percentile(0.99), percentile(0.999),
                                   ms(values[values.count - 1]),
                                   ms(total)))
            }
        }
        guard !rows.isEmpty else { return "" }
        var out = "| Interval | n | p50 ms | p99 ms | p999 ms | max ms | total ms |\n"
        out += "| --- | --- | --- | --- | --- | --- | --- |\n"
        out += rows.joined(separator: "\n")
        return out
    }
}

/// Counts main-queue hops by originating callback.
///
/// `onMain` picks up `#function` automatically, so no call site changes and no
/// cost unless statistics are enabled. This is what turns "9 417 hops" into a
/// list of the callbacks worth fixing.
final class ProfilingHopCounter {
    static let shared = ProfilingHopCounter()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ caller: StaticString) {
        let key = "\(caller)"
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        counts.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func report() -> String {
        lock.lock()
        let snapshot = counts
        lock.unlock()
        guard !snapshot.isEmpty else { return "" }
        var out = "| Callback | Main-queue hops |\n| --- | --- |\n"
        for (key, value) in snapshot.sorted(by: { $0.value > $1.value }) {
            out += "| `\(key)` | \(value) |\n"
        }
        return out
    }
}

/// Public entry point so a host app can print the in-process distributions.
public enum TerminalProfiling {
    /// True when `SWIFTTERM_PROFILE_STATS=1` selected in-process recording.
    public static var isRecording: Bool { ProfilingStats.enabled }

    /// Clears the recorded samples, starting a new measurement window.
    public static func reset() {
        ProfilingStats.shared.reset()
        ProfilingHopCounter.shared.reset()
    }

    /// A markdown table of main-queue hops by originating callback.
    public static func hopReport() -> String { ProfilingHopCounter.shared.report() }

    /// A markdown table of recorded interval distributions, empty when
    /// recording is off or nothing was recorded.
    public static func report() -> String { ProfilingStats.shared.report() }
}

enum Profiling {
    /// Master switch. Read once at load: toggling it mid-process is not
    /// supported, and a stored property keeps the hot-path check to one load.
    static let enabled: Bool = {
        ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE"] == "1"
            || ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE_STATS"] == "1"
    }()

    /// True when signposts should be emitted. Statistics recording can run
    /// without them, which is the cheaper configuration for measurement.
    static let signpostsEnabled: Bool = {
        ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE"] == "1"
    }()

#if canImport(os)
    static let log = OSLog(subsystem: "org.tirania.SwiftTerm", category: "IOProfile")
#endif

    @inline(__always)
    static func begin(_ event: ProfilingEvent, owner: ProfilingOwner? = nil) -> ProfilingInterval {
        guard enabled else { return ProfilingInterval(inactive: event) }
        let start = DispatchTime.now().uptimeNanoseconds
#if canImport(os)
        var id = OSSignpostID.invalid
        if signpostsEnabled {
            id = OSSignpostID(log: log)
            if let owner {
                os_signpost(.begin, log: log, name: event.name, signpostID: id,
                            "owner=%{public}@", owner.tag)
            } else {
                os_signpost(.begin, log: log, name: event.name, signpostID: id)
            }
        }
        return ProfilingInterval(event: event, owner: owner, startNs: start, id: id)
#else
        return ProfilingInterval(event: event, owner: owner, startNs: start)
#endif
    }

    @inline(__always)
    static func begin(_ event: ProfilingEvent, _ format: StaticString, _ a: CVarArg) -> ProfilingInterval {
        guard enabled else { return ProfilingInterval(inactive: event) }
        let start = DispatchTime.now().uptimeNanoseconds
#if canImport(os)
        var id = OSSignpostID.invalid
        if signpostsEnabled {
            id = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: event.name, signpostID: id, format, a)
        }
        return ProfilingInterval(event: event, owner: nil, startNs: start, id: id)
#else
        return ProfilingInterval(event: event, owner: nil, startNs: start)
#endif
    }
}
