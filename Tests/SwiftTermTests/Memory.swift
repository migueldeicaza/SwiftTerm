//
//  Memory.swift - Ensures that an allocated terminal is deallocated, this is
// to make sure we do not regress when we use helper classes that might introduce
// a strong cycle.
//  
//
//  Created by Miguel de Icaza on 4/17/21.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class SwiftTermMemory {
    private struct DeinitState: Sendable {
        var headless = false
        var terminal = false
    }

    private static let deinitState = Locked(DeinitState())

    class SimpleTerminal: HeadlessTerminal {
        
        init (queue: DispatchQueue) {
            super.init (queue: queue, onEnd: { x in })
        }
        deinit {
            SwiftTermMemory.deinitState.withLock { $0.headless = true }
        }
    }
    
    class EmptyTerminalDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {
        }
    }
    class SubTerminal: Terminal {
        init (delegate: TerminalDelegate) {
            super.init(delegate: delegate)
        }
        
        deinit {
            SwiftTermMemory.deinitState.withLock { $0.terminal = true }
        }
    }
    
    // This tests that the `Terminal` instance is not leaking
    @Test func testTerminal() {
        SwiftTermMemory.deinitState.withLock { $0.terminal = false }
        func run () {
            let _ = SubTerminal (delegate: EmptyTerminalDelegate ())
        }
        run ()
        #expect(SwiftTermMemory.deinitState.withLock { $0.terminal })

    }
    
    func allocate (){
        let queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)
        let h = SimpleTerminal(queue: queue)
        //h.terminal.close ()
        let _ = h.terminal
    }
    
    // This test ensures that we are not keeping any strong references
    // in the code that would prevent terminal containers from being released
    @Test func testMemory() {
        SwiftTermMemory.deinitState.withLock { $0.headless = false }
        allocate ()
        #expect(SwiftTermMemory.deinitState.withLock { $0.headless })
    }
}
#endif
