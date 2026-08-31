//
//  MetalRendererConcurrencyTests.swift
//  SwiftTermTests
//
//  Covers the checked state captured by Metal completion and timer callbacks.
//

#if os(macOS) && canImport(Metal)
import Foundation
import Metal
import Testing
@testable import SwiftTerm

@Suite("Metal renderer concurrency")
struct MetalRendererConcurrencyTests {
    private func requireSendable<T: Sendable>(_: T.Type) {}

    @Test func redrawStateIsCheckedSendableAndConsumesPendingOnce() {
        requireSendable(MetalRedrawState.self)
        let redraws = Locked(0)
        let state = MetalRedrawState()
        state.configure {
            redraws.withLock { $0 += 1 }
        }

        state.markPendingRedraw()
        #expect(state.consumePendingRedraw())
        #expect(!state.consumePendingRedraw())
        state.requestRedraw()
        #expect(redraws.withLock { $0 } == 1)
    }

    @Test @MainActor func retirementInvalidatesRedrawAndQueuedBlinkStart() {
        let redraws = Locked(0)
        let state = MetalRedrawState()
        state.configure { redraws.withLock { $0 += 1 } }
        let controller = MetalCursorBlinkController(redrawState: state)
        #expect(state.setCursorBlinkWanted(true))
        state.markPendingRedraw()
        state.invalidate()
        controller.apply(shouldBlink: true)
        state.requestRedraw()
        state.markPendingRedraw()
        #expect(!state.consumePendingRedraw())
        #expect(!state.setCursorBlinkWanted(true))
        #expect(!controller.isRunning)
        #expect(redraws.withLock { $0 } == 0)
    }

    @Test @MainActor func mainRedrawDeliveryIsCoalescedAndInvalidated() async throws {
        var redraws = 0
        let state = MetalRedrawState()
        state.configureOnMain { redraws += 1 }
        for _ in 0..<1_000 { state.requestRedraw() }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(redraws == 1)
        state.requestRedraw()
        state.invalidate()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(redraws == 1)
    }

    @Test @MainActor func cursorBlinkControllerOwnsTimerOnMainActor() {
        let redraws = Locked(0)
        let state = MetalRedrawState()
        state.configure {
            redraws.withLock { $0 += 1 }
        }
        let controller = MetalCursorBlinkController(redrawState: state,
                                                    interval: 0.01)

        #expect(state.setCursorBlinkWanted(true))
        controller.apply(shouldBlink: true)
        #expect(controller.isRunning)
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        #expect(redraws.withLock { $0 } > 0)

        #expect(state.setCursorBlinkWanted(false))
        controller.apply(shouldBlink: false)
        #expect(!controller.isRunning)
        #expect(state.cursorBlinkOn)
    }

    @Test func bufferRecyclerRetainsAndReturnsCompletedBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let buffer = device.makeBuffer(length: 4_096,
                                              options: .storageModeShared) else {
            return
        }
        let recycler = MetalTerminalRenderer.MetalBufferRecycler()
        requireSendable(MetalTerminalRenderer.MetalBufferRecycler.self)

        let batchID = try #require(recycler.retainUntilCompletion([buffer]))
        #expect(recycler.pendingBatchCount == 1)
        #expect(recycler.take(length: buffer.length) == nil)

        recycler.complete(batchID: batchID)
        #expect(recycler.pendingBatchCount == 0)
        let returned = try #require(recycler.take(length: buffer.length))
        #expect(returned === buffer)
    }
}
#endif
