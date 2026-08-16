//
//  RenderBench: a deterministic render-path benchmark for SwiftTerm.
//
//  Hosts a real TerminalView in an on-screen window and feeds it synthetic
//  frames as fast as the main run loop accepts them, with no PTY or shell in
//  the way. The workload is generated from a fixed seed, so two builds render
//  byte-identical input and their profiles are directly comparable.
//
//  Usage:
//    RenderBench [--metal] [--seconds N] [--scenario dense|medium|scroll|arabic|arabic-line]
//    RenderBench [--metal] [--seconds N] --vtebench NAME|all
//    RenderBench --list-vtebench
//
//  Scenarios:
//    dense   every cell gets its own truecolor foreground and background
//            (vtebench dense_cells shape: many one-cell attribute runs)
//    medium  a color change every 8 cells (longer runs, fewer segments)
//    scroll  plain ASCII lines that scroll the screen
//    arabic  scrolling Arabic words (exercises the BiDi shaping path)
//
//  Profile it with Instruments:
//    swift build -c release
//    xcrun xctrace record --template 'Time Profiler' \
//        --launch -- .build/release/RenderBench --seconds 20
//

import AppKit
import SwiftTerm
import VTEBenchWorkloads
import os

let usage = """
    usage: RenderBench [--metal] [--seconds N] [--scenario dense|medium|scroll|arabic|arabic-line]
           RenderBench [--metal] [--seconds N] --vtebench NAME|all
           RenderBench --list-vtebench
    """

var seconds = 15.0
var useMetal = false
var scenario = "dense"
var scenarioWasSpecified = false
var vteBenchSelection: String?
var listVTEBenchWorkloads = false

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = argIterator.next() {
    switch argument {
    case "--metal":
        useMetal = true
    case "--seconds":
        guard let value = argIterator.next(), !value.hasPrefix("--"),
              let parsedSeconds = Double(value), parsedSeconds.isFinite,
              parsedSeconds > 0
        else {
            print("--seconds requires a number greater than zero")
            exit(1)
        }
        seconds = parsedSeconds
    case "--scenario":
        scenario = argIterator.next() ?? scenario
        scenarioWasSpecified = true
    case "--vtebench":
        guard let selection = argIterator.next(), !selection.hasPrefix("--") else {
            print("--vtebench requires a workload name or 'all'")
            print(usage)
            exit(1)
        }
        vteBenchSelection = selection
    case "--list-vtebench":
        listVTEBenchWorkloads = true
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        if argument.hasPrefix("--vtebench=") {
            vteBenchSelection = String(argument.dropFirst("--vtebench=".count))
        } else {
            print(usage)
            exit(1)
        }
    }
}
guard seconds.isFinite, seconds > 0 else {
    print("--seconds must be greater than zero")
    exit(1)
}
guard ["dense", "medium", "scroll", "arabic", "arabic-line"].contains(scenario) else {
    print("unknown scenario: \(scenario)")
    exit(1)
}
guard !(scenarioWasSpecified && vteBenchSelection != nil) else {
    print("--scenario and --vtebench cannot be used together")
    exit(1)
}

guard let allVTEBenchWorkloads = try? VTEBenchWorkloads.makeDefault() else {
    print("could not load the vtebench workloads")
    exit(1)
}
if listVTEBenchWorkloads {
    for workload in allVTEBenchWorkloads {
        print(workload.name)
    }
    exit(0)
}

let selectedVTEBenchWorkloads: [VTEBenchWorkload]
if let selection = vteBenchSelection {
    if selection == "all" {
        selectedVTEBenchWorkloads = allVTEBenchWorkloads
    } else if let workload = allVTEBenchWorkloads.first(where: { $0.name == selection }) {
        selectedVTEBenchWorkloads = [workload]
    } else {
        print("unknown vtebench workload: \(selection)")
        print("available workloads: \(allVTEBenchWorkloads.map(\.name).joined(separator: ", "))")
        exit(1)
    }
} else {
    selectedVTEBenchWorkloads = []
}

/// Deterministic generator so every run feeds identical bytes.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int {
        Int(next() % UInt64(n))
    }
}

final class BenchDelegate: NSObject, TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class FrameSource {
    private var rng = SplitMix64(state: 42)
    private let scenario: String
    private let arabicWords = [
        "السلام", "عليكم", "مرحبا", "بالعالم", "هذا", "اختبار",
        "الأداء", "للنص", "العربي", "طرفية", "سويفت", "تيرم",
    ]

    init(scenario: String) {
        self.scenario = scenario
    }

    func nextFrame(cols: Int, rows: Int) -> [UInt8] {
        switch scenario {
        case "dense":
            return coloredFrame(cols: cols, rows: rows, runLength: 1)
        case "medium":
            return coloredFrame(cols: cols, rows: rows, runLength: 8)
        case "scroll":
            return scrollChunk(cols: cols, rows: rows)
        case "arabic-line":
            return arabicLine()
        default:
            return arabicChunk(rows: rows)
        }
    }

    /// One full screen addressed row by row; every `runLength` cells switch to
    /// a fresh truecolor foreground and background.
    private func coloredFrame(cols: Int, rows: Int, runLength: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(rows * cols * 40 / runLength + rows * cols)
        for row in 1...rows {
            out.append(contentsOf: Array("\u{1b}[\(row);1H".utf8))
            var col = 0
            while col < cols {
                let fg = (rng.below(216), rng.below(216), rng.below(216))
                let bg = (rng.below(216), rng.below(216), rng.below(216))
                out.append(contentsOf: Array(
                    "\u{1b}[38;2;\(fg.0);\(fg.1);\(fg.2);48;2;\(bg.0);\(bg.1);\(bg.2)m".utf8))
                for _ in 0..<min(runLength, cols - col) {
                    out.append(UInt8(33 + rng.below(93)))
                }
                col += runLength
            }
        }
        return out
    }

    /// One screenful of plain ASCII lines, newline-terminated so the terminal
    /// scrolls.
    private func scrollChunk(cols: Int, rows: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(rows * (cols + 2))
        for _ in 0..<rows {
            for _ in 0..<(cols - 1) {
                out.append(UInt8(97 + rng.below(26)))
            }
            out.append(contentsOf: [13, 10])
        }
        return out
    }

    /// One screenful of scrolling Arabic word lines.
    private func arabicChunk(rows: Int) -> [UInt8] {
        var out: [UInt8] = []
        for _ in 0..<rows {
            out.append(contentsOf: arabicLine())
        }
        return out
    }

    /// A single scrolling Arabic line per tick: the interactive pattern, where
    /// the visible rows are redrawn many times while their content is
    /// unchanged (exercises the BiDi paragraph caches).
    private func arabicLine() -> [UInt8] {
        var line = ""
        for i in 0..<10 {
            if i > 0 {
                line += " "
            }
            line += arabicWords[rng.below(arabicWords.count)]
        }
        var out = Array(line.utf8)
        out.append(contentsOf: [13, 10])
        return out
    }
}

/// Counts completed presentations from either the main or Metal thread.
final class PresentationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let signposter = OSSignposter(subsystem: "org.tirania.SwiftTerm", category: "RenderBench")
    private var window: NSWindow!
    private var terminalView: TerminalView!
    private let terminalViewDelegate = BenchDelegate()
    private let frames = FrameSource(scenario: scenario)
    private var frameCount = 0
    private var byteCount = 0
    private var startTime: CFAbsoluteTime = 0
    private var lastReportedSecond = 0
    private let presentationCounter = PresentationCounter()
    private var vteBenchWorkloadIndex = 0
    private var vteBenchSample: [UInt8] = []
    private var presentationTimedOut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentRect = NSRect(x: 60, y: 200, width: 800, height: 600)
        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled],
                          backing: .buffered,
                          defer: false)
        let runName = selectedVTEBenchWorkloads.isEmpty ? scenario : "vtebench"
        window.title = "RenderBench: \(runName)\(useMetal ? " (Metal)" : " (CG)")"
        terminalView = TerminalView(frame: window.contentView!.bounds)
        terminalView.terminalDelegate = terminalViewDelegate
        if useMetal {
            do {
                try terminalView.setUseMetal(true)
            } catch {
                print("METAL UNAVAILABLE: \(error)")
                exit(1)
            }
        }
        window.contentView!.addSubview(terminalView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if selectedVTEBenchWorkloads.isEmpty {
            let terminal = terminalView.getTerminal()
            print("renderer=\(rendererName) scenario=\(scenario) " +
                  "cols=\(terminal.cols) rows=\(terminal.rows) seconds=\(seconds)")
            startTime = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async { self.tick() }
        } else {
            let counter = presentationCounter
            TerminalView.onFramePresented = {
                counter.record()
            }
            print("renderer=\(rendererName) mode=vtebench " +
                  "cases=\(selectedVTEBenchWorkloads.count) " +
                  "cols=\(VTEBenchWorkloads.defaultColumns) " +
                  "rows=\(VTEBenchWorkloads.defaultRows) seconds_per_case=\(seconds)")
            prepareVTEBenchWorkload()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TerminalView.onFramePresented = nil
    }

    private func tick() {
        let t = terminalView.getTerminal()
        let payload = frames.nextFrame(cols: t.cols, rows: t.rows)

        let interval = signposter.beginInterval("feed")
        terminalView.feed(byteArray: payload[...])
        signposter.endInterval("feed", interval)

        frameCount += 1
        byteCount += payload.count

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        if Int(elapsed) > lastReportedSecond {
            lastReportedSecond = Int(elapsed)
            report(elapsed: elapsed, prefix: "  t=\(lastReportedSecond)s")
        }
        if elapsed >= seconds {
            report(elapsed: elapsed, prefix: "TOTAL")
            exit(0)
        }
        DispatchQueue.main.async { self.tick() }
    }

    private func report(elapsed: Double, prefix: String) {
        let mbps = Double(byteCount) / 1e6 / elapsed
        let fps = Double(frameCount) / elapsed
        print(String(format: "%@ frames=%d bytes=%d %.1f MB/s %.1f frames/s",
                     prefix, frameCount, byteCount, mbps, fps))
    }

    private var rendererName: String {
        if !terminalView.isUsingMetalRenderer {
            return "cg"
        }
        return terminalView.isUsingRenderLoop ? "metal-layer" : "metal-mtk"
    }

    /// Resets and sets up one vtebench case outside the measured interval.
    private func prepareVTEBenchWorkload() {
        guard vteBenchWorkloadIndex < selectedVTEBenchWorkloads.count else {
            TerminalView.onFramePresented = nil
            print("VTEBENCH COMPLETE cases=\(selectedVTEBenchWorkloads.count) " +
                  "settlement=\(presentationTimedOut ? "timeout" : "complete")")
            fflush(stdout)
            if presentationTimedOut {
                exit(3)
            } else {
                NSApp.terminate(nil)
            }
            return
        }

        let workload = selectedVTEBenchWorkloads[vteBenchWorkloadIndex]
        terminalView.resize(
            cols: VTEBenchWorkloads.defaultColumns,
            rows: VTEBenchWorkloads.defaultRows)
        terminalView.feed(byteArray: [UInt8]("\u{1b}c".utf8)[...])
        if !workload.setup.isEmpty {
            terminalView.feed(byteArray: workload.setup[...])
        }
        vteBenchSample = workload.sample()

        // Let reset/setup reach the screen before diagnostics and timing start.
        let presentation = presentationCounter.value
        terminalView.requestRedraw()
        waitForPresentationToSettle(after: presentation, timeout: 2.0) { [weak self] settled in
            guard let self else { return }
            if !settled {
                self.presentationTimedOut = true
            }
            self.beginVTEBenchMeasurement()
        }
    }

    private func beginVTEBenchMeasurement() {
        let terminal = terminalView.getTerminal()
        guard terminal.cols == VTEBenchWorkloads.defaultColumns,
              terminal.rows == VTEBenchWorkloads.defaultRows
        else {
            print("terminal size changed before measurement: \(terminal.cols)x\(terminal.rows)")
            exit(2)
        }

        terminalView.resetDiagnostics()
        frameCount = 0
        byteCount = 0
        lastReportedSecond = 0
        startTime = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { self.tickVTEBenchWorkload() }
    }

    private func tickVTEBenchWorkload() {
        let interval = signposter.beginInterval("vtebench.feed")
        terminalView.feed(byteArray: vteBenchSample[...])
        signposter.endInterval("vtebench.feed", interval)

        frameCount += 1
        byteCount += vteBenchSample.count
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        if Int(elapsed) > lastReportedSecond {
            lastReportedSecond = Int(elapsed)
            let workload = selectedVTEBenchWorkloads[vteBenchWorkloadIndex]
            let mbps = Double(byteCount) / 1e6 / elapsed
            print(String(format: "  case=%@ t=%ds samples=%d %.1f MB/s",
                         workload.name, lastReportedSecond, frameCount, mbps))
        }

        if elapsed >= seconds {
            finishVTEBenchMeasurement(elapsed: elapsed)
            return
        }
        DispatchQueue.main.async { self.tickVTEBenchWorkload() }
    }

    /// Waits for the final dirty frame before it reads diagnostics and exits.
    private func finishVTEBenchMeasurement(elapsed: Double) {
        let measuredDiagnostics = terminalView.diagnostics
        let presentation = presentationCounter.value
        terminalView.requestRedraw()
        waitForPresentationToSettle(after: presentation, timeout: 2.0) { [weak self] settled in
            guard let self else { return }
            if !settled {
                self.presentationTimedOut = true
            }
            self.reportVTEBenchResult(
                elapsed: elapsed,
                measuredDiagnostics: measuredDiagnostics,
                settled: settled)
            self.vteBenchWorkloadIndex += 1
            DispatchQueue.main.async { self.prepareVTEBenchWorkload() }
        }
    }

    private func reportVTEBenchResult(
        elapsed: Double,
        measuredDiagnostics: TerminalView.Diagnostics,
        settled: Bool
    ) {
        let workload = selectedVTEBenchWorkloads[vteBenchWorkloadIndex]
        let finalDiagnostics = terminalView.diagnostics
        let mbps = Double(byteCount) / 1e6 / elapsed
        let feedsPerSecond = Double(frameCount) / elapsed
        let renderFPS = Double(measuredDiagnostics.renders) / elapsed

        print(String(
            format: "VTEBENCH name=%@ renderer=%@ elapsed=%.3f samples=%d " +
                "sample_bytes=%d bytes=%d MB/s=%.1f feeds/s=%.1f " +
                "frames=%d renders=%d render_fps=%.1f ticks=%d " +
                "coalesced=%d idle=%d main_hops=%d " +
                "final_frames=%d final_renders=%d settled=%@",
            workload.name,
            rendererName,
            elapsed,
            frameCount,
            vteBenchSample.count,
            byteCount,
            mbps,
            feedsPerSecond,
            measuredDiagnostics.frames,
            measuredDiagnostics.renders,
            renderFPS,
            measuredDiagnostics.ticks,
            measuredDiagnostics.renderLoopCoalesced,
            measuredDiagnostics.idleTicks,
            measuredDiagnostics.mainHops,
            finalDiagnostics.frames,
            finalDiagnostics.renders,
            settled ? "yes" : "timeout"))
        fflush(stdout)
    }

    /// Requires one post-marker presentation followed by a short quiet period.
    /// The timeout prevents a hidden or unavailable window from blocking CI.
    private func waitForPresentationToSettle(
        after baseline: Int,
        timeout: Double,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        var lastCount = presentationCounter.value
        var lastChange = CFAbsoluteTimeGetCurrent()

        func poll() {
            let now = CFAbsoluteTimeGetCurrent()
            let count = presentationCounter.value
            if count != lastCount {
                lastCount = count
                lastChange = now
            }
            if count > baseline && now - lastChange >= 0.075 {
                completion(true)
                return
            }
            if now >= deadline {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
