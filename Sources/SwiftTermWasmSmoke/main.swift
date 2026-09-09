import SwiftTerm

private final class WasmTerminalDelegate: TerminalDelegate {
    var sentBytes: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { sentBytes.append(contentsOf: data) }
}

@main
struct SwiftTermWasmSmoke {
    static func main() {
        let delegate = WasmTerminalDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 8, rows: 2, scrollback: 0))
        terminal.feed(text: "WASM")
        let output = terminal.getBufferAsData()
        terminal.close()
        guard output.starts(with: [87, 65, 83, 77]) else { fatalError("SwiftTerm WASM smoke check failed") }
        print("SwiftTerm WASM smoke check passed")
    }
}
