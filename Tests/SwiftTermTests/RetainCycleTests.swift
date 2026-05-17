#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

private class NoOpTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class RetainCycleTests {

    @Test("Terminal deallocates after resetNormalBuffer()")
    func terminalDeallocatesAfterResetNormalBuffer() {
        weak var weakTerminal: Terminal?

        autoreleasepool {
            let delegate = NoOpTerminalDelegate()
            let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))
            weakTerminal = terminal
            terminal.resetNormalBuffer()
        }

        #expect(weakTerminal == nil, "Terminal leaked — retain cycle in resetNormalBuffer() scroll closure")
    }

    @Test("Terminal deallocates after resetToInitialState()")
    func terminalDeallocatesAfterResetToInitialState() {
        weak var weakTerminal: Terminal?

        autoreleasepool {
            let delegate = NoOpTerminalDelegate()
            let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))
            weakTerminal = terminal
            terminal.resetToInitialState()
        }

        #expect(weakTerminal == nil, "Terminal leaked — retain cycle after resetToInitialState()")
    }
}
#endif
