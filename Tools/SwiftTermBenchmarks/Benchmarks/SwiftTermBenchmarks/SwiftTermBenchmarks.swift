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

    Benchmark(
        "kitty_snapshot_empty",
        configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
    ) { benchmark in
        snapshot(benchmark, imageSize: nil)
    }

    Benchmark(
        "kitty_snapshot_3mb",
        configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))
    ) { benchmark in
        snapshot(benchmark, imageSize: (width: 1024, height: 768))
    }
}
#else
let benchmarks: @Sendable () -> Void = { }
#endif
