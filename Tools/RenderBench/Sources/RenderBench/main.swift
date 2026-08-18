//
//  RenderBench: a deterministic render-path benchmark for SwiftTerm.
//
//  Hosts a real TerminalView in an on-screen window and feeds it synthetic
//  frames as fast as the main run loop accepts them, with no PTY or shell in
//  the way. The workload is generated from a fixed seed, so two builds render
//  byte-identical input and their profiles are directly comparable.
//
//  Usage:
//    RenderBench [--metal] [--seconds N]
//                [--scenario dense|medium|scroll|arabic|arabic-line|stalled-frame]
//
//  Scenarios:
//    dense   every cell gets its own truecolor foreground and background
//            (vtebench dense_cells shape: many one-cell attribute runs)
//    medium  a color change every 8 cells (longer runs, fewer segments)
//    scroll  plain ASCII lines that scroll the screen
//    arabic  scrolling Arabic words (exercises the BiDi shaping path)
//    stalled-frame
//            hold the Metal frame permit before the first draw, then feed
//            terminal output. The renderer must recover without a client
//            renderer toggle.
//
//  Profile it with Instruments:
//    swift build -c release
//    xcrun xctrace record --template 'Time Profiler' \
//        --launch -- .build/release/RenderBench --seconds 20
//

import AppKit
import SwiftTerm
import os

var seconds = 15.0
var useMetal = false
var scenario = "dense"

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = argIterator.next() {
    switch argument {
    case "--metal":
        useMetal = true
    case "--seconds":
        seconds = Double(argIterator.next() ?? "") ?? seconds
    case "--scenario":
        scenario = argIterator.next() ?? scenario
    default:
        print("usage: RenderBench [--metal] [--seconds N] " +
              "[--scenario dense|medium|scroll|arabic|arabic-line|stalled-frame]")
        exit(1)
    }
}
guard ["dense", "medium", "scroll", "arabic", "arabic-line", "stalled-frame"].contains(scenario) else {
    print("unknown scenario: \(scenario)")
    exit(1)
}

if scenario == "stalled-frame" {
#if DEBUG
    useMetal = true
    setenv("SWIFTTERM_TEST_METAL_FRAME_PERMIT_HELD", "1", 1)
#else
    print("stalled-frame requires a debug build")
    exit(1)
#endif
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
        case "stalled-frame":
            return coloredFrame(cols: cols, rows: rows, runLength: 1)
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
    private var statusObserver: NSObjectProtocol?
    private var stalledFrameStartedAt: CFAbsoluteTime?
    private var recoveryStartedAt: CFAbsoluteTime?
    private var startedWithBlackPane = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentRect = NSRect(x: 60, y: 200, width: 800, height: 600)
        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled],
                          backing: .buffered,
                          defer: false)
        window.title = "RenderBench: \(scenario)\(useMetal ? " (Metal)" : " (CG)")"
        terminalView = TerminalView(frame: window.contentView!.bounds)
        terminalView.terminalDelegate = terminalViewDelegate
        window.contentView!.addSubview(terminalView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if scenario == "stalled-frame" {
            stalledFrameStartedAt = CFAbsoluteTimeGetCurrent()
            statusObserver = NotificationCenter.default.addObserver(
                forName: .terminalViewMetalRendererStatusDidChange,
                object: terminalView,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if self.terminalView.metalRendererStatus.state == .recovering,
                   self.recoveryStartedAt == nil {
                    self.recoveryStartedAt = CFAbsoluteTimeGetCurrent()
                }
            }
        }

        if useMetal {
            do {
                try terminalView.setUseMetal(true)
#if DEBUG
                if scenario == "stalled-frame" {
                    unsetenv("SWIFTTERM_TEST_METAL_FRAME_PERMIT_HELD")
                }
#endif
            } catch {
#if DEBUG
                if scenario == "stalled-frame" {
                    unsetenv("SWIFTTERM_TEST_METAL_FRAME_PERMIT_HELD")
                }
#endif
                print("METAL UNAVAILABLE: \(error)")
                exit(1)
            }
        }

        let t = terminalView.getTerminal()
        print("renderer=\(useMetal ? "metal" : "cg") scenario=\(scenario) " +
              "cols=\(t.cols) rows=\(t.rows) seconds=\(seconds)")
        if scenario == "stalled-frame" {
            print("FAULT ACTIVE: the Metal frame permit is held before the first draw.")
            print("EXPECTED: recovery starts after about one second and Metal presents a frame.")
            let status = terminalView.metalRendererStatus
            startedWithBlackPane = status.state == .waitingForFirstFrame
                && status.presentedFrameCount == 0
        }
        startTime = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { self.tick() }
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
            if scenario == "stalled-frame" {
                validateStalledFrameRecovery()
            }
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

    private func validateStalledFrameRecovery() {
        let status = terminalView.metalRendererStatus
        let recoveryDelay = recoveryStartedAt.flatMap { recoveryAt in
            stalledFrameStartedAt.map { recoveryAt - $0 }
        }
        var failures: [String] = []
        if !startedWithBlackPane {
            failures.append("the first renderer did not start without a presented frame")
        }
        if frameCount == 0 || byteCount == 0 {
            failures.append("the terminal did not accept synthetic output")
        }
        if let recoveryDelay {
            if recoveryDelay < 0.75 || recoveryDelay > 2.5 {
                failures.append(String(format: "recovery started after %.3f seconds", recoveryDelay))
            }
        } else {
            failures.append("recovery did not start")
        }
        if status.state != .healthy {
            failures.append("renderer state is \(status.state), not healthy")
        }
        if status.presentedFrameCount == 0 {
            failures.append("no drawable was presented")
        }
        if !terminalView.isUsingMetalRenderer {
            failures.append("Metal was disabled after the one-time fault")
        }

        if failures.isEmpty {
            print("RECOVERED: Metal presented \(status.presentedFrameCount) frames and remains enabled.")
            return
        }
        for failure in failures {
            print("FAILED: \(failure)")
        }
        exit(2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
