#if os(macOS)
import Benchmark
import Dispatch
import Foundation
import SwiftTerm

private enum SwiftTermBenchmarks {
    static let queue: DispatchQueue = {
        DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)
    }()
}

private func testFeed(benchmark: Benchmark, data: [UInt8], innerIterations: Int) {
    let h = HeadlessTerminal(queue: SwiftTermBenchmarks.queue) { _ in }
    let t = h.terminal!

    t.feed(text: "\u{1b}[38;2;19;49;174;48;2;23;56;179mStringThis is a very long line\n\r")

    benchmark.startMeasurement()
    for _ in benchmark.scaledIterations {
        for _ in 0..<innerIterations {
            t.feed(byteArray: data)
        }
    }
    benchmark.stopMeasurement()
}

let benchmarks: @Sendable () -> Void = {
    Benchmark("testPerformance", configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))) { benchmark in
        let data = [UInt8]("pointless repetition\n".utf8)
        testFeed(benchmark: benchmark, data: data, innerIterations: 1_000)
    }

    Benchmark("testPerformance2", configuration: .init(metrics: [.wallClock], maxDuration: .seconds(10))) { benchmark in
        let data = [UInt8]("pointless repetition\n".utf8)
        testFeed(benchmark: benchmark, data: data, innerIterations: 1_000)
    }
}
#else
let benchmarks: @Sendable () -> Void = { }
#endif
