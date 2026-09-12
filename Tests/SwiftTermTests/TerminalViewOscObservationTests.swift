#if os(macOS)
import Dispatch
import Foundation
import Testing
@testable import SwiftTerm

@Suite("TerminalView OSC observation")
struct TerminalViewOscObservationTests {
    @MainActor
    @Test func viewForwardsCopiedOscEventsToObservers() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 640, height: 320)))
        let received = Locked<[TerminalOscEvent]>([])
        let delivered = DispatchSemaphore(value: 0)

        let observation = view.observeOscEvents { event in
            received.withLock { $0.append(event) }
            delivered.signal()
        }

        view.feed(text: "\u{1b}]777;notify;Title;Body\u{7}")

        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(received.withLock { $0 } == [
            TerminalOscEvent(code: 777, payload: Array("notify;Title;Body".utf8))
        ])
        withExtendedLifetime(observation) {}
    }
}
#endif
