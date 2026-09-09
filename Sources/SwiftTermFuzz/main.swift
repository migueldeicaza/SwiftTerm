#if os(macOS)
import Foundation
import SwiftTerm

private final class FuzzTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

private func makeTerminal() -> (Terminal, FuzzTerminalDelegate) {
    let delegate = FuzzTerminalDelegate()
    let terminal = Terminal(
        delegate: delegate,
        options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))
    terminal.silentLog = true
    return (terminal, delegate)
}

/// Ports Ghostty's parser, stream, and OSC fuzz-target shapes into one
/// libFuzzer entry point. The first byte selects the target.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzMe(data: UnsafePointer<UInt8>, length: Int) -> CInt {
    guard length > 0 else { return 0 }
    let input = Array(UnsafeBufferPointer(start: data, count: Int(length)))
    let (terminal, delegate) = makeTerminal()

    switch input[0] % 3 {
    case 0:
        // Parser target: arbitrary VT input, one byte at a time.
        for byte in input.dropFirst() {
            terminal.feed(byteArray: [byte])
        }
    case 1:
        // Stream target: choose the slice or byte-at-a-time input path.
        guard input.count > 1 else { return 0 }
        let payload = input.dropFirst(2)
        if input[1] & 1 == 0 {
            terminal.feed(buffer: payload)
        } else {
            for byte in payload {
                terminal.feed(byteArray: [byte])
            }
        }
    default:
        // OSC target: choose BEL, C1 ST, or a missing terminator.
        guard input.count > 1 else { return 0 }
        var framed: [UInt8] = [0x1b, 0x5d]
        framed.append(contentsOf: input.dropFirst(2))
        switch input[1] % 3 {
        case 0: framed.append(0x07)
        case 1: framed.append(0x9c)
        default: break
        }
        terminal.feed(byteArray: framed)
    }

    withExtendedLifetime(delegate) {}
    return 0
}
#endif
