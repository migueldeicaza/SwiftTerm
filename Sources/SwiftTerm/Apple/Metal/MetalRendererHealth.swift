#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import Metal
import QuartzCore

/// Shared by every renderer generation of a view, including explicit toggles.
/// A stalled GPU may retain at most two submitted frames for that view. Time
/// windows and surface changes never reset this budget; only completion does.
final class MetalFrameBudget: Sendable {
    private struct State {
        var count = 0
        var capacityRetry: (@Sendable () -> Void)?
    }
    private let state = Locked(State())

    var hasCapacity: Bool { outstandingCount < 2 }
    var outstandingCount: Int { state.withLock { $0.count } }

    func acquire() -> Bool {
        state.withLock {
            guard $0.count < 2 else { return false }
            $0.count += 1
            return true
        }
    }

    /// One deferred structural change, not a per-frame scheduler. Checking
    /// capacity and registering under the same lock avoids a lost release.
    func retryWhenAvailable(_ retry: @escaping @Sendable () -> Void) {
        let ready = state.withLock {
            guard $0.count >= 2 else { return true }
            $0.capacityRetry = retry
            return false
        }
        if ready { retry() }
    }

    func cancelRetry() {
        state.withLock { $0.capacityRetry = nil }
    }

    func release() {
        let retry = state.withLock {
            precondition($0.count > 0)
            $0.count -= 1
            let retry = $0.capacityRetry
            $0.capacityRetry = nil
            return retry
        }
        retry?()
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

/// One submitted-frame monitor and at most one main-actor failure delivery
/// per renderer. Healthy completion stays on the completion thread. Neither
/// a missing drawable nor a refused frame permit starts the watchdog.
final class MetalRendererHealth: Sendable {
    typealias FailureHandler = @MainActor @Sendable (MetalError) -> Void
    static let timeout: TimeInterval = 5

    private struct State {
        var active = true
        var failed = false
        var command: (any MTLCommandBuffer)?
        var submittedAt: TimeInterval = 0
        var failureHandler: FailureHandler?
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
    func configure(failure: FailureHandler?) {
        state.withLock { $0.failureHandler = failure }
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
        let deliverFailure = state.withLock { state in
            state.command = nil
            timer.schedule(deadline: .distantFuture)
            guard state.active, !state.failed, error != nil,
                  state.failureHandler != nil else { return false }
            state.failed = true
            return true
        }
        // Clear the old monitor before returning its permit: another frame
        // may start immediately, and must not have its command cleared by us.
        frame.complete()
        if deliverFailure, let error { enqueueFailure(error) }
        guard canRender else { return }
        // Preserve the ordinary completion-thread fast path, including when
        // no health handler or presentation observer has been installed.
        if error == nil { TerminalView.onFramePresented?() }
        if redrawState.consumePendingRedraw() { redrawState.requestRedraw() }
    }

    func fail(_ error: MetalError) {
        let deliver = state.withLock { state in
            guard state.active, !state.failed, state.failureHandler != nil else { return false }
            state.failed = true
            timer.schedule(deadline: .distantFuture)
            return true
        }
        if deliver { enqueueFailure(error) }
    }

    func checkForTimeout(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let error: MetalError? = state.withLock { state in
            guard state.active, !state.failed, let command = state.command,
                  now - state.submittedAt >= Self.timeout else { return nil }
            var status = command.status
#if DEBUG
            status = state.simulatedStatus ?? status
#endif
            guard status != .completed else { return nil }
            state.failed = true
            if status == .error {
                return .commandFailed(command.error?.localizedDescription ?? "Unknown GPU error")
            }
            return .commandTimedOut
        }
        if let error { enqueueFailure(error) }
    }

    /// Called only after CPU rendering is quiescent. A Metal completion may
    /// still run, but can now only release its own frame/recycler resources.
    func retire() {
        state.withLock {
            $0.active = false
            $0.command = nil
            $0.failureHandler = nil
            timer.schedule(deadline: .distantFuture)
        }
        redrawState.invalidate()
    }

    /// `failed` admits exactly one recovery delivery per renderer lifetime.
    /// Healthy completion, presentation and redraw never enqueue actor work.
    private func enqueueFailure(_ error: MetalError) {
        Task { @MainActor [self] in
            let handler = state.withLock { $0.active ? $0.failureHandler : nil }
            handler?(error)
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
