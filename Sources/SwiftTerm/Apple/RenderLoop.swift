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
struct RenderLoopCounters {
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
final class RenderLoop {
    /// Renders one frame. Called on the render thread, never re-entrantly, and
    /// always with `frameLock` held.
    var onRender: (() -> Void)?

    /// Serialises a frame against structural changes made on the main thread:
    /// enabling or disabling Metal, rebinding the surface after a display
    /// change, a synchronous draw for a screenshot.
    ///
    /// **Never take this while holding the terminal lock.** The render thread
    /// takes them in the order frameLock -> terminalLock, so the reverse order
    /// on main deadlocks. Structural operations hold neither when they start.
    let frameLock = NSLock()

    private let semaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var pending = false
    private var stopped = false
    private var thread: Thread?
    private var counters = RenderLoopCounters()

    /// Starts the render thread. Idempotent.
    func start () {
        stateLock.lock()
        let alreadyRunning = thread != nil || stopped
        stateLock.unlock()
        guard !alreadyRunning else { return }

        let thread = Thread { [weak self] in
            self?.run()
        }
        thread.name = "org.tirania.SwiftTerm.render"
        // The frame deadline is the display's, the same class of deadline the
        // main thread runs at. Anything lower and a busy machine drops frames
        // that the main-thread path would have produced.
        thread.qualityOfService = .userInteractive
        stateLock.lock()
        self.thread = thread
        stateLock.unlock()
        thread.start()
    }

    /// Asks for one frame. Safe from any thread, including the render thread.
    func signal () {
        stateLock.lock()
        counters.signals += 1
        guard !stopped else {
            stateLock.unlock()
            return
        }
        let wasPending = pending
        pending = true
        if wasPending {
            counters.coalesced += 1
        }
        stateLock.unlock()

        // Only the transition from clean to pending posts, so the semaphore
        // never accumulates a backlog of frames to catch up on.
        if !wasPending {
            semaphore.signal()
        }
    }

    /// Stops the loop permanently and waits for any frame in flight to finish.
    ///
    /// Waiting matters: the caller is usually tearing down the surface the
    /// in-flight frame is drawing into.
    func invalidate () {
        stateLock.lock()
        let wasStopped = stopped
        stopped = true
        pending = false
        stateLock.unlock()
        guard !wasStopped else { return }

        semaphore.signal()
        // The loop drops frameLock between frames and takes it again only
        // after re-checking `stopped`, so acquiring it here means no frame is
        // running and none will start.
        frameLock.lock()
        frameLock.unlock()

        stateLock.lock()
        thread = nil
        onRender = nil
        stateLock.unlock()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return thread != nil && !stopped
    }

    var currentCounters: RenderLoopCounters {
        stateLock.lock()
        defer { stateLock.unlock() }
        return counters
    }

    func resetCounters () {
        stateLock.lock()
        counters = RenderLoopCounters()
        stateLock.unlock()
    }

    private func run () {
        while true {
            semaphore.wait()

            stateLock.lock()
            if stopped {
                stateLock.unlock()
                return
            }
            // Cleared before the frame, not after: a change arriving while
            // this frame is being drawn must schedule the next one.
            pending = false
            counters.frames += 1
            let render = onRender
            stateLock.unlock()

            guard let render else { continue }
            frameLock.lock()
            render()
            frameLock.unlock()
        }
    }
}
#endif
