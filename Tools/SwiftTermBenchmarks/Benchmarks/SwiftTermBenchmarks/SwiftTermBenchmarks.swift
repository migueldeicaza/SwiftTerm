#if os(macOS)
import Benchmark
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
}

private func feed(_ benchmark: Benchmark, workload: VTEBenchWorkload) {
    let headlessTerminal = HeadlessTerminal(queue: SwiftTermBenchmarks.queue) { _ in }
    let terminal = headlessTerminal.terminal!
    terminal.resize(cols: SwiftTermBenchmarks.columns, rows: SwiftTermBenchmarks.rows)
    terminal.feed(byteArray: SwiftTermBenchmarks.reset)
    if !workload.setup.isEmpty {
        terminal.feed(byteArray: workload.setup)
    }
    let sample = workload.sample()

    benchmark.startMeasurement()
    for _ in benchmark.scaledIterations {
        terminal.feed(byteArray: sample)
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
}
#else
let benchmarks: @Sendable () -> Void = { }
#endif
