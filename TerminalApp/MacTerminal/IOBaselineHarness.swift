//
//  IOBaselineHarness.swift
//  MacTerminal
//
//  Load harness for the io-gaps.md C0.2 baselines. Produces the numbers that
//  Docs/io-baselines.md leaves as TODO: throughput, main-thread stall
//  distribution, and frame production under load.
//
//  Everything here is measurement scaffolding for the app. It is deliberately
//  not part of the SwiftTerm library.
//

import Foundation
import SwiftTerm

/// Samples how long the main thread is unavailable.
///
/// A background timer stamps a deadline and posts a block to the main queue.
/// The delay between the deadline and the block running is the time the main
/// thread was busy or blocked, which is exactly the quantity that decides
/// whether frames keep coming under load.
///
/// This measures main-queue latency rather than run-loop cycle time on purpose:
/// a modal loop or a long `draw(_:)` shows up here, and both are the failure
/// mode that io-gaps.md G1 addresses.
final class MainThreadStallMonitor {
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "swiftterm-stall-monitor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var samplesNs: [UInt64] = []
    private var outstanding = 0

    /// - Parameter interval: sampling period. 4 ms samples a 120 Hz display
    ///   about twice per frame, which is enough to catch a dropped frame
    ///   without the monitor itself becoming a load.
    init(interval: TimeInterval = 0.004) {
        self.interval = interval
    }

    func start() {
        stop()
        lock.lock()
        samplesNs.removeAll(keepingCapacity: true)
        outstanding = 0
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Skip a sample rather than pile up when main is already behind:
            // an unbounded backlog would measure the backlog, not the stall.
            self.lock.lock()
            let busy = self.outstanding > 2
            if !busy { self.outstanding += 1 }
            self.lock.unlock()
            guard !busy else { return }

            let deadline = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let delay = DispatchTime.now().uptimeNanoseconds &- deadline
                self.lock.lock()
                self.samplesNs.append(delay)
                self.outstanding -= 1
                self.lock.unlock()
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    struct Summary {
        var count: Int
        var meanMs: Double
        var p50Ms: Double
        var p99Ms: Double
        var maxMs: Double
    }

    func summarize() -> Summary {
        lock.lock()
        let samples = samplesNs.sorted()
        lock.unlock()
        guard !samples.isEmpty else {
            return Summary(count: 0, meanMs: 0, p50Ms: 0, p99Ms: 0, maxMs: 0)
        }
        func ms(_ ns: UInt64) -> Double { Double(ns) / 1_000_000.0 }
        func percentile(_ p: Double) -> Double {
            let index = min(samples.count - 1, max(0, Int((Double(samples.count - 1) * p).rounded())))
            return ms(samples[index])
        }
        let total = samples.reduce(UInt64(0), &+)
        return Summary(count: samples.count,
                       meanMs: ms(total / UInt64(samples.count)),
                       p50Ms: percentile(0.50),
                       p99Ms: percentile(0.99),
                       maxMs: ms(samples[samples.count - 1]))
    }
}

/// Runs one load case against a live terminal and reports the result.
final class IOBaselineHarness {
    /// The load cases from io-gaps.md C0.2 that can be driven by sending a
    /// command to the shell. Cases needing user interaction (the window drag in
    /// case 2, the keystrokes in case 3) are run by hand with the same report.
    enum Case: Int, CaseIterable {
        case flood
        case bidiFlood
        case tui
        case binary

        var title: String {
            switch self {
            case .flood: return "Flood (100 MB ASCII)"
            case .bidiFlood: return "Bidi flood (80 MB)"
            case .tui: return "TUI scroll"
            case .binary: return "Binary cat (/tmp/big.bin)"
            }
        }

        /// A file this case needs before it can run.
        var requiredFile: String? {
            switch self {
            case .binary: return "/tmp/big.bin"
            default: return nil
            }
        }

        /// Shell command that produces the load. Each ends by printing a marker
        /// so a reader of the transcript can see the case ran to completion.
        var command: String {
            switch self {
            case .flood:
                // yes gives a steady saturated stream without needing a file on
                // disk. head bounds it so a wedged run cannot flood forever.
                return "yes 'the quick brown fox jumps over the lazy dog 0123456789' | head -c 104857600"
            case .bidiFlood:
                // Arabic and Hebrew text exercises the bidi layout that
                // currently runs inside the terminal lock (io-gaps.md G2).
                // 80 MB, not 20: the quiet detector polls every 250 ms, so a
                // window near one second carries +/- 20% quantization error.
                // At ~5 s that drops to a few percent.
                return "yes 'مرحبا بالعالم שלום עולם hello world 0123456789' | head -c 83886080"
            case .tui:
                return "for i in $(seq 1 2000); do printf '\\033[2J\\033[H'; seq 1 40; done"
            case .binary:
                // Arbitrary bytes: the parser meets malformed sequences, huge
                // combining runs and control characters it cannot fast-path.
                // This is the case that has been observed to wedge the app for
                // long periods, which is why the watchdog below is not
                // optional.
                return "cat /tmp/big.bin"
            }
        }
    }

    private let terminal: LocalProcessTerminalView
    private let monitor = MainThreadStallMonitor()
    private var startTime = DispatchTime.now()
    private var runningCase: Case?
    private var completion: ((String) -> Void)?

    /// Watchdog queue. Deliberately not the main queue: the whole point is to
    /// survive a main thread that is wedged, which is exactly the state the
    /// binary case can produce. A main-queue timeout would never fire.
    private let watchdogQueue = DispatchQueue(label: "swiftterm-baseline-watchdog",
                                              qos: .userInitiated)
    private var watchdog: DispatchSourceTimer?

    /// Hard limit on one measurement window. Overridable with
    /// `SWIFTTERM_BASELINE_TIMEOUT` (seconds).
    private let timeoutSeconds: Double

    /// When true, a timeout ends the process. Scripted runs want this: a hung
    /// app that never exits blocks whatever is driving it.
    var terminateOnTimeout = false

    init(terminal: LocalProcessTerminalView) {
        self.terminal = terminal
        let environment = ProcessInfo.processInfo.environment["SWIFTTERM_BASELINE_TIMEOUT"]
        self.timeoutSeconds = environment.flatMap(Double.init) ?? 45.0
    }

    var isRunning: Bool { runningCase != nil }

    /// The load must be at least this large before the run counts as real.
    ///
    /// Without it, a command typed before the shell was listening produces only
    /// the echoed command line, the counter goes quiet, and the harness happily
    /// reports a "0.0 MB/s" run. That happened, and the number looked
    /// plausible enough in a table to be dangerous.
    private static let minimumLoadBytes = 64 * 1024

    /// Runs one case and calls `completion` with a report when the load has
    /// stopped producing output.
    ///
    /// Two phases. First wait for the shell to finish starting and print its
    /// prompt, detected as the byte counter going quiet. Only then reset the
    /// counters and send the command, so shell startup is never inside the
    /// measurement window and the command is never typed into a shell that is
    /// not listening yet.
    func run(_ loadCase: Case, completion: @escaping (String) -> Void) {
        guard runningCase == nil else { return }

        if let path = loadCase.requiredFile, !FileManager.default.fileExists(atPath: path) {
            completion("## \(loadCase.title)\n\nSKIPPED: \(path) does not exist.\n"
                       + "Create it first, for example:\n"
                       + "    dd if=/dev/urandom of=\(path) bs=1m count=64\n")
            return
        }

        runningCase = loadCase
        self.completion = completion

        waitForQuiet(minimumBytes: 0) { [weak self] in
            guard let self else { return }
            self.terminal.resetDiagnostics()
            TerminalProfiling.reset()
            self.monitor.start()
            self.startTime = DispatchTime.now()
            self.armWatchdog(for: loadCase)
            self.terminal.send(txt: loadCase.command + "\n")
            self.waitForQuiet(minimumBytes: Self.minimumLoadBytes) { [weak self] in
                self?.finish()
            }
        }
    }

    /// Fires off the main thread if the measurement window overruns. It reports
    /// what was captured up to that point and, for scripted runs, ends the
    /// process rather than leaving a wedged app behind.
    private func armWatchdog(for loadCase: Case) {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                                 &- self.startTime.uptimeNanoseconds) / 1_000_000_000.0
            self.monitor.stop()
            var report = self.buildReport(loadCase: loadCase, elapsed: elapsed)
            report = "**TIMED OUT after \(Int(self.timeoutSeconds)) s.** "
                + "The load did not finish; numbers below cover the window that ran, "
                + "and the app was still busy when it expired.\n\n" + report
            print("===BASELINE-BEGIN===")
            print(report)
            print("===BASELINE-END===")
            fflush(stdout)
            if self.terminateOnTimeout {
                exit(3)
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// Calls `then` once the byte counter has been still for three polls and
    /// has passed `minimumBytes`. Polling beats a fixed duration: the cases
    /// differ by an order of magnitude in runtime, so a fixed window would
    /// either cut the flood short or sit idle through the short cases.
    private func waitForQuiet(minimumBytes: Int, then: @escaping () -> Void) {
        var lastBytes = -1
        var quietPolls = 0
        let pollInterval = 0.25

        func poll() {
            guard runningCase != nil else { return }
            let bytes = terminal.diagnostics.bytesFed
            if bytes == lastBytes {
                quietPolls += 1
            } else {
                quietPolls = 0
                lastBytes = bytes
            }
            if quietPolls >= 3 && bytes >= minimumBytes {
                then()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
    }

    private func finish() {
        guard let loadCase = runningCase else { return }
        cancelWatchdog()
        // Subtract the quiet detection window so throughput is not diluted by
        // the time spent noticing that the load stopped.
        let quietWindow = 0.75
        let elapsed = max(0.001,
                          Double(DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds)
                            / 1_000_000_000.0 - quietWindow)
        monitor.stop()
        let report = buildReport(loadCase: loadCase, elapsed: elapsed)
        runningCase = nil
        completion?(report)
        completion = nil
    }

    /// Builds the report from whatever has been recorded so far. Called both by
    /// a normal finish and by the watchdog, so it must not assume the run
    /// completed and must be safe off the main thread: every source it reads
    /// (view diagnostics, stall monitor, profiling stats) is lock-guarded.
    private func buildReport(loadCase: Case, elapsed: Double) -> String {
        let stalls = monitor.summarize()
        let diagnostics = terminal.diagnostics

        let mbPerSecond = Double(diagnostics.bytesFed) / elapsed / (1024 * 1024)
        let framesPerSecond = Double(diagnostics.frames) / elapsed

        let usesMetal = ProcessInfo.processInfo.arguments.contains("--metal")
            || ProcessInfo.processInfo.environment["SWIFTTERM_METAL"] == "1"
        let renderer = usesMetal ? "Metal" : "CoreGraphics"

        var report = ""
        report += "## \(loadCase.title) [\(renderer)]\n\n"
        report += "| Measurement | Value |\n| --- | --- |\n"
        report += String(format: "| Elapsed | %.2f s |\n", elapsed)
        report += String(format: "| Bytes fed | %d (%.1f MB) |\n",
                         diagnostics.bytesFed, Double(diagnostics.bytesFed) / (1024 * 1024))
        report += String(format: "| Throughput | %.1f MB/s |\n", mbPerSecond)
        report += "| Batches | \(diagnostics.batches) |\n"
        report += "| Mean batch | \(diagnostics.meanBatchBytes) bytes |\n"
        report += String(format: "| Frames | %d (%.1f/s) |\n", diagnostics.frames, framesPerSecond)
        report += "| Display ticks | \(diagnostics.ticks) |\n"
        report += "| Idle ticks | \(diagnostics.idleTicks) |\n"
        report += "| Immediate ticks | \(diagnostics.immediateTicks) |\n"
        report += "| Link pauses | \(diagnostics.pauses) |\n"
        report += "| Main-queue hops | \(diagnostics.mainHops) |\n"
        report += String(format: "| Main-thread stall, mean | %.2f ms |\n", stalls.meanMs)
        report += String(format: "| Main-thread stall, p50 | %.2f ms |\n", stalls.p50Ms)
        report += String(format: "| Main-thread stall, p99 | %.2f ms |\n", stalls.p99Ms)
        report += String(format: "| Main-thread stall, max | %.2f ms |\n", stalls.maxMs)
        report += "| Stall samples | \(stalls.count) |\n"

        // In-process interval distributions, when SWIFTTERM_PROFILE_STATS=1.
        // These are complete, unlike a log-stream capture under load.
        let intervals = TerminalProfiling.report()
        if !intervals.isEmpty {
            report += "\n### Intervals\n\n" + intervals + "\n"
        }
        let hops = TerminalProfiling.hopReport()
        if !hops.isEmpty {
            report += "\n### Main-queue hops by callback\n\n" + hops
        }
        let lockCallers = TerminalProfiling.lockCallerReport()
        if !lockCallers.isEmpty {
            report += "\n### Main-thread lock acquisitions by call site\n\n" + lockCallers
        }
        return report
    }
}
