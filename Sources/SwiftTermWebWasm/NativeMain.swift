#if !arch(wasm32)
import SwiftTerm
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Native reference used by the cross-runtime corpus tests.
private func nativeSnapshotFailure(_ message: String) -> Never {
    let bytes = Array((message + "\n").utf8)
    _ = bytes.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
    exit(1)
}

func nativeSnapshotMain() {
    guard CommandLine.arguments.dropFirst().contains("--snapshot") else { return }
    var input: [UInt8] = []
    var block = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = block.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
        if count == 0 { break }
        if count < 0 || count > ABI.maximumWrite - input.count { nativeSnapshotFailure("The input read failed or exceeded 16 MiB.") }
        input.append(contentsOf: block.prefix(count))
    }
    let entry = TerminalEntry(cols: 80, rows: 24, scrollback: 0)
    entry.terminal.feed(buffer: input[...])
    if entry.host.queueFailure { nativeSnapshotFailure("The terminal queue limit was reached.") }
    var output: [UInt8] = []
    let source = entry.terminal.makeRenderSnapshot(scope: .full)
    guard SnapshotEncoder.encode(source, generation: 1, focused: true, into: &output) else { nativeSnapshotFailure("The snapshot exceeds its limit.") }
    var written = 0
    while written < output.count {
        let count = output.withUnsafeBytes { write(1, $0.baseAddress!.advanced(by: written), $0.count - written) }
        if count <= 0 { nativeSnapshotFailure("The snapshot write failed.") }
        written += count
    }
}
#endif
