#if os(macOS)
import Benchmark
import Foundation
import Dispatch
import SwiftTerm
import VTEBenchWorkloads

private enum SwiftTermBenchmarks {
    static let columns = VTEBenchWorkloads.defaultColumns
    static let rows = VTEBenchWorkloads.defaultRows
    static let reset = [UInt8]("\u{1b}c".utf8)
    static let queue = DispatchQueue(
        label: "SwiftTermBenchmarks",
        qos: .userInteractive,
        attributes: .concurrent)
    static let workloads = try! VTEBenchWorkloads.makeDefault(
        columns: columns,
        rows: rows)
    static let hardeningWorkloads = VTEBenchWorkloads.makeHardening(
        columns: columns,
        rows: rows)
    static let hyperlinkWorkloads = VTEBenchWorkloads.makeHyperlink(
        columns: columns,
        rows: rows)
}

private func feed(_ benchmark: Benchmark, workload: VTEBenchWorkload) {
    let options = TerminalOptions(
        cols: SwiftTermBenchmarks.columns,
        rows: SwiftTermBenchmarks.rows,
        maximumOscBytes: workload.maximumOscBytes ?? TerminalOptions.default.maximumOscBytes)
    let headlessTerminal = HeadlessTerminal(queue: SwiftTermBenchmarks.queue, options: options) { _ in }
    let terminal = headlessTerminal.terminal!
    terminal.resize(cols: SwiftTermBenchmarks.columns, rows: SwiftTermBenchmarks.rows)
    terminal.feed(byteArray: SwiftTermBenchmarks.reset)
    if !workload.setup.isEmpty {
        terminal.feed(byteArray: workload.setup)
    }
    if workload.inputChunkSize == nil {
        // Keep the default vtebench timing loop unchanged. A loop over one
        // synthetic chunk is measurable in the fastest cases.
        let sample = workload.sample()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            terminal.feed(byteArray: sample)
        }
        benchmark.stopMeasurement()
    } else {
        let sampleChunks = workload.sampleChunks()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            for chunk in sampleChunks {
                terminal.feed(byteArray: chunk)
            }
        }
        benchmark.stopMeasurement()
    }
    checkHyperlinks(terminal, workload: workload)
}

/// Stops the run when the links that a workload prints do not resolve.
///
/// A terminal that runs out of link codes prints the text without its link,
/// and is faster. The check runs after measurement, so it costs no time.
private func checkHyperlinks(_ terminal: Terminal, workload: VTEBenchWorkload) {
    if let uri = workload.lastHyperlink {
        let found = (0..<terminal.rows).contains { row in
            (0..<terminal.cols).contains { column in
                linkURI(terminal.getCharData(col: column, row: row)?.getPayload()) == uri
            }
        }
        precondition(found, "\(workload.name): the link \(uri) does not resolve")
    }
    // All payloads end the active link, so new text must have no link.
    terminal.feed(byteArray: [UInt8]("\u{1b}[HZ".utf8))
    precondition(terminal.getCharData(col: 0, row: 0)?.getPayload() == nil,
                 "\(workload.name): the link was not closed")
}

/// Returns the URI of a cell's OSC 8 payload, which has the form `params;uri`.
private func linkURI(_ payload: Any?) -> String? {
    guard let payload = payload as? String, let separator = payload.firstIndex(of: ";") else {
        return nil
    }
    return String(payload[payload.index(after: separator)...])
}

/// Measures link lookup for each cell of a screen that shows one link.
///
/// This is the nearest SwiftTerm match to the lookup mode of Ghostty's
/// `hyperlink-map` benchmark. SwiftTerm keeps the link code in the cell, so
/// there is no separate map to measure. One iteration reads every cell once.
private func hyperlinkLookup(_ benchmark: Benchmark) {
    let columns = SwiftTermBenchmarks.columns
    let rows = SwiftTermBenchmarks.rows
    let uri = "https://example.com/benchmark"
    let headlessTerminal = HeadlessTerminal(queue: SwiftTermBenchmarks.queue) { _ in }
    let terminal = headlessTerminal.terminal!
    terminal.resize(cols: columns, rows: rows)
    terminal.feed(byteArray: SwiftTermBenchmarks.reset)
    terminal.feed(byteArray: [UInt8](
        "\u{1b}[H\u{1b}]8;;\(uri)\u{1b}\\\(String(repeating: "x", count: columns * rows))\u{1b}]8;;\u{1b}\\".utf8))
    for row in 0..<rows {
        for column in 0..<columns {
            precondition(linkURI(terminal.getCharData(col: column, row: row)?.getPayload()) == uri,
                         "cell \(column),\(row) does not resolve to the link")
        }
    }

    var missing = 0
    benchmark.startMeasurement()
    for _ in benchmark.scaledIterations {
        for row in 0..<rows {
            for column in 0..<columns {
                let payload = terminal.getCharData(col: column, row: row)?.getPayload()
                if payload == nil {
                    missing += 1
                }
                blackHole(payload)
            }
        }
    }
    benchmark.stopMeasurement()
    precondition(missing == 0, "\(missing) lookups did not find the link")
}

/// A deterministic RGBA payload. Content does not matter to the snapshot cost,
/// only its size, but a varying pattern keeps a compressor from flattering it.
private func syntheticRGBA(width: Int, height: Int) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            bytes.append(UInt8(truncatingIfNeeded: x))
            bytes.append(UInt8(truncatingIfNeeded: y))
            bytes.append(UInt8(truncatingIfNeeded: x &* y))
            bytes.append(255)
        }
    }
    return bytes
}

/// Measures `kittyGraphicsRenderSnapshot()`, which a renderer calls once per
/// frame through `TerminalSnapshot`.
///
/// This is the only benchmark in the repository that puts an image on screen.
/// The vtebench workloads never do, so they cannot see per-image snapshot cost
/// at all — which is exactly how a full pixel copy per frame went unnoticed.
/// Run the two cases together: `kitty_snapshot_empty` is the fixed overhead and
/// `kitty_snapshot_3mb` adds one 1024x768 image, so the difference is what one
/// live image costs per frame.
private func snapshot(_ benchmark: Benchmark, imageSize: (width: Int, height: Int)?) {
    let headlessTerminal = HeadlessTerminal(queue: SwiftTermBenchmarks.queue) { _ in }
    let terminal = headlessTerminal.terminal!
    terminal.resize(cols: SwiftTermBenchmarks.columns, rows: SwiftTermBenchmarks.rows)
    terminal.feed(byteArray: SwiftTermBenchmarks.reset)

    if let imageSize {
        let pixels = syntheticRGBA(width: imageSize.width, height: imageSize.height)
        let encoded = Data(pixels).base64EncodedString()
        // a=T transmits and displays, so the image carries a placement and the
        // snapshot has to build both the image table and the placement list.
        let control = "a=T,f=32,s=\(imageSize.width),v=\(imageSize.height),i=1,C=1"
        terminal.feed(byteArray: [UInt8]("\u{1b}_G\(control);\(encoded)\u{1b}\\".utf8))
        precondition(terminal.kittyGraphicsRenderSnapshot().imagesById[1] != nil,
                     "the image did not reach the snapshot; the benchmark would measure nothing")
    }

    benchmark.startMeasurement()
    for _ in benchmark.scaledIterations {
        blackHole(terminal.kittyGraphicsRenderSnapshot())
    }
    benchmark.stopMeasurement()
}

let benchmarks: @Sendable () -> Void = {
    for workload in SwiftTermBenchmarks.workloads {
        Benchmark(
            workload.name,
            configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
        ) { benchmark in
            feed(benchmark, workload: workload)
        }
    }

    if ProcessInfo.processInfo.environment["SWIFTTERM_HARDENING_BENCHMARKS"] == "1" {
        for workload in SwiftTermBenchmarks.hardeningWorkloads {
            Benchmark(
                workload.name,
                configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
            ) { benchmark in
                feed(benchmark, workload: workload)
            }
        }
    }

    if ProcessInfo.processInfo.environment["SWIFTTERM_OSC8_BENCHMARKS"] == "1" {
        for workload in SwiftTermBenchmarks.hyperlinkWorkloads {
            Benchmark(
                workload.name,
                configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
            ) { benchmark in
                feed(benchmark, workload: workload)
            }
        }

        Benchmark(
            "osc8_lookup",
            // Each scaled iteration reads all 2,000 cells once.
            configuration: .init(metrics: [.wallClock], scalingFactor: .kilo, maxDuration: .seconds(10))
        ) { benchmark in
            hyperlinkLookup(benchmark)
        }
    }

    Benchmark(
        "kitty_snapshot_empty",
        // Batch short snapshot calls to reduce timer quantization error.
        configuration: .init(metrics: [.wallClock], scalingFactor: .kilo, maxDuration: .seconds(10))
    ) { benchmark in
        snapshot(benchmark, imageSize: nil)
    }

    Benchmark(
        "kitty_snapshot_3mb",
        configuration: .init(metrics: [.wallClock], scalingFactor: .kilo, maxDuration: .seconds(10))
    ) { benchmark in
        snapshot(benchmark, imageSize: (width: 1024, height: 768))
    }
}
#else
let benchmarks: @Sendable () -> Void = { }
#endif
