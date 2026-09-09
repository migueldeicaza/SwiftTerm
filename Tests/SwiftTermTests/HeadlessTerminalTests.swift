#if !os(iOS) && !os(Windows)
import Dispatch
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

    private final class BlockingTitleDelegate: TerminalDelegate {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)

        func setTerminalTitle(source: Terminal, title: String) {
            entered.signal()
            resume.wait()
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test func directDeliveryOptionConfiguresLocalProcess() {
        let defaultDelivery = HeadlessTerminal { _ in }
        let directDelivery = HeadlessTerminal(directDelivery: true) { _ in }

        #expect(!defaultDelivery.process.directDelivery)
        #expect(directDelivery.process.directDelivery)
    }

    @Test func nilQueueIsPrivateSerialQueueSharedWithLocalProcess() {
        let headless = HeadlessTerminal { _ in }

        #expect(headless.deliveryQueue !== DispatchQueue.main)
        #expect(headless.deliveryQueue === headless.process.dispatchQueue)
    }

    @Test func suppliedQueueIsPreservedAndSharedWithLocalProcess() {
        let queue = DispatchQueue(
            label: "swiftterm-headless-supplied-queue-test",
            attributes: .concurrent)
        let headless = HeadlessTerminal(queue: queue) { _ in }

        #expect(headless.deliveryQueue === queue)
        #expect(headless.process.dispatchQueue === queue)
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

    @Test func endCallbackDoesNotOverlapFinalParse() {
        let ended = DispatchSemaphore(value: 0)
        let terminationAttempted = DispatchSemaphore(value: 0)
        let headless = HeadlessTerminal(directDelivery: true) { _ in
            ended.signal()
        }
        let delegate = BlockingTitleDelegate()
        headless.terminal.tdel = delegate
        let reference = Locked<HeadlessTerminal?>(headless)
        let titleSequence = Array("\u{1b}]2;blocked title\u{7}".utf8)

        DispatchQueue.global().async {
            let headless = reference.withLock { $0 }
            headless?.dataReceived(slice: titleSequence[...])
        }
        #expect(delegate.entered.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global().async {
            terminationAttempted.signal()
            guard let headless = reference.withLock({ $0 }) else { return }
            headless.processTerminated(headless.process, exitCode: 0)
        }
        #expect(terminationAttempted.wait(timeout: .now() + 2) == .success)
        #expect(ended.wait(timeout: .now() + 0.05) == .timedOut)

        delegate.resume.signal()
        #expect(ended.wait(timeout: .now() + 2) == .success)
    }
}
#endif
