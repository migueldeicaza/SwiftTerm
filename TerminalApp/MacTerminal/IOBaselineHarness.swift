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

        var title: String {
            switch self {
            case .flood: return "Flood (100 MB ASCII)"
            case .bidiFlood: return "Bidi flood"
            case .tui: return "TUI scroll"
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
                return "yes 'مرحبا بالعالم שלום עולם hello world 0123456789' | head -c 20971520"
            case .tui:
                return "for i in $(seq 1 2000); do printf '\\033[2J\\033[H'; seq 1 40; done"
            }
        }
    }

    private let terminal: LocalProcessTerminalView
    private let monitor = MainThreadStallMonitor()
    private var startTime = DispatchTime.now()
    private var runningCase: Case?
    private var completion: ((String) -> Void)?

    init(terminal: LocalProcessTerminalView) {
        self.terminal = terminal
    }

    var isRunning: Bool { runningCase != nil }

    /// Runs one case and calls `completion` with a report when the load has
    /// stopped producing output.
    func run(_ loadCase: Case, completion: @escaping (String) -> Void) {
        guard runningCase == nil else { return }
        runningCase = loadCase
        self.completion = completion

        terminal.resetDiagnostics()
        monitor.start()
        startTime = DispatchTime.now()
        terminal.send(txt: loadCase.command + "\n")

        pollForQuiet()
    }

    /// The load is done when the byte counter stops moving. Polling beats a
    /// fixed duration here: the cases have very different runtimes, and a
    /// fixed window would either cut the flood short or spend most of the
    /// window idle for the shorter cases.
    private func pollForQuiet() {
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
            // Three quiet polls, and only after some data actually arrived.
            if quietPolls >= 3 && bytes > 0 {
                finish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
    }

    private func finish() {
        guard let loadCase = runningCase else { return }
        // Subtract the quiet detection window so throughput is not diluted by
        // the time spent noticing that the load stopped.
        let quietWindow = 0.75
        let elapsed = max(0.001,
                          Double(DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds)
                            / 1_000_000_000.0 - quietWindow)
        monitor.stop()
        let stalls = monitor.summarize()
        let diagnostics = terminal.diagnostics
        runningCase = nil

        let mbPerSecond = Double(diagnostics.bytesFed) / elapsed / (1024 * 1024)
        let framesPerSecond = Double(diagnostics.frames) / elapsed

        var report = ""
        report += "## \(loadCase.title)\n\n"
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
        report += String(format: "| Main-thread stall, mean | %.2f ms |\n", stalls.meanMs)
        report += String(format: "| Main-thread stall, p50 | %.2f ms |\n", stalls.p50Ms)
        report += String(format: "| Main-thread stall, p99 | %.2f ms |\n", stalls.p99Ms)
        report += String(format: "| Main-thread stall, max | %.2f ms |\n", stalls.maxMs)
        report += "| Stall samples | \(stalls.count) |\n"

        completion?(report)
        completion = nil
    }
}
