#if !os(iOS) && !os(Windows)
import Testing
@testable import SwiftTerm

final class HeadlessTerminalTests {
    private final class LockObservingDelegate: TerminalDelegate {
        var title: String?
        var heldTerminalLock = false

        func setTerminalTitle(source: Terminal, title: String) {
            self.title = title
            heldTerminalLock = source.terminalLock.isLockedByCurrentThread
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test func directDeliveryOptionConfiguresLocalProcess() {
        let defaultDelivery = HeadlessTerminal { _ in }
        let directDelivery = HeadlessTerminal(directDelivery: true) { _ in }

        #expect(!defaultDelivery.process.directDelivery)
        #expect(directDelivery.process.directDelivery)
    }

    @Test func dataReceivedFeedsWhileHoldingTerminalLock() {
        let headless = HeadlessTerminal { _ in }
        let delegate = LockObservingDelegate()
        headless.terminal.tdel = delegate

        let titleSequence = Array("\u{1b}]2;locked title\u{7}".utf8)
        headless.dataReceived(slice: titleSequence[...])

        #expect(delegate.title == "locked title")
        #expect(delegate.heldTerminalLock)
    }
}
#endif
