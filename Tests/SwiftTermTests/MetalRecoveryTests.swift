#if os(macOS) && canImport(MetalKit) && DEBUG
import AppKit
import MetalKit
import QuartzCore
import Testing
@testable import SwiftTerm

// Gate only hardware availability: missing shaders, renderer initialization
// failures, or missing drawables must fail rather than silently skip coverage.
@MainActor
@Suite("Metal recovery", .serialized,
       .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalRecoveryTests {
    private func makeView(size: CGSize = CGSize(width: 320, height: 120)) throws -> TerminalView {
        let view = TerminalView(frame: CGRect(origin: .zero, size: size), font: nil,
                                options: TerminalOptions(cols: 30, rows: 6, scrollback: 100))
        view.usesMetalLayerSurface = true
        try view.setUseMetal(true)
        view.stopRenderLoop()
        return view
    }

    private func eventually(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(condition())
    }

    private func heldSubmission(_ view: TerminalView) async throws -> MetalCompletionGate {
        view.stopRenderLoop()
        let gate = MetalCompletionGate()
        let health = try #require(view.renderOwner.metalHealthForTesting())
        view.renderOwner.configureMetalFaultForTesting(completionGate: gate)
        health.simulateCommandStatus(.committed)
        view.drawMetalFrameNow()
        do {
            try await eventually { gate.isHoldingCompletion }
            return gate
        } catch {
            gate.release()
            throw error
        }
    }

    private struct Model: Equatable {
        let terminal: ObjectIdentifier
        let selection: ObjectIdentifier
        let search: ObjectIdentifier
        let contents: Data
        let scrollback: Int
        let selectedText: String
        let searchResult: SearchResult?
    }

    private func model(_ view: TerminalView) -> Model {
        view.withTerminal { terminal in
            Model(terminal: ObjectIdentifier(terminal),
                  selection: ObjectIdentifier(view.selection),
                  search: ObjectIdentifier(view.search),
                  contents: terminal.getBufferAsData(), scrollback: terminal.buffer.yBase,
                  selectedText: view.selection.getSelectedText(),
                  searchResult: view.search.lastResult)
        }
    }

    @Test func firstFailureReplacesSecondFallsBackWithoutLosingModelOrInput() async throws {
        let view = try makeView()
        let input = RecoveryInputDelegate()
        view.terminalDelegate = input
        defer { view.metalRendererFallbackHandler = nil; view.updateUiClosed() }
        view.feed(text: (0..<40).map { "line \($0)\r\n" }.joined())
        #expect(view.findNext("line 12", scrollToResult: false))
        let before = model(view)
        #expect(before.scrollback > 0)
        #expect(before.selectedText == "line 12")
        let firstSurface = try #require(view.metalView)
        let generation = view.metalGenerationForTesting
        var fallbacks = 0
        view.metalRendererFallbackHandler = { error in
            // Re-entering value/input APIs here would deadlock if delivery
            // still held the renderer or owner lock.
            #expect(!view.isUsingMetalRenderer)
            #expect(view.metalView == nil)
            #expect(!view.renderOwner.hasMetalRenderer)
            #expect(model(view) == before)
            #expect(error.description.contains("encoder"))
            view.send(txt: "after")
            fallbacks += 1
        }
        #expect(view.metalRendererFallbackHandler != nil)
        view.renderOwner.configureMetalFaultForTesting(creationFailure: .commandBufferUnavailable)
        view.drawMetalFrameNow()
        try await eventually { view.metalGenerationForTesting != generation }
        #expect(view.isUsingMetalRenderer)
        #expect(fallbacks == 0)
        #expect(view.metalView !== firstSurface)
        #expect(firstSurface.superview == nil)
        #expect((firstSurface as? TerminalMetalLayerView)?.onNeedsDisplay == nil)
        #expect(model(view) == before)

        view.stopRenderLoop()
        view.renderOwner.configureMetalFaultForTesting(creationFailure: .renderEncoderUnavailable)
        view.drawMetalFrameNow()
        try await eventually { fallbacks == 1 }
        #expect(model(view) == before)
        try await eventually { String(decoding: input.bytes, as: UTF8.self) == "after" }
        view.feed(text: "\r\ncontinued")
        #expect(view.getBufferAsData().count >= before.contents.count)
    }

    @Test func lateCompletionAndStaleFailureCannotTouchReplacement() async throws {
        let view = try makeView()
        defer { view.updateUiClosed() }
        let oldGeneration = view.metalGenerationForTesting
        let oldHealth = try #require(view.renderOwner.metalHealthForTesting())
        let gate = try await heldSubmission(view)
        defer { gate.release() }
        #expect(view.metalOutstandingFramesForTesting == 1)

        oldHealth.checkForTimeout(now: .greatestFiniteMagnitude)
        try await eventually { view.metalGenerationForTesting != oldGeneration }
        view.stopRenderLoop()
        let replacement = try #require(view.metalView)
        let replacementHealth = try #require(view.renderOwner.metalHealthForTesting())
        let generation = view.metalGenerationForTesting
        let presentations = Locked(0)
        let previous = TerminalView.onFramePresented
        TerminalView.onFramePresented = { presentations.withLock { $0 += 1 } }
        defer { TerminalView.onFramePresented = previous }

        gate.release()
        oldHealth.fail(.commandFailed("late old error"))
        view.deliverMetalFailureForTesting(.commandTimedOut, generation: oldGeneration)
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(view.metalOutstandingFramesForTesting == 0)
        #expect(presentations.withLock { $0 } == 0)
        #expect(view.metalGenerationForTesting == generation)
        #expect(view.metalView === replacement)
        #expect(replacementHealth.canRender)
        #expect(view.renderOwner.completedMetalRenders == 0)
    }

    @Test func hungFramesStayBoundedAcrossTimeWindowsAndExplicitReenable() async throws {
        let view = try makeView()
        defer { view.metalRendererFallbackHandler = nil; view.updateUiClosed() }
        var fallbacks = 0
        view.metalRendererFallbackHandler = { _ in fallbacks += 1 }
        view.metalRecoveryTestTime = 100
        let first = try await heldSubmission(view)
        defer { first.release() }
        let firstHealth = try #require(view.renderOwner.metalHealthForTesting())
        firstHealth.checkForTimeout(now: .greatestFiniteMagnitude)
        try await eventually { view.renderOwner.metalHealthForTesting() !== firstHealth }
        #expect(view.isUsingMetalRenderer)

        // Even outside the retry window, two permanently outstanding frames
        // must never permit a third retained generation.
        view.metalRecoveryTestTime = 131
        let second = try await heldSubmission(view)
        defer { second.release() }
        let secondHealth = try #require(view.renderOwner.metalHealthForTesting())
        secondHealth.checkForTimeout(now: .greatestFiniteMagnitude)
        try await eventually { fallbacks == 1 }
        #expect(view.metalOutstandingFramesForTesting == 2)
        for _ in 0..<4 {
            #expect(throws: MetalError.self) { try view.setUseMetal(true) }
            #expect(!view.isUsingMetalRenderer)
            #expect(view.metalView == nil)
        }
        #expect(view.metalOutstandingFramesForTesting == 2)
        first.release()
        try view.setUseMetal(true)
        #expect(view.isUsingMetalRenderer)
        #expect(view.metalOutstandingFramesForTesting == 1)
        second.release()
        #expect(view.metalOutstandingFramesForTesting == 0)
        #expect(fallbacks == 1)
    }

    @Test func commandCompletionErrorRecoversAndRealWatchdogFallsBackOnce() async throws {
        let view = try makeView()
        defer { view.metalRendererFallbackHandler = nil; view.updateUiClosed() }
        var fallbacks = 0
        view.metalRendererFallbackHandler = { error in
            #expect(!view.isUsingMetalRenderer)
            #expect(error.description.contains("five seconds"))
            fallbacks += 1
        }
        let generation = view.metalGenerationForTesting
        let first = try await heldSubmission(view)
        defer { first.release() }
        first.release(error: .commandFailed("controlled completion error"))
        try await eventually { view.metalGenerationForTesting != generation }
        #expect(view.isUsingMetalRenderer)
        #expect(view.metalOutstandingFramesForTesting == 0)

        let second = try await heldSubmission(view)
        defer { second.release() }
        // Use the real dispatch timer, without polling the renderer or ever
        // holding GPU execution. Only the completion notification is withheld.
        try await eventually(timeout: MetalRendererHealth.timeout + 2) { fallbacks == 1 }
        #expect(view.metalOutstandingFramesForTesting == 1)
        second.release(error: .commandFailed("late completion"))
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(fallbacks == 1)
        #expect(view.metalOutstandingFramesForTesting == 0)
    }

    @Test func missingDrawableAndPermitRefusalAreNotHealthFailures() async throws {
        let empty = try makeView(size: .zero)
        defer { empty.updateUiClosed() }
        let emptyHealth = try #require(empty.renderOwner.metalHealthForTesting())
        let generation = empty.metalGenerationForTesting
        empty.drawMetalFrameNow()
        emptyHealth.checkForTimeout(now: .greatestFiniteMagnitude)
        #expect(empty.renderOwner.completedMetalRenders == 0)
        #expect(emptyHealth.canRender)
        #expect(empty.metalGenerationForTesting == generation)

        let view = try makeView()
        defer { view.updateUiClosed() }
        let gate = try await heldSubmission(view)
        defer { gate.release() }
        let health = try #require(view.renderOwner.metalHealthForTesting())
        for _ in 0..<5 { view.drawMetalFrameNow() }
        #expect(health.canRender)
        #expect(view.renderOwner.completedMetalRenders == 1)
        #expect(view.metalOutstandingFramesForTesting == 1)
        // A terminal command whose notification is merely delayed is not a
        // hung GPU. Only a nonterminal status is eligible for the watchdog.
        health.simulateCommandStatus(.completed)
        health.checkForTimeout(now: .greatestFiniteMagnitude)
        #expect(health.canRender)
    }

    @Test func parkingRebindingAndShutdownNeverWaitForGPU() async throws {
        let view = try makeView()
        defer { view.updateUiClosed() }
        let before = model(view)
        let oldSurface = try #require(view.metalView)
        let gate = try await heldSubmission(view)
        defer { gate.release() }
        let started = ProcessInfo.processInfo.systemUptime
        view.startRenderLoopIfNeeded()
        view.viewDidMoveToWindow() // nil window: a parked, still-live terminal
        #expect(!view.isUsingRenderLoop)
        #expect(view.isUsingMetalRenderer)
        #expect(view.metalView === oldSurface)
        view.rebindMetalForTesting()
        #expect(view.isUsingMetalRenderer)
        #expect(view.metalView !== oldSurface)
        #expect(oldSurface.superview == nil)
        #expect(model(view) == before)
        #expect(view.updateUiClosed())
        #expect(view.updateUiClosed())
        #expect(!view.isUsingMetalRenderer)
        #expect(!view.isUsingRenderLoop)
        #expect(view.metalView == nil)
        #expect(view.metalOutstandingFramesForTesting == 1)
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
    }

    @Test func retirementQuiescesCPUWithoutWaitingForHeldGPUCompletion() async throws {
        let view = try makeView()
        defer { view.updateUiClosed() }
        let gate = try await heldSubmission(view)
        defer { gate.release() }
        try assertCPUDrain(view)
    }

    private func assertCPUDrain(_ view: TerminalView) throws {
        view.startRenderLoopIfNeeded()
        let loop = try #require(view.renderLoop)
        let entered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            loop.frameLock.lock()
            entered.signal()
            Thread.sleep(forTimeInterval: 0.1)
            loop.frameLock.unlock()
        }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        let start = ProcessInfo.processInfo.systemUptime
        try view.setUseMetal(false)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        #expect(elapsed >= 0.08 && elapsed < 2)
        #expect(!loop.isRunning)
        #expect(view.metalOutstandingFramesForTesting == 1)
    }

    @Test func queuedFailureIsInvalidatedByExplicitDisableAndShutdown() async throws {
        let view = try makeView()
        defer { view.metalRendererFallbackHandler = nil; view.updateUiClosed() }
        var fallbacks = 0
        view.metalRendererFallbackHandler = { _ in fallbacks += 1 }
        let health = try #require(view.renderOwner.metalHealthForTesting())
        health.fail(.commandFailed("queued before disable"))
        try view.setUseMetal(false)
        try view.setUseMetal(true)
        let current = try #require(view.renderOwner.metalHealthForTesting())
        current.fail(.commandFailed("queued before shutdown"))
        view.updateUiClosed()
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(fallbacks == 0)
        #expect(!view.isUsingMetalRenderer)
    }

    @Test func retirementReleasesRendererWithoutReleasingSubmittedPermit() async throws {
        let view = try makeView()
        defer { view.updateUiClosed() }
        try view.setUseMetal(false)
        let target = TerminalMetalLayerView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        let device = try #require(MTLCreateSystemDefaultDevice())
        target.renderDevice = device
        let budget = MetalFrameBudget()
        var renderer: MetalTerminalRenderer? = try MetalTerminalRenderer(target: target, frameBudget: budget)
        weak var weakRenderer = renderer
        let gate = MetalCompletionGate()
        defer { gate.release() }
        renderer?.completionGate = gate
        view.renderOwner.installMetalRenderer(try #require(renderer), needsExternalDraw: true)
        #expect(view.renderSnapshotForMetal(renderer: try #require(renderer), target: target))
        try await eventually { gate.isHoldingCompletion }
        #expect(renderer?.waitForIdle(timeout: 0) == false)
        renderer = nil
        #expect(view.renderOwner.removeMetalRenderer())
        #expect(weakRenderer == nil)
        #expect(budget.outstandingCount == 1)
        gate.release()
        #expect(budget.outstandingCount == 0)
    }

    @Test func submittedCapsuleOwnsDrawableUntilCompletionOnly() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let texture = try #require(device.makeTexture(descriptor:
            MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                      width: 2, height: 2, mipmapped: false)))
        let budget = MetalFrameBudget()
        let permit = DispatchSemaphore(value: 0)
        #expect(budget.acquire())
        var drawable: RecoveryDrawable? = RecoveryDrawable(texture: texture)
        weak var weakDrawable = drawable
        let frame = MetalSubmittedFrame(drawable: try #require(drawable), permit: permit, budget: budget)
        drawable = nil
        #expect(weakDrawable != nil)
        #expect(permit.wait(timeout: .now()) == .timedOut)
        frame.complete()
        #expect(weakDrawable == nil)
        #expect(permit.wait(timeout: .now()) == .success)
        frame.complete()
        #expect(permit.wait(timeout: .now()) == .timedOut)
        #expect(budget.outstandingCount == 0)
        // The API default on which encoded-buffer/atlas retirement relies.
        #expect(MTLCommandBufferDescriptor().retainedReferences)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        #expect(command.retainedReferences)
    }
}

private final class RecoveryDrawable: NSObject, CAMetalDrawable {
    let texture: any MTLTexture
    let layer = CAMetalLayer()
    let drawableID: Int = 1
    let presentedTime: CFTimeInterval = 0
    init(texture: any MTLTexture) { self.texture = texture }
    func present() {}
    func present(at presentationTime: CFTimeInterval) {}
    func present(afterMinimumDuration duration: CFTimeInterval) {}
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {}
}

@MainActor
private final class RecoveryInputDelegate: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
