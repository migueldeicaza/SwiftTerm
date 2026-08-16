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
    /// Acquiring the Metal drawable. Blocking, and paced by vsync, so it is
    /// time the main thread is unavailable rather than work it is doing.
    case metalDrawable = 7
    /// Building the Metal draw data (glyph shaping, row cache, buffers).
    case metalBuildDrawData = 8
    /// Encoding and committing the Metal command buffer.
    case metalEncode = 9
    /// Building one row's draw data: shaping plus glyph rasterization.
    case metalRowBuild = 10
    /// Building the row's attributed string (shared with the CG path).
    case rowAttributedString = 11
    /// CoreText shaping of the row's segments plus glyph rasterization.
    case rowShape = 12
    /// Applying a coalesced terminal resize, inside the frame's lock
    /// acquisition (io-gaps.md G5b).
    case frameResize = 13

    var index: Int { rawValue }

    /// Lock intervals are recorded per owner; the rest have a single bucket.
    var isOwnerTagged: Bool {
        self == .lockWait || self == .lockHold
    }

    var name: StaticString {
        switch self {
        case .frameResize: return "Frame.Resize"
        case .ioBatch: return "IO.Batch"
        case .ioParse: return "IO.Parse"
        case .lockWait: return "Lock.Wait"
        case .lockHold: return "Lock.Hold"
        case .frameTick: return "Frame.Tick"
        case .frameRefresh: return "Frame.Refresh"
        case .frameDraw: return "Frame.Draw"
        case .metalDrawable: return "Metal.Drawable"
        case .metalBuildDrawData: return "Metal.BuildDrawData"
        case .metalEncode: return "Metal.Encode"
        case .metalRowBuild: return "Metal.RowBuild"
        case .rowAttributedString: return "Row.AttributedString"
        case .rowShape: return "Row.Shape"
        }
    }

    var nameString: String {
        switch self {
        case .frameResize: return "Frame.Resize"
        case .ioBatch: return "IO.Batch"
        case .ioParse: return "IO.Parse"
        case .lockWait: return "Lock.Wait"
        case .lockHold: return "Lock.Hold"
        case .frameTick: return "Frame.Tick"
        case .frameRefresh: return "Frame.Refresh"
        case .frameDraw: return "Frame.Draw"
        case .metalDrawable: return "Metal.Drawable"
        case .metalBuildDrawData: return "Metal.BuildDrawData"
        case .metalEncode: return "Metal.Encode"
        case .metalRowBuild: return "Metal.RowBuild"
        case .rowAttributedString: return "Row.AttributedString"
        case .rowShape: return "Row.Shape"
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

/// One interval distribution from the in-process profiler.
public struct IntervalSummary: Sendable {
    public let event: String
    public let owner: String?
    public let count: Int
    public let p50Ms: Double
    public let p99Ms: Double
    public let p999Ms: Double
    public let maxMs: Double
    public let totalMs: Double
    public let dropped: Int
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
        let buckets = ProfilingEvent.allCases.count * Self.ownerCount
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

    func summaries() -> [IntervalSummary] {
        lock.lock()
        let snapshot = samples
        let drops = dropped
        lock.unlock()

        var result: [IntervalSummary] = []
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
                let owner = event.isOwnerTagged
                    ? ProfilingOwner(rawValue: UInt8(ownerRaw))?.tag
                    : nil
                result.append(IntervalSummary(
                    event: event.nameString,
                    owner: owner,
                    count: values.count,
                    p50Ms: percentile(0.50),
                    p99Ms: percentile(0.99),
                    p999Ms: percentile(0.999),
                    maxMs: ms(values[values.count - 1]),
                    totalMs: ms(total),
                    dropped: drops[index]))
            }
        }
        return result
    }

    /// A markdown table of the specified distributions, or an empty string
    /// when the array is empty.
    func report(summaries: [IntervalSummary]) -> String {
        var rows: [String] = []
        for summary in summaries {
            var label = summary.event
            if let owner = summary.owner {
                label += " owner=\(owner)"
            }
            if summary.dropped > 0 {
                label += " (+\(summary.dropped) dropped)"
            }
            rows.append(String(
                format: "| %@ | %d | %.3f | %.3f | %.3f | %.3f | %.1f |",
                label,
                summary.count,
                summary.p50Ms,
                summary.p99Ms,
                summary.p999Ms,
                summary.maxMs,
                summary.totalMs))
        }
        guard !rows.isEmpty else { return "" }
        var out = "| Interval | n | p50 ms | p99 ms | p999 ms | max ms | total ms |\n"
        out += "| --- | --- | --- | --- | --- | --- | --- |\n"
        out += rows.joined(separator: "\n")
        return out
    }

    /// A markdown table of the recorded distributions, or an empty string when
    /// nothing was recorded.
    func report() -> String {
        report(summaries: summaries())
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

/// Counts terminal-lock acquisitions by call site.
///
/// Same trick as the hop counter: `withTerminal` picks up `#function`, so the
/// attribution needs no call-site changes. Only records main-thread
/// acquisitions, which are the ones that pay a full parse batch of wait time.
final class ProfilingLockCallers {
    static let shared = ProfilingLockCallers()
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
        var out = "| Call site | Main-thread lock acquisitions |\n| --- | --- |\n"
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
        ProfilingLockCallers.shared.reset()
    }

    /// A markdown table of main-queue hops by originating callback.
    public static func hopReport() -> String { ProfilingHopCounter.shared.report() }

    /// A markdown table of main-thread terminal-lock acquisitions by call site.
    public static func lockCallerReport() -> String { ProfilingLockCallers.shared.report() }

    /// A markdown table of recorded interval distributions, empty when
    /// recording is off or nothing was recorded.
    public static func report() -> String { ProfilingStats.shared.report() }

    /// Returns one structured value for each recorded interval distribution.
    public static func summaries() -> [IntervalSummary] {
        ProfilingStats.shared.summaries()
    }

    /// Renders a captured summary set as the standard markdown table.
    public static func report(summaries: [IntervalSummary]) -> String {
        ProfilingStats.shared.report(summaries: summaries)
    }
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
