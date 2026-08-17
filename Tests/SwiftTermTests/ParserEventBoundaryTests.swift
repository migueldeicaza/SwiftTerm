import Dispatch
import Testing
@testable import SwiftTerm

@Suite("Parser OSC event boundary")
struct ParserEventBoundaryTests {
    @Test func overrideStaysSynchronousAndObserversUseEncounterOrder() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        let overrideState = Locked((called: false, heldTerminalLock: false))
        let received = Locked<[TerminalOscEvent]>([])
        let delivered = DispatchSemaphore(value: 0)

        let observation = terminal.observeOscEvents { event in
            let count = received.withLock { events in
                events.append(event)
                return events.count
            }
            if count == 2 {
                delivered.signal()
            }
        }

        terminal.registerOscHandler(code: 777) { [unowned terminal] payload in
            overrideState.withLock { state in
                state.called = payload.elementsEqual("outer".utf8)
                state.heldTerminalLock = terminal.terminalLock.isLockedByCurrentThread
            }
            terminal.feed(text: "\u{1b}]778;nested\u{7}")
        }

        terminal.terminalLock.withLock {
            terminal.feed(text: "\u{1b}]777;outer\u{7}")
        }

        let overrideSnapshot = overrideState.withLock { $0 }
        #expect(overrideSnapshot.called)
        #expect(overrideSnapshot.heldTerminalLock)
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(received.withLock { $0 } == [
            TerminalOscEvent(code: 777, payload: Array("outer".utf8)),
            TerminalOscEvent(code: 778, payload: Array("nested".utf8)),
        ])
        withExtendedLifetime(observation) {}
    }

    @Test func cancellationAndTokenDeinitializationStopLaterEvents() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 1)
        let receivedCodes = Locked<[Int]>([])
        let firstDelivered = DispatchSemaphore(value: 0)

        var observation: TerminalOscObservation? = terminal.observeOscEvents { event in
            receivedCodes.withLock { $0.append(event.code) }
            firstDelivered.signal()
        }

        terminal.feed(text: "\u{1b}]700;first\u{7}")
        #expect(firstDelivered.wait(timeout: .now() + 2) == .success)

        observation?.cancel()
        observation = nil

        let barrierDelivered = DispatchSemaphore(value: 0)
        let barrier = terminal.observeOscEvents { event in
            if event.code == 702 || event.code == 704 {
                barrierDelivered.signal()
            }
        }

        terminal.feed(text: "\u{1b}]701;cancelled\u{7}")
        terminal.feed(text: "\u{1b}]702;barrier\u{7}")

        #expect(barrierDelivered.wait(timeout: .now() + 2) == .success)
        #expect(receivedCodes.withLock { $0 } == [700])

        var lifetimeObservation: TerminalOscObservation? = terminal.observeOscEvents { event in
            receivedCodes.withLock { $0.append(event.code) }
        }
        #expect(lifetimeObservation != nil)
        lifetimeObservation = nil

        terminal.feed(text: "\u{1b}]703;deinitialized\u{7}")
        terminal.feed(text: "\u{1b}]704;lifetime-barrier\u{7}")

        #expect(barrierDelivered.wait(timeout: .now() + 2) == .success)
        #expect(receivedCodes.withLock { $0 } == [700])
        withExtendedLifetime(barrier) {}
    }
}
