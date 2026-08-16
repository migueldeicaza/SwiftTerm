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

import AppKit
import Foundation
import SwiftTerm
import VTEBenchWorkloads

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
    private var generation: UInt64 = 0

    /// - Parameter interval: sampling period. 4 ms samples a 120 Hz display
    ///   about twice per frame, which is enough to catch a dropped frame
    ///   without the monitor itself becoming a load.
    init(interval: TimeInterval = 0.004) {
        self.interval = interval
    }

    func start() {
        stop()
        lock.lock()
        generation &+= 1
        let activeGeneration = generation
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
            guard self.generation == activeGeneration else {
                self.lock.unlock()
                return
            }
            let busy = self.outstanding > 2
            if !busy { self.outstanding += 1 }
            self.lock.unlock()
            guard !busy else { return }

            let deadline = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let delay = DispatchTime.now().uptimeNanoseconds &- deadline
                self.lock.lock()
                guard self.generation == activeGeneration else {
                    self.lock.unlock()
                    return
                }
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
        lock.lock()
        generation &+= 1
        outstanding = 0
        lock.unlock()
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
    /// A fixed workload that the child process sends through the PTY.
    enum Case: String, CaseIterable {
        case flood
        case bidiFlood = "bidi"
        case tui
        case binary
        case cursorMotion = "cursor_motion"
        case denseCells = "dense_cells"
        case lightCells = "light_cells"
        case mediumCells = "medium_cells"
        case scrolling
        case scrollingBottomRegion = "scrolling_bottom_region"
        case scrollingBottomSmallRegion = "scrolling_bottom_small_region"
        case scrollingFullscreen = "scrolling_fullscreen"
        case scrollingTopRegion = "scrolling_top_region"
        case scrollingTopSmallRegion = "scrolling_top_small_region"
        case syncMediumCells = "sync_medium_cells"
        case unicode

        static let vteBenchCases: [Case] = [
            .cursorMotion,
            .denseCells,
            .lightCells,
            .mediumCells,
            .scrolling,
            .scrollingBottomRegion,
            .scrollingBottomSmallRegion,
            .scrollingFullscreen,
            .scrollingTopRegion,
            .scrollingTopSmallRegion,
            .syncMediumCells,
            .unicode
        ]

        var title: String {
            switch self {
            case .flood: return "Flood (100 MB ASCII)"
            case .bidiFlood: return "Bidi flood (80 MB)"
            case .tui: return "TUI scroll"
            case .binary: return "Binary byte ramp (64 MB)"
            case .unicode: return "vtebench unicode (100 MiB)"
            default: return "vtebench \(rawValue)"
            }
        }
    }

    private struct Workload {
        let setup: [UInt8]
        let payload: [UInt8]
        let targetByteCount: Int
    }

    private struct PreparedCase {
        let loadCase: Case
        let setupCommand: String
        let setupByteCount: Int
        let payloadCommand: String
        let targetByteCount: Int
    }

    private struct Measurement {
        let report: String
        let machineLine: String
    }

    private struct Iteration {
        let loadCase: Case
        let repetition: Int
        let repetitionCount: Int
        let isWarmUp: Bool
    }

    private let terminal: LocalProcessTerminalView
    private let monitor = MainThreadStallMonitor()
    private var startTime = DispatchTime.now()
    private var runningCase: Case?
    private var pendingIterations: [Iteration] = []
    private var resultHandler: ((String, String) -> Void)?
    private var suiteCompletion: (() -> Void)?
    private var benchmarkLabel = "unlabelled"
    private var preparedCases: [Case: PreparedCase] = [:]
    private let vteBenchWorkloads: [String: VTEBenchWorkload]
    private let temporaryDirectory: URL?
    private let preparationError: String?

    /// Watchdog queue. Deliberately not the main queue: the whole point is to
    /// survive a main thread that is wedged, which is exactly the state the
    /// binary case can produce. A main-queue timeout would never fire.
    private let watchdogQueue = DispatchQueue(label: "swiftterm-baseline-watchdog",
                                              qos: .userInitiated)
    private var watchdog: DispatchSourceTimer?
    private var completionTimer: DispatchSourceTimer?
    private var measurementEnded = false

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

        var workloads: [String: VTEBenchWorkload] = [:]
        var directory: URL?
        var errorText: String?
        do {
            workloads = Dictionary(uniqueKeysWithValues:
                try VTEBenchWorkloads.makeDefault().map { ($0.name, $0) })
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftterm-ptybench-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false)
            directory = url
        } catch {
            errorText = "Cannot prepare benchmark payloads: \(error)"
        }
        self.vteBenchWorkloads = workloads
        self.temporaryDirectory = directory
        self.preparationError = errorText
    }

    deinit {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    var isRunning: Bool { runningCase != nil }

    /// Runs one case for an interactive menu action. Scripted runs use
    /// `runSuite` so they can add a warm-up and repeats.
    func run(_ loadCase: Case, completion: @escaping (String) -> Void) {
        runSuite(
            cases: [loadCase],
            repeatCount: 1,
            label: "interactive",
            includesWarmUp: false,
            result: { report, machineLine in
                completion(machineLine + "\n" + report)
            },
            completion: {})
    }

    /// Runs each case with one excluded warm-up, then reports every repetition.
    func runSuite(
        cases: [Case],
        repeatCount: Int,
        label: String,
        includesWarmUp: Bool = true,
        result: @escaping (String, String) -> Void,
        completion: @escaping () -> Void
    ) {
        guard runningCase == nil, let firstCase = cases.first else { return }
        guard repeatCount > 0 else {
            result("Benchmark repeat count must be positive.", "")
            completion()
            return
        }

        do {
            for loadCase in cases {
                _ = try preparedCase(for: loadCase)
            }
        } catch {
            result("## PTY benchmark\n\nFAILED: \(error)", "")
            completion()
            return
        }

        var iterations: [Iteration] = []
        for loadCase in cases {
            if includesWarmUp {
                iterations.append(Iteration(
                    loadCase: loadCase,
                    repetition: 0,
                    repetitionCount: repeatCount,
                    isWarmUp: true))
            }
            for repetition in 1...repeatCount {
                iterations.append(Iteration(
                    loadCase: loadCase,
                    repetition: repetition,
                    repetitionCount: repeatCount,
                    isWarmUp: false))
            }
        }

        pendingIterations = iterations
        runningCase = firstCase
        benchmarkLabel = label
        resultHandler = result
        suiteCompletion = completion
        terminal.suspendsRenderingWhenNotVisible = false

        makeWindowVisible { [weak self] in
            self?.prepareShell()
        }
    }

    /// Activates the app and waits for AppKit to mark its window as visible.
    private func makeWindowVisible(then: @escaping () -> Void) {
        let attempts = 100

        func poll(_ attemptsLeft: Int) {
            guard runningCase != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            if let window = terminal.window {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(terminal)
                if window.occlusionState.contains(.visible) {
                    then()
                    return
                }
            }
            guard attemptsLeft > 0 else {
                print("PTYBENCH warning=window_not_visible")
                then()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                poll(attemptsLeft - 1)
            }
        }

        poll(attempts)
    }

    private func prepareShell() {
        // Disable input echo so the command is not part of the byte count.
        // Disable output processing so the PTY does not change LF to CR-LF.
        waitForQuiet(minimumBytes: 0) { [weak self] in
            guard let self else { return }
            self.sendShellCommand("stty -echo -opost")
            self.waitForQuiet(minimumBytes: 0) { [weak self] in
                self?.runNextIteration()
            }
        }
    }

    /// Calls `then` when setup output is quiet. This time is not measured.
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

    private func runNextIteration() {
        guard !pendingIterations.isEmpty else {
            terminal.suspendsRenderingWhenNotVisible = true
            runningCase = nil
            resultHandler = nil
            let completion = suiteCompletion
            suiteCompletion = nil
            completion?()
            return
        }

        let iteration = pendingIterations.removeFirst()
        runningCase = iteration.loadCase
        guard let prepared = preparedCases[iteration.loadCase] else {
            preconditionFailure("The benchmark case was not prepared")
        }

        terminal.resize(
            cols: VTEBenchWorkloads.defaultColumns,
            rows: VTEBenchWorkloads.defaultRows)
        terminal.resetDiagnostics()
        sendShellCommand(prepared.setupCommand)
        waitForQuiet(minimumBytes: prepared.setupByteCount) { [weak self] in
            self?.beginMeasurement(iteration, prepared: prepared)
        }
    }

    private func beginMeasurement(_ iteration: Iteration, prepared: PreparedCase) {
        terminal.resetDiagnostics()
        TerminalProfiling.reset()
        monitor.start()
        startTime = DispatchTime.now()
        measurementEnded = false
        armCompletionTimer(iteration, prepared: prepared)
        armWatchdog(iteration, prepared: prepared)
        sendShellCommand(prepared.payloadCommand)
    }

    /// Clears pending terminal reports before it enters a shell command.
    private func sendShellCommand(_ command: String) {
        terminal.send(txt: "\u{15}" + command + "\n")
    }

    /// Stops the measured interval after the parse thread records all bytes.
    private func armCompletionTimer(_ iteration: Iteration, prepared: PreparedCase) {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.terminal.diagnostics.bytesFed >= prepared.targetByteCount
            else { return }
            self.finishMeasurement(iteration, prepared: prepared, timedOut: false)
        }
        timer.resume()
        completionTimer = timer
    }

    /// Ends the process if one fixed-work interval exceeds its hard limit.
    private func armWatchdog(_ iteration: Iteration, prepared: PreparedCase) {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { [weak self] in
            self?.finishMeasurement(iteration, prepared: prepared, timedOut: true)
        }
        timer.resume()
        watchdog = timer
    }

    private func cancelMeasurementTimers() {
        completionTimer?.cancel()
        completionTimer = nil
        watchdog?.cancel()
        watchdog = nil
    }

    /// Runs on `watchdogQueue`. All captured sources use their own locks.
    private func finishMeasurement(
        _ iteration: Iteration,
        prepared: PreparedCase,
        timedOut: Bool
    ) {
        guard !measurementEnded else { return }
        measurementEnded = true
        cancelMeasurementTimers()
        let elapsed = max(
            0.001,
            Double(DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds)
                / 1_000_000_000.0)
        monitor.stop()
        let diagnostics = terminal.diagnostics
        let summaries = TerminalProfiling.summaries()
        let stalls = monitor.summarize()
        var measurement = buildMeasurement(
            iteration: iteration,
            targetByteCount: prepared.targetByteCount,
            elapsed: elapsed,
            diagnostics: diagnostics,
            summaries: summaries,
            stalls: stalls,
            timedOut: timedOut)

        if timedOut {
            measurement = Measurement(
                report: "**TIMED OUT after \(Int(timeoutSeconds)) s.** "
                    + "The child did not send the fixed payload.\n\n"
                    + measurement.report,
                machineLine: measurement.machineLine)
            print("===BASELINE-BEGIN===")
            print(measurement.machineLine)
            print(measurement.report)
            print("===BASELINE-END===")
            fflush(stdout)
            if terminateOnTimeout {
                exit(3)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !timedOut && !iteration.isWarmUp {
                self.resultHandler?(measurement.report, measurement.machineLine)
            } else if timedOut {
                self.terminal.suspendsRenderingWhenNotVisible = true
                self.runningCase = nil
                self.pendingIterations.removeAll()
                self.resultHandler?(measurement.report, measurement.machineLine)
                self.resultHandler = nil
                let completion = self.suiteCompletion
                self.suiteCompletion = nil
                completion?()
                return
            }
            self.runNextIteration()
        }
    }

    private struct PreparationFailure: Error, CustomStringConvertible {
        let description: String
    }

    private func preparedCase(for loadCase: Case) throws -> PreparedCase {
        if let prepared = preparedCases[loadCase] {
            return prepared
        }
        if let preparationError {
            throw PreparationFailure(description: preparationError)
        }
        guard let temporaryDirectory else {
            throw PreparationFailure(description: "The temporary directory is not available.")
        }

        let workload = try workload(for: loadCase)
        // RIS isolates the workload. The explicit resets are also necessary:
        // SwiftTerm's RIS path does not currently clear focus reporting.
        let resetSequence = "\u{1b}c"
            + "\u{1b}[?1004l"  // Focus reports.
            + "\u{1b}[?2004l"  // Bracketed paste.
            + "\u{1b}[?1000l"  // Basic mouse reports.
            + "\u{1b}[?1002l"  // Button-event mouse reports.
            + "\u{1b}[?1003l"  // Any-event mouse reports.
        let reset = [UInt8](resetSequence.utf8)
        let setup = reset + workload.setup
        let setupURL = temporaryDirectory.appendingPathComponent("\(loadCase.rawValue)-setup.bin")
        try Data(setup).write(to: setupURL, options: .atomic)

        // Keep each file small. One `cat` process reads it more than once.
        // This avoids one process launch for each payload repetition.
        let maximumChunkBytes = 8 * 1024 * 1024
        let repetitionsPerChunk = max(1, maximumChunkBytes / workload.payload.count)
        var chunk: [UInt8] = []
        chunk.reserveCapacity(workload.payload.count * repetitionsPerChunk)
        for _ in 0..<repetitionsPerChunk {
            chunk.append(contentsOf: workload.payload)
        }
        if chunk.count > workload.targetByteCount {
            chunk = Array(chunk.prefix(workload.targetByteCount))
        }

        let payloadURL = temporaryDirectory.appendingPathComponent("\(loadCase.rawValue)-payload.bin")
        try Data(chunk).write(to: payloadURL, options: .atomic)
        let fullChunks = workload.targetByteCount / chunk.count
        let remainder = workload.targetByteCount % chunk.count
        var payloadPaths = Array(repeating: payloadURL.path, count: fullChunks)
        if remainder > 0 {
            let remainderURL = temporaryDirectory
                .appendingPathComponent("\(loadCase.rawValue)-remainder.bin")
            try Data(chunk.prefix(remainder)).write(to: remainderURL, options: .atomic)
            payloadPaths.append(remainderURL.path)
        }

        let prepared = PreparedCase(
            loadCase: loadCase,
            setupCommand: "/bin/cat \(shellQuote(setupURL.path))",
            setupByteCount: setup.count,
            payloadCommand: "/bin/cat " + payloadPaths.map(shellQuote).joined(separator: " "),
            targetByteCount: workload.targetByteCount)
        preparedCases[loadCase] = prepared
        return prepared
    }

    private func workload(for loadCase: Case) throws -> Workload {
        let mebibyte = 1024 * 1024
        switch loadCase {
        case .flood:
            return Workload(
                setup: [],
                payload: [UInt8]("the quick brown fox jumps over the lazy dog 0123456789\n".utf8),
                targetByteCount: 100 * mebibyte)
        case .bidiFlood:
            return Workload(
                setup: [],
                payload: [UInt8]("مرحبا بالعالم שלום עולם hello world 0123456789\n".utf8),
                targetByteCount: 80 * mebibyte)
        case .tui:
            var payload: [UInt8] = []
            let clear = [UInt8]("\u{1b}[2J\u{1b}[H".utf8)
            let rows = [UInt8]((1...40).map(String.init).joined(separator: "\n").appending("\n").utf8)
            for _ in 0..<2_000 {
                payload.append(contentsOf: clear)
                payload.append(contentsOf: rows)
            }
            return Workload(setup: [], payload: payload, targetByteCount: payload.count)
        case .binary:
            return Workload(
                setup: [],
                payload: (0...255).map(UInt8.init),
                targetByteCount: 64 * mebibyte)
        default:
            guard let source = vteBenchWorkloads[loadCase.rawValue] else {
                throw PreparationFailure(
                    description: "The vtebench workload '\(loadCase.rawValue)' is not available.")
            }
            return Workload(
                setup: source.setup,
                payload: source.payload,
                targetByteCount: 100 * mebibyte)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds both output forms from one captured summary set.
    private func buildMeasurement(
        iteration: Iteration,
        targetByteCount: Int,
        elapsed: Double,
        diagnostics: TerminalView.Diagnostics,
        summaries: [IntervalSummary],
        stalls: MainThreadStallMonitor.Summary,
        timedOut: Bool
    ) -> Measurement {
        let measuredBytes = timedOut ? min(diagnostics.bytesFed, targetByteCount) : targetByteCount
        let mbPerSecond = Double(measuredBytes) / elapsed / (1024 * 1024)
        let framesPerSecond = Double(diagnostics.frames) / elapsed

        // Ask the view, never the launch flags. The two say different things
        // the moment a default changes, and a report labelled with the wrong
        // renderer is worse than one with no label.
        let renderer: String
        if terminal.isUsingMetalRenderer {
            renderer = terminal.isUsingRenderLoop ? "Metal, layer + render loop"
                                                  : "Metal, MTKView"
        } else {
            renderer = "CoreGraphics"
        }

        var report = ""
        report += "## \(iteration.loadCase.title) [\(renderer)]\n\n"
        if diagnostics.frames == 0 {
            report += "**INVALID: No frames were produced. Do not compare this run.**\n\n"
        }
        report += "| Measurement | Value |\n| --- | --- |\n"
        report += String(format: "| Elapsed | %.2f s |\n", elapsed)
        report += String(format: "| Bytes fed | %d (%.1f MB) |\n",
                         measuredBytes, Double(measuredBytes) / (1024 * 1024))
        report += String(format: "| Throughput | %.1f MB/s |\n", mbPerSecond)
        report += "| Batches | \(diagnostics.batches) |\n"
        report += "| Mean batch | \(diagnostics.meanBatchBytes) bytes |\n"
        report += String(format: "| Frames | %d (%.1f/s) |\n", diagnostics.frames, framesPerSecond)
        report += "| Renders (actually drawn) | \(diagnostics.renders) |\n"
        if diagnostics.renderLoopFrames > 0 {
            report += "| Render-loop frames | \(diagnostics.renderLoopFrames) |\n"
            report += "| Render-loop coalesced | \(diagnostics.renderLoopCoalesced) |\n"
        }
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

        if diagnostics.metricsCacheLookups > 0 || diagnostics.glyphAtlasLookups > 0 {
            func hitRate(_ hits: Int, _ lookups: Int) -> Double {
                lookups == 0 ? 0 : Double(hits) * 100 / Double(lookups)
            }
            report += "\n### Metal glyph caches\n\n"
            report += "| Measurement | Value |\n| --- | ---: |\n"
            report += "| Metrics lookups | \(diagnostics.metricsCacheLookups) |\n"
            report += "| Metrics hits | \(diagnostics.metricsCacheHits) |\n"
            report += "| Metrics misses | \(diagnostics.metricsCacheMisses) |\n"
            report += String(format: "| Metrics hit rate | %.2f%% |\n",
                             hitRate(diagnostics.metricsCacheHits,
                                     diagnostics.metricsCacheLookups))
            report += "| Glyph-atlas lookups | \(diagnostics.glyphAtlasLookups) |\n"
            report += "| Glyph-atlas hits | \(diagnostics.glyphAtlasHits) |\n"
            report += "| Glyph-atlas misses | \(diagnostics.glyphAtlasMisses) |\n"
            report += String(format: "| Glyph-atlas hit rate | %.2f%% |\n",
                             hitRate(diagnostics.glyphAtlasHits,
                                     diagnostics.glyphAtlasLookups))
            report += "| Permanent-empty hits | \(diagnostics.permanentEmptyGlyphHits) |\n"
            report += String(format: "| Permanent-empty hit rate | %.2f%% |\n",
                             hitRate(diagnostics.permanentEmptyGlyphHits,
                                     diagnostics.glyphAtlasLookups))
            report += "| Full glyph-cache misses | \(diagnostics.fullGlyphCacheMisses) |\n"
            report += String(format: "| Full glyph-cache miss rate | %.2f%% |\n",
                             hitRate(diagnostics.fullGlyphCacheMisses,
                                     diagnostics.glyphAtlasLookups))
            report += "| Rasterizations | \(diagnostics.glyphRasterizations) |\n"
            report += "| Bitmap rasterization results | \(diagnostics.bitmapRasterizationResults) |\n"
            report += "| Empty rasterization results | \(diagnostics.emptyRasterizationResults) |\n"
            report += "| Transient rasterization failures | \(diagnostics.transientRasterizationFailures) |\n"
            report += "| Glyph bounds queries | \(diagnostics.glyphBoundsQueries) |\n"
            report += "| Glyph draw calls | \(diagnostics.glyphDrawCalls) |\n"
            report += "| Negative-cache evictions | \(diagnostics.negativeGlyphCacheEvictions) |\n"
            report += "| Negative-cache high-water | \(diagnostics.negativeGlyphCacheHighWater) |\n"
            report += "| Raster-font registry lookups | \(diagnostics.rasterFontRegistryLookups) |\n"
            report += "| Raster-font registry hits | \(diagnostics.rasterFontRegistryHits) |\n"
            report += "| Raster-font registry misses | \(diagnostics.rasterFontRegistryMisses) |\n"
            report += String(format: "| Raster-font registry hit rate | %.2f%% |\n",
                             hitRate(diagnostics.rasterFontRegistryHits,
                                     diagnostics.rasterFontRegistryLookups))
            report += "| Raster-font registry high-water | \(diagnostics.rasterFontRegistryHighWater) |\n"
            report += "| Raster-font registry teardowns | \(diagnostics.rasterFontRegistryTeardowns) |\n"
            report += "| Drawable hits avoiding metrics | \(diagnostics.drawableHitsAvoidedMetricsLookup) |\n"
            report += "| Drawable hits requiring metrics | \(diagnostics.drawableHitsRequiredMetricsLookup) |\n"
            report += "| Miss metrics reused for fitting | \(diagnostics.metricsReusedFromDrawableMiss) |\n"
            report += "| Metrics-font registry high-water | \(diagnostics.metricsFontRegistryHighWater) |\n"
            report += "| Full font identities aliasing raster identity | \(diagnostics.fullIdentityTokensAliasingRasterIdentity) |\n"
            report += "| Full glyph keys aliasing raster glyph key | \(diagnostics.fullCacheKeysAliasingRasterGlyphKey) |\n"
            report += "| Grayscale atlas grows | \(diagnostics.grayscaleAtlasGrows) |\n"
            report += "| Color atlas grows | \(diagnostics.colorAtlasGrows) |\n"
            report += "| Grayscale atlas resets | \(diagnostics.grayscaleAtlasResets) |\n"
            report += "| Color atlas resets | \(diagnostics.colorAtlasResets) |\n"
            report += "| Metrics entry-limit resets | \(diagnostics.metricsEntryLimitResets) |\n"
            report += "| Metrics font-limit resets | \(diagnostics.metricsFontLimitResets) |\n"
            report += "| Rows rebuilt | \(diagnostics.metalRowsRebuilt) |\n"
            report += "| Atlas-invalidated build attempts | \(diagnostics.atlasInvalidationBuildAttempts) |\n"
        }

        // In-process interval distributions, when SWIFTTERM_PROFILE_STATS=1.
        // These are complete, unlike a log-stream capture under load.
        let intervals = TerminalProfiling.report(summaries: summaries)
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
        let machineLine = buildMachineLine(
            iteration: iteration,
            bytes: measuredBytes,
            elapsed: elapsed,
            mbPerSecond: mbPerSecond,
            diagnostics: diagnostics,
            summaries: summaries,
            stalls: stalls,
            timedOut: timedOut)
        return Measurement(report: report, machineLine: machineLine)
    }

    private func buildMachineLine(
        iteration: Iteration,
        bytes: Int,
        elapsed: Double,
        mbPerSecond: Double,
        diagnostics: TerminalView.Diagnostics,
        summaries: [IntervalSummary],
        stalls: MainThreadStallMonitor.Summary,
        timedOut: Bool
    ) -> String {
        func summary(_ event: String, owner: String? = nil) -> IntervalSummary? {
            summaries.first { $0.event == event && $0.owner == owner }
        }
        func number(_ value: Double, digits: Int) -> String {
            String(
                format: "%.*f",
                locale: Locale(identifier: "en_US_POSIX"),
                arguments: [digits, value])
        }
        func machineValue(_ value: String) -> String {
            let safe = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
                return value
            }
            return shellQuote(value.replacingOccurrences(of: "\n", with: " "))
        }

        let lockHoldParse = summary("Lock.Hold", owner: "parse")
        let lockHoldOther = summary("Lock.Hold", owner: "other")
        let lockWaitParse = summary("Lock.Wait", owner: "parse")
        let frameRefresh = summary("Frame.Refresh")
        let ioParse = summary("IO.Parse")
        let ioBatch = summary("IO.Batch")

        var fields = [
            "PTYBENCH",
            "case=\(iteration.loadCase.rawValue)",
            "build=\(machineValue(benchmarkLabel))",
            "repeat=\(iteration.repetition)/\(iteration.repetitionCount)",
            "bytes=\(bytes)",
            "elapsed_s=\(number(elapsed, digits: 3))",
            "mb_s=\(number(mbPerSecond, digits: 1))",
            "frames=\(diagnostics.frames)",
            "renders=\(diagnostics.renders)",
            "lock_hold_parse_n=\(lockHoldParse?.count ?? 0)",
            "lock_hold_parse_p50=\(number(lockHoldParse?.p50Ms ?? 0, digits: 3))",
            "lock_hold_parse_p99=\(number(lockHoldParse?.p99Ms ?? 0, digits: 3))",
            "lock_hold_parse_total=\(number(lockHoldParse?.totalMs ?? 0, digits: 1))",
            "lock_hold_other_n=\(lockHoldOther?.count ?? 0)",
            "lock_hold_other_p50=\(number(lockHoldOther?.p50Ms ?? 0, digits: 3))",
            "lock_hold_other_p99=\(number(lockHoldOther?.p99Ms ?? 0, digits: 3))",
            "lock_hold_other_total=\(number(lockHoldOther?.totalMs ?? 0, digits: 1))",
            "lock_wait_parse_total=\(number(lockWaitParse?.totalMs ?? 0, digits: 1))",
            "frame_refresh_p50=\(number(frameRefresh?.p50Ms ?? 0, digits: 3))",
            "frame_refresh_p99=\(number(frameRefresh?.p99Ms ?? 0, digits: 3))",
            "frame_refresh_total=\(number(frameRefresh?.totalMs ?? 0, digits: 1))",
            "io_parse_total=\(number(ioParse?.totalMs ?? 0, digits: 1))",
            "io_batch_total=\(number(ioBatch?.totalMs ?? 0, digits: 1))",
            "stall_p99=\(number(stalls.p99Ms, digits: 2))",
            "stall_max=\(number(stalls.maxMs, digits: 2))"
        ]
        if diagnostics.frames == 0 {
            fields.append("status=no_render")
        } else if timedOut {
            fields.append("status=timeout")
        }
        if timedOut {
            fields.append("timed_out=true")
        }
        return fields.joined(separator: " ")
    }
}
