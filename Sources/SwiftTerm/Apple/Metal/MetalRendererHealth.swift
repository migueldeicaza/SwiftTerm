#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import Metal
import QuartzCore

/// Shared by every renderer generation of a view, including explicit toggles.
/// A stalled GPU may retain at most two submitted frames for that view. Time
/// windows and surface changes never reset this budget; only completion does.
final class MetalFrameBudget: Sendable {
    private let count = Locked(0)

    var hasCapacity: Bool { outstandingCount < 2 }
    var outstandingCount: Int { count.withLock { $0 } }

    func acquire() -> Bool {
        count.withLock {
            guard $0 < 2 else { return false }
            $0 += 1
            return true
        }
    }

    func release() {
        count.withLock {
            precondition($0 > 0)
            $0 -= 1
        }
    }
}

/// The only additional resource lifetime captured by a submitted command.
/// Metal's retained-reference command buffer owns encoded buffers/textures;
/// this capsule keeps the actual presented drawable alive, not its view or
/// renderer. Retirement must NOT release its permit or recycle its resources.
final class MetalSubmittedFrame: Sendable {
    private let drawable: Locked<(any CAMetalDrawable)?>
    private let permit: DispatchSemaphore
    private let budget: MetalFrameBudget

    init(drawable: any CAMetalDrawable, permit: DispatchSemaphore,
         budget: MetalFrameBudget) {
        self.drawable = Locked(drawable)
        self.permit = permit
        self.budget = budget
    }

    func complete() {
        let completed = drawable.withLock {
            guard $0 != nil else { return false }
            $0 = nil
            return true
        }
        guard completed else { return }
        budget.release()
        permit.signal()
    }
}

/// One coalesced monitor and at most one queued main-actor delivery per
/// renderer. Neither a missing drawable nor a refused frame permit starts the
/// watchdog: it observes only submitted commands that remain nonterminal.
final class MetalRendererHealth: Sendable {
    typealias FailureHandler = @MainActor @Sendable (MetalError) -> Void
    typealias PresentationHandler = @MainActor @Sendable () -> Void
    static let timeout: TimeInterval = 5

    private struct State {
        var active = true
        var failed = false
        var command: (any MTLCommandBuffer)?
        var submittedAt: TimeInterval = 0
        var pendingFailure: MetalError?
        var pendingPresentation = false
        var deliveryScheduled = false
        var failureHandler: FailureHandler?
        var presentationHandler: PresentationHandler?
#if DEBUG
        var simulatedStatus: MTLCommandBufferStatus?
#endif
    }

    private let state = Locked(State())
    private let timer: DispatchSourceTimer
    private let redrawState: MetalRedrawState

    init(redrawState: MetalRedrawState) {
        self.redrawState = redrawState
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { [weak self] in self?.checkForTimeout() }
        timer.resume()
    }

    deinit { timer.cancel() }

    var canRender: Bool { state.withLock { $0.active && !$0.failed } }

    @MainActor
    func configure(failure: FailureHandler?, presentation: PresentationHandler?) {
        state.withLock {
            $0.failureHandler = failure
            $0.presentationHandler = presentation
        }
    }

    func submitted(_ command: any MTLCommandBuffer) {
        state.withLock {
            guard $0.active, !$0.failed, $0.failureHandler != nil else { return }
            $0.command = command
            $0.submittedAt = ProcessInfo.processInfo.systemUptime
            timer.schedule(deadline: .now() + Self.timeout)
        }
    }

    func completed(error: MetalError?, frame: MetalSubmittedFrame) {
        let deliver = state.withLock { state in
            state.command = nil
            timer.schedule(deadline: .distantFuture)
            guard state.active, !state.failed else { return false }
            if let error, state.failureHandler != nil {
                state.failed = true
                state.pendingFailure = error
            } else if error == nil {
                state.pendingPresentation = true
            }
            return scheduleDelivery(&state)
        }
        // Clear the old monitor before returning its permit: another frame
        // may start immediately, and must not have its command cleared by us.
        frame.complete()
        if deliver { enqueueDelivery() }
    }

    func fail(_ error: MetalError) {
        let deliver = state.withLock { state in
            guard state.active, !state.failed, state.failureHandler != nil else { return false }
            state.failed = true
            state.pendingFailure = error
            timer.schedule(deadline: .distantFuture)
            return scheduleDelivery(&state)
        }
        if deliver { enqueueDelivery() }
    }

    func checkForTimeout(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let deliver = state.withLock { state in
            guard state.active, !state.failed, let command = state.command,
                  now - state.submittedAt >= Self.timeout else { return false }
            var status = command.status
#if DEBUG
            status = state.simulatedStatus ?? status
#endif
            switch status {
            case .completed: return false
            case .error:
                state.pendingFailure = .commandFailed(command.error?.localizedDescription ?? "Unknown GPU error")
            default: state.pendingFailure = .commandTimedOut
            }
            state.failed = true
            return scheduleDelivery(&state)
        }
        if deliver { enqueueDelivery() }
    }

    /// Called only after CPU rendering is quiescent. A Metal completion may
    /// still run, but can now only release its own frame/recycler resources.
    func retire() {
        state.withLock {
            $0.active = false
            $0.command = nil
            $0.pendingFailure = nil
            $0.pendingPresentation = false
            $0.failureHandler = nil
            $0.presentationHandler = nil
            timer.schedule(deadline: .distantFuture)
        }
        redrawState.invalidate()
    }

    private func scheduleDelivery(_ state: inout State) -> Bool {
        guard !state.deliveryScheduled else { return false }
        state.deliveryScheduled = true
        return true
    }

    private func enqueueDelivery() {
        Task { @MainActor [self] in
            let delivery = state.withLock { state -> (MetalError?, FailureHandler?, PresentationHandler?)? in
                state.deliveryScheduled = false
                guard state.active else { return nil }
                let result = (state.pendingFailure, state.failureHandler,
                              state.pendingPresentation && !state.failed ? state.presentationHandler : nil)
                state.pendingFailure = nil
                state.pendingPresentation = false
                return result
            }
            guard let delivery else { return }
            if let error = delivery.0 {
                delivery.1?(error)
            } else if canRender {
                delivery.2?()
                if redrawState.consumePendingRedraw() { redrawState.requestRedraw() }
            }
        }
    }

#if DEBUG
    func simulateCommandStatus(_ status: MTLCommandBufferStatus) {
        state.withLock { $0.simulatedStatus = status }
    }
#endif
}

#if DEBUG
/// Withholds a completion notification, never GPU execution. Tests release it
/// explicitly; no blocked shared event, infinite kernel, or driver wait.
final class MetalCompletionGate: Sendable {
    private struct State {
        var pending: (@Sendable (MetalError?) -> Void)?
        var released = false
    }
    private let state = Locked(State())

    var isHoldingCompletion: Bool { state.withLock { $0.pending != nil } }

    func hold(_ completion: @escaping @Sendable (MetalError?) -> Void) {
        let held = state.withLock {
            guard !$0.released else { return false }
            precondition($0.pending == nil)
            $0.pending = completion
            return true
        }
        if !held { completion(nil) }
    }

    func release(error: MetalError? = nil) {
        let completion = state.withLock {
            $0.released = true
            let completion = $0.pending
            $0.pending = nil
            return completion
        }
        completion?(error)
    }
}
#endif
#endif
