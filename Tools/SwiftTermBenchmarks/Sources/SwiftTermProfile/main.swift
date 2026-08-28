import Dispatch
import Foundation
import SwiftTerm
import VTEBenchWorkloads

private struct Options {
    var workloadName: String
    var iterations = 800
    var warmupIterations = 2
    var minimumByteCount = 1_048_576

    static func parse(_ arguments: [String]) -> Options? {
        guard let workloadName = arguments.first else { return nil }
        var result = Options(workloadName: workloadName)
        var index = 1

        while index < arguments.count {
            guard index + 1 < arguments.count,
                  let value = Int(arguments[index + 1]),
                  value > 0 else {
                return nil
            }
            switch arguments[index] {
            case "--iterations":
                result.iterations = value
            case "--warmup":
                result.warmupIterations = value
            case "--minimum-bytes":
                result.minimumByteCount = value
            default:
                return nil
            }
            index += 2
        }
        return result
    }
}

private func usage() -> Never {
    let names = try! (VTEBenchWorkloads.makeDefault() + VTEBenchWorkloads.makeHardening())
        .map(\.name).joined(separator: ", ")
    FileHandle.standardError.write(Data("""
    usage: SwiftTermProfile WORKLOAD [--iterations N] [--warmup N] [--minimum-bytes N]
    workloads: \(names)

    """.utf8))
    exit(64)
}

guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    usage()
}
let workloads = try VTEBenchWorkloads.makeDefault() + VTEBenchWorkloads.makeHardening()
guard let workload = workloads.first(where: { $0.name == options.workloadName }) else {
    usage()
}

let columns = VTEBenchWorkloads.defaultColumns
let rows = VTEBenchWorkloads.defaultRows
let queue = DispatchQueue(label: "SwiftTermProfile", qos: .userInteractive)
let terminalOptions = TerminalOptions(
    cols: columns,
    rows: rows,
    maximumOscBytes: workload.maximumOscBytes ?? TerminalOptions.default.maximumOscBytes)
let headless = HeadlessTerminal(queue: queue, options: terminalOptions) { _ in }
let terminal = headless.terminal!
let reset = [UInt8]("\u{1b}c".utf8)
let sample = workload.sample(minimumByteCount: options.minimumByteCount)
let sampleChunks = workload.inputChunkSize == nil
    ? nil
    : workload.sampleChunks(minimumByteCount: options.minimumByteCount)

terminal.resize(cols: columns, rows: rows)
terminal.feed(byteArray: reset)
if !workload.setup.isEmpty {
    terminal.feed(byteArray: workload.setup)
}
if let sampleChunks {
    for _ in 0..<options.warmupIterations {
        for chunk in sampleChunks {
            terminal.feed(byteArray: chunk)
        }
    }
} else {
    for _ in 0..<options.warmupIterations {
        terminal.feed(byteArray: sample)
    }
}
#if SWIFTTERM_SEAM_COUNTER
TerminalProfiling.reset()
#endif

let clock = ContinuousClock()
let start = clock.now
if let sampleChunks {
    for _ in 0..<options.iterations {
        for chunk in sampleChunks {
            terminal.feed(byteArray: chunk)
        }
    }
} else {
    for _ in 0..<options.iterations {
        terminal.feed(byteArray: sample)
    }
}
let elapsed = start.duration(to: clock.now)
let seconds = Double(elapsed.components.seconds)
    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
let byteCount = sample.count * options.iterations
let mibPerSecond = Double(byteCount) / 1_048_576 / seconds

print("workload=\(workload.name) iterations=\(options.iterations) bytes=\(byteCount) " +
      String(format: "elapsed_s=%.6f mib_s=%.3f", seconds, mibPerSecond))
#if SWIFTTERM_SEAM_COUNTER
print(TerminalProfiling.seamReport())
#endif
