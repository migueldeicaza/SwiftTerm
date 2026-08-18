//
//  ProfilingTests.swift
//  SwiftTermTests
//
//  Covers the signpost instrumentation added for io-gaps.md C0.1.
//

import Foundation
import Testing
@testable import SwiftTerm

@Suite("Profiling")
struct ProfilingTests {
    /// The whole design rests on this: with the environment variable unset,
    /// every interval must be inert. If this flips, the instrumentation starts
    /// costing something in production builds.
    @Test func profilingIsOffByDefault() {
        #expect(Profiling.enabled == (ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE"] == "1"))
    }

    /// An inactive interval must tolerate every `end` overload. These are the
    /// calls that run on the hot path when profiling is off.
    @Test func inactiveIntervalsAreSafeToEnd() {
        let interval = Profiling.begin(.ioBatch)
        interval.end()
        interval.end("bytes=%d", 42)
        interval.end("rows=%d cols=%d", 24, 80)
    }

    @Test func ownerTagsAreDistinct() {
        let tags = Set([ProfilingOwner.main, .parse, .timer, .other].map { $0.tag })
        #expect(tags.count == 4)
    }

    @Test @MainActor func ownerOnMainThreadIsMain() {
        #expect(ProfilingOwner.current == .main)
    }

    /// `ProfilingOwner.current` reads `Thread.name`, which is what
    /// `TerminalIOPipeline` sets on its parse thread. This asserts the two
    /// sides agree; a rename on either side breaks lock traces silently
    /// otherwise.
    @Test func ownerOnNamedParseThreadIsParse() async {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ProfilingOwner, Never>) in
            let thread = Thread {
                continuation.resume(returning: ProfilingOwner.current)
            }
            thread.name = ProfilingOwner.parseThreadName
            thread.start()
        }
        #expect(result == .parse)
    }

    @Test func ownerOnUnnamedBackgroundThreadIsOther() async {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ProfilingOwner, Never>) in
            let thread = Thread {
                continuation.resume(returning: ProfilingOwner.current)
            }
            thread.start()
        }
        #expect(result == .other)
    }

    @Test func structuredSummariesMatchTheMarkdownReport() {
        ProfilingStats.shared.reset()
        defer { ProfilingStats.shared.reset() }

        ProfilingStats.shared.record(.ioParse, owner: nil, nanoseconds: 1_000_000)
        ProfilingStats.shared.record(.ioParse, owner: nil, nanoseconds: 2_000_000)
        ProfilingStats.shared.record(.ioParse, owner: nil, nanoseconds: 3_000_000)
        ProfilingStats.shared.record(.ioParse, owner: nil, nanoseconds: 4_000_000)
        ProfilingStats.shared.record(.lockHold, owner: .parse, nanoseconds: 500_000)

        let summaries = TerminalProfiling.summaries()
        let parse = summaries.first { $0.event == "IO.Parse" && $0.owner == nil }
        #expect(parse?.count == 4)
        #expect(parse?.p50Ms == 3.0)
        #expect(parse?.p99Ms == 4.0)
        #expect(parse?.p999Ms == 4.0)
        #expect(parse?.maxMs == 4.0)
        #expect(parse?.totalMs == 10.0)
        #expect(parse?.dropped == 0)

        let lock = summaries.first { $0.event == "Lock.Hold" && $0.owner == "parse" }
        #expect(lock?.count == 1)
        #expect(lock?.p50Ms == 0.5)

        let report = TerminalProfiling.report(summaries: summaries)
        #expect(TerminalProfiling.report() == report)
        #expect(report.contains("| IO.Parse | 4 | 3.000 | 4.000 | 4.000 | 4.000 | 10.0 |"))
        #expect(report.contains("| Lock.Hold owner=parse | 1 | 0.500 |"))
    }

    /// Exercises the real lock with intervals in flight. Catches an unbalanced
    /// begin/end or a hold interval leaking across owners, which would show up
    /// as a precondition failure or a hang rather than a bad trace.
    @Test func lockRemainsCorrectWithIntervalsInFlight() async {
        let lock = TerminalLock()
        let counter = Locked(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<500 {
                        lock.withLock {
                            counter.withLock { $0 += 1 }
                        }
                    }
                }
            }
        }
        #expect(counter.withLock { $0 } == 2000)
    }
}
