//
//  RenderLoop.swift
//  SwiftTerm
//
//  A dedicated thread that prepares and draws terminal frames.
//
//  The main thread pays about 6 ms per frame on the Metal path, essentially
//  all of it building row data (io-gaps.md G1). That cost is CPU work rather
//  than a blocked wait, so moving it off main genuinely frees the main thread
//  instead of relocating a stall — and once it is off main, blocking for a
//  drawable costs the main thread nothing either.
//
//  This type is deliberately small. It owns a thread, a semaphore and a
//  coalescing flag, and it knows nothing about terminals or Metal.
//

#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation

/// Counters describing how the render loop behaved over a measurement window.
struct RenderLoopCounters: Sendable {
    /// Calls to `signal`.
    var signals = 0
    /// Frames the loop actually ran.
    var frames = 0
    /// Signals that arrived while one was already pending and were folded into
    /// it. A large value means the producer is outrunning the renderer, which
    /// is the intended behaviour under a flood, not a fault.
    var coalesced = 0
}

/// Runs a callback on a dedicated high-priority thread, one frame at a time.
///
/// Signals coalesce: several `signal()` calls before the loop wakes produce one
/// frame, so a flood cannot queue work faster than it can be drawn.
final class RenderLoop: Sendable {
    /// Renders one frame. Called on the render thread, never re-entrantly, and
    /// always with `frameLock` held.
    ///
    private let onRender: @Sendable () -> Void

    /// Serialises a frame against structural changes made on the main thread:
    /// enabling or disabling Metal, rebinding the surface after a display
    /// change, a synchronous draw for a screenshot.
    ///
    /// **Never take this while holding the terminal lock.** The render thread
    /// takes them in the order frameLock -> terminalLock, so the reverse order
    /// on main deadlocks. Structural operations hold neither when they start.
    let frameLock = NSLock()

    private let semaphore = DispatchSemaphore(value: 0)
    private struct ControlState {
        var pending = false
        var stopped = false
        var thread: Thread?
        var counters = RenderLoopCounters()
    }
    private let control = Locked(ControlState())

    init (onRender: @escaping @Sendable () -> Void) {
        self.onRender = onRender
    }

    deinit {
        invalidate()
    }

    /// Starts the render thread. Idempotent.
    func start () {
        let control = control
        let semaphore = semaphore
        let frameLock = frameLock
        let onRender = onRender
        let thread = Thread {
            Self.run(
                control: control,
                semaphore: semaphore,
                frameLock: frameLock,
                onRender: onRender)
        }
        thread.name = "org.tirania.SwiftTerm.render"
        // The frame deadline is the display's, the same class of deadline the
        // main thread runs at. Anything lower and a busy machine drops frames
        // that the main-thread path would have produced.
        thread.qualityOfService = .userInteractive
        let shouldStart = control.withLock { state in
            guard state.thread == nil, !state.stopped else { return false }
            state.thread = thread
            return true
        }
        guard shouldStart else { return }
        thread.start()
    }

    /// Asks for one frame. Safe from any thread, including the render thread.
    func signal () {
        let shouldWake = control.withLock { state in
            state.counters.signals += 1
            guard !state.stopped else { return false }
            let wasPending = state.pending
            state.pending = true
            if wasPending {
                state.counters.coalesced += 1
            }
            return !wasPending
        }

        // Only the transition from clean to pending posts, so the semaphore
        // never accumulates a backlog of frames to catch up on.
        if shouldWake {
            semaphore.signal()
        }
    }

    /// Stops the loop permanently and waits for any frame in flight to finish.
    ///
    /// Waiting matters: the caller is usually tearing down the surface the
    /// in-flight frame is drawing into.
    func invalidate () {
        let stop = control.withLock { state -> (shouldStop: Bool, isWorker: Bool) in
            guard !state.stopped else { return (false, false) }
            state.stopped = true
            state.pending = false
            return (true, state.thread === Thread.current)
        }
        guard stop.shouldStop else { return }

        semaphore.signal()
        // The loop drops frameLock between frames and takes it again only
        // after re-checking `stopped`, so acquiring it here means no frame is
        // running and none will start.
        if !stop.isWorker {
            frameLock.lock()
            frameLock.unlock()
        }

        control.withLock { $0.thread = nil }
    }

    var isRunning: Bool {
        control.withLock { $0.thread != nil && !$0.stopped }
    }

    var currentCounters: RenderLoopCounters {
        control.withLock { $0.counters }
    }

    func resetCounters () {
        control.withLock { $0.counters = RenderLoopCounters() }
    }

    private static func run (
        control: Locked<ControlState>,
        semaphore: DispatchSemaphore,
        frameLock: NSLock,
        onRender: @Sendable () -> Void
    ) {
        while true {
            semaphore.wait()

            let shouldRender = control.withLock { state in
                guard !state.stopped else { return false }
                // Cleared before the frame, not after: a change arriving while
                // this frame is being drawn must schedule the next one.
                state.pending = false
                state.counters.frames += 1
                return true
            }
            guard shouldRender else { return }

            frameLock.lock()
            let shouldStop = control.withLock { $0.stopped }
            if shouldStop {
                frameLock.unlock()
                return
            }
            autoreleasepool {
                onRender()
            }
            frameLock.unlock()
        }
    }
}
#endif
