//
//  FrameDriver.swift
//
//  Drives terminal snapshot refreshes at the display cadence.
//

#if os(macOS) || os(iOS) || os(visionOS) || os(tvOS)
import Foundation
import QuartzCore

#if os(macOS)
import AppKit
import CoreVideo
#else
import UIKit
#endif

/// A synchronous display-link replacement for unit tests.
final class ManualTickSource {
    private weak var driver: FrameDriver?

    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    fileprivate func attach(to driver: FrameDriver) {
        self.driver = driver
    }

    fileprivate func start() {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
    }

    fileprivate func stop() {
        guard isRunning else { return }
        isRunning = false
        stopCount += 1
    }

    fileprivate func invalidate() {
        stop()
        driver = nil
    }

    /// Sends one tick synchronously when the source is running.
    func tick() {
        guard isRunning else { return }
        driver?.sourceDidTick()
    }
}

private final class FrameDisplayLinkTarget: NSObject {
    weak var driver: FrameDriver?

    @objc func displayLinkFired(_ sender: Any) {
        driver?.sourceDidTick()
    }
}

private protocol FrameDisplayLinkBackend: AnyObject {
    func start()
    func stop()
    func invalidate()
}

#if os(macOS)
@available(macOS 14.0, *)
private final class MacFrameDisplayLinkBackend: FrameDisplayLinkBackend {
    private let link: CADisplayLink

    init(view: NSView, target: FrameDisplayLinkTarget) {
        link = view.displayLink(
            target: target,
            selector: #selector(FrameDisplayLinkTarget.displayLinkFired(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
    }

    func start() {
        link.isPaused = false
    }

    func stop() {
        link.isPaused = true
    }

    func invalidate() {
        link.invalidate()
    }
}
#else
private final class MobileFrameDisplayLinkBackend: FrameDisplayLinkBackend {
    private let link: CADisplayLink

    init(target: FrameDisplayLinkTarget) {
        link = CADisplayLink(
            target: target,
            selector: #selector(FrameDisplayLinkTarget.displayLinkFired(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
    }

    func start() {
        link.isPaused = false
    }

    func stop() {
        link.isPaused = true
    }

    func invalidate() {
        link.invalidate()
    }
}
#endif

/// Counters describing how the frame driver behaved over a measurement window.
/// Cheap enough to keep unconditional: a handful of integer increments per
/// display tick, all under the lock the driver already takes.
struct FrameDriverCounters {
    /// Ticks delivered by the display link (or the immediate path).
    var ticks = 0
    /// Ticks that found the driver dirty and therefore produced a frame.
    var frames = 0
    /// Ticks that found nothing to do. A high ratio means the link is running
    /// for no reason, which is what the idle pause exists to prevent.
    var idleTicks = 0
    /// Times the driver paused the display link after the idle run.
    var pauses = 0
    /// Frames requested outside the display cadence, by `requestImmediateTick`.
    var immediateTicks = 0
}

/// Coalesces terminal changes and submits them at the display cadence.
final class FrameDriver {
    static let idleTickLimit = 8

    /// The view installs a weakly captured frame callback here.
    var onTick: (() -> Void)?

    private let stateLock = NSLock()
    private var dirty = false
    private var running = false
    private var invalidated = false
    private var resumeScheduled = false
    private var immediateTickScheduled = false
    private var lastResumeTickUptimeNs: UInt64 = 0
    /// True while nothing can see this terminal: occluded, miniaturised, the
    /// application hidden, or (on iOS) backgrounded. Guarded by stateLock.
    private var visibilitySuspended = false
    private var visibilitySuspensionEnabled = true
    private var lastReportedVisibility = true
    private var visibilityObservers: [NSObjectProtocol] = []
    private var idleTickCount = 0
    private var counters = FrameDriverCounters()

    private let displayLinkTarget = FrameDisplayLinkTarget()
    private var displayLinkBackend: FrameDisplayLinkBackend?
    private var manualTickSource: ManualTickSource?

#if os(macOS)
    private weak var boundWindow: NSWindow?
    private var cvDisplayLink: CVDisplayLink?
    private var cvCallbackContext: Unmanaged<FrameDisplayLinkTarget>?
    private var cvTickScheduled = false
    private var screenObserver: NSObjectProtocol?
#endif

    init() {
        displayLinkTarget.driver = self
#if !os(macOS)
        displayLinkBackend = MobileFrameDisplayLinkBackend(target: displayLinkTarget)
        installVisibilityObservers()
#endif
    }

    init(tickSource: ManualTickSource) {
        manualTickSource = tickSource
        displayLinkTarget.driver = self
        tickSource.attach(to: self)
    }

    deinit {
        invalidateOnMain()
    }

    /// A snapshot of the counters. Safe on any thread.
    var currentCounters: FrameDriverCounters {
        stateLock.lock()
        defer { stateLock.unlock() }
        return counters
    }

    /// Zeroes the counters at the start of a measurement window.
    func resetCounters() {
        stateLock.lock()
        counters = FrameDriverCounters()
        stateLock.unlock()
    }

    /// Marks the next frame as dirty. This method is safe on any thread.
    func markDirty() {
        var scheduleResume = false
        stateLock.lock()
        if !invalidated {
            dirty = true
            if !running && !resumeScheduled {
                resumeScheduled = true
                scheduleResume = true
            }
        }
        stateLock.unlock()

        if scheduleResume {
            // One block does both: start the link, and draw this frame now
            // instead of waiting for the first vsync after it starts. That
            // wait is what the 150 ms post-input window used to hide, and it
            // only ever helped input — output-only wakeups paid it in full
            // (io-gaps.md G4, WO-C6).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resumeOnMainIfNeeded()
                self.tickAfterResumeIfDue()
            }
        }
    }

    /// The minimum gap between two resume-driven immediate ticks.
    ///
    /// The resume path can only fire while the link is paused, so a flood
    /// cannot reach it — the link is running throughout. This bounds the
    /// pathological case instead: a producer that goes quiet long enough to
    /// pause the link and then wakes it, over and over.
    private static let minimumResumeTickInterval: UInt64 = 16_000_000

    /// The clock the resume rate limit reads. A seam, because a test that
    /// asserts a 16 ms limit against the wall clock passes alone and fails in a
    /// full suite run, where the machine is busy enough for real time to pass
    /// between two statements.
    var nowUptimeNs: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    private func tickAfterResumeIfDue() {
        precondition(Thread.isMainThread)
        let now = nowUptimeNs()

        stateLock.lock()
        // `visibilitySuspended` matters here as much as in the resume itself.
        // Without it this path draws a frame into a window nobody can see, and
        // worse, consumes the dirty flag doing it — so becoming visible again
        // found nothing to draw and showed a stale frame. Caught by
        // `suspendedVisibilityStopsTicking`.
        let due = !invalidated && dirty && !visibilitySuspended
            && (lastResumeTickUptimeNs == 0
                || now &- lastResumeTickUptimeNs >= Self.minimumResumeTickInterval)
        if due {
            lastResumeTickUptimeNs = now
        }
        stateLock.unlock()
        guard due else { return }

        sourceDidTick(isImmediate: true)
    }

    /// Queues one coalesced main-thread tick without waiting for vsync.
    func requestImmediateTick() {
        markDirty()

        var scheduleTick = false
        stateLock.lock()
        if !invalidated && !immediateTickScheduled {
            immediateTickScheduled = true
            scheduleTick = true
        }
        stateLock.unlock()

        if scheduleTick {
            DispatchQueue.main.async { [weak self] in
                self?.sourceDidTick(isImmediate: true)
            }
        }
    }

    /// Permanently stops this driver and releases its display-link resources.
    func invalidate() {
        if Thread.isMainThread {
            invalidateOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.invalidateOnMain()
            }
        }
    }

#if os(macOS)
    /// Binds the driver to the view's current window and display.
    func bind(to view: NSView?) {
        precondition(Thread.isMainThread)
        removeWindowObservers()
        destroyMacBackend()
        boundWindow = view?.window

        guard let view, let window = view.window else { return }
        let forceCV = ProcessInfo.processInfo.environment["SWIFTTERM_FORCE_CVDISPLAYLINK"] == "1"
        if #available(macOS 14.0, *), !forceCV {
            displayLinkBackend = MacFrameDisplayLinkBackend(view: view,
                                                            target: displayLinkTarget)
        } else {
            installCVDisplayLink(for: window)
            // The screen observer is CV-only: it retargets the link at the
            // display the window moved to, which CADisplayLink does itself.
            installScreenObserver(for: window)
        }
        // Visibility observers belong to both backends (io-gaps.md G8b). They
        // used to be installed only alongside the CVDisplayLink, so on macOS
        // 14+ — the default — an occluded terminal kept ticking, and after
        // WO-F4 that means a whole render thread working on pixels nobody can
        // see.
        installVisibilityObservers(for: window)
        updateVisibilityOnMain()
        resumeOnMainIfNeeded()
    }
#endif

#if !os(macOS)
    /// A backgrounded app must not drive its display link: UIKit terminates
    /// processes that keep drawing, and the frames are invisible regardless
    /// (io-gaps.md G8b).
    private func installVisibilityObservers() {
        let center = NotificationCenter.default
        visibilityObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.setVisibilityOnMain(visible: false)
        })
        visibilityObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.setVisibilityOnMain(visible: true)
        })
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for observer in visibilityObservers {
            center.removeObserver(observer)
        }
        visibilityObservers.removeAll()
    }
#endif

    /// Applies a visibility decision. Shared by both platforms; each works out
    /// `visible` its own way.
    ///
    /// Not private so tests can drive it: a unit test has no window to occlude,
    /// miniaturise or hide, and faking the notifications would test AppKit
    /// rather than this class.
    func setVisibilityOnMain(visible: Bool) {
        precondition(Thread.isMainThread)
        stateLock.lock()
        lastReportedVisibility = visible
        stateLock.unlock()
        applyVisibilityPolicyOnMain()
    }

#if os(macOS)
    /// Enables or disables the window visibility policy.
    func setVisibilitySuspensionEnabledOnMain(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        stateLock.lock()
        visibilitySuspensionEnabled = enabled
        stateLock.unlock()
        applyVisibilityPolicyOnMain()
    }

    var isVisibilitySuspensionEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return visibilitySuspensionEnabled
    }
#endif

    private func applyVisibilityPolicyOnMain() {
        precondition(Thread.isMainThread)
        stateLock.lock()
        let shouldSuspend = visibilitySuspensionEnabled && !lastReportedVisibility
        let changed = visibilitySuspended != shouldSuspend
        visibilitySuspended = shouldSuspend
        let wasRunning = running
        if shouldSuspend {
            running = false
        }
        stateLock.unlock()
        guard changed else { return }

        if !shouldSuspend {
            // Through resumeOnMainIfNeeded so the dirty flag still gates it:
            // becoming visible is not by itself a reason to draw.
            resumeOnMainIfNeeded()
            // But if something *did* change while hidden, draw it now rather
            // than at the next vsync. Unocclusion is the idle-wakeup case from
            // WO-C6 — the user just looked at the window — and making them
            // wait a frame for content that has been ready is the same mistake
            // in a more visible place.
            tickAfterResumeIfDue()
        } else if wasRunning {
            pauseBackendOnMain()
        }
    }

    /// True while nothing can see this terminal. Safe on any thread.
    var isVisibilitySuspended: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return visibilitySuspended
    }

    fileprivate func sourceDidTick() {
        sourceDidTick(isImmediate: false)
    }

    private func sourceDidTick(isImmediate: Bool) {
        precondition(Thread.isMainThread)
        var shouldCall = false
        var shouldPause = false

        stateLock.lock()
        if isImmediate {
            immediateTickScheduled = false
            counters.immediateTicks += 1
        }
        counters.ticks += 1
        if !invalidated {
            if dirty {
                dirty = false
                idleTickCount = 0
                shouldCall = true
                counters.frames += 1
            } else if running {
                idleTickCount += 1
                counters.idleTicks += 1
                if idleTickCount >= Self.idleTickLimit {
                    idleTickCount = 0
                    running = false
                    shouldPause = true
                    counters.pauses += 1
                }
            }
        }
        stateLock.unlock()

        if shouldCall {
            onTick?()
        }
        if shouldPause {
            pauseBackendOnMain()
        }
    }

    private func resumeOnMainIfNeeded() {
        precondition(Thread.isMainThread)

        stateLock.lock()
        resumeScheduled = false
        let shouldStart = !invalidated && dirty && !running
        stateLock.unlock()
        guard shouldStart, canRunBackendOnMain() else { return }

        startBackendOnMain()
        stateLock.lock()
        if !invalidated {
            running = true
            idleTickCount = 0
        }
        stateLock.unlock()
    }

    private func canRunBackendOnMain() -> Bool {
        stateLock.lock()
        let suspended = visibilitySuspended
        stateLock.unlock()
        // Suspension applies to every backend, including the manual test
        // source. A driver with a manual source never binds a window, so it is
        // only ever suspended by a test asking for it.
        if suspended {
            return false
        }
        if manualTickSource != nil || displayLinkBackend != nil {
            return true
        }
#if os(macOS)
        return cvDisplayLink != nil
#else
        return false
#endif
    }

    private func startBackendOnMain() {
        manualTickSource?.start()
        displayLinkBackend?.start()
#if os(macOS)
        if let cvDisplayLink {
            CVDisplayLinkStart(cvDisplayLink)
        }
#endif
    }

    private func pauseBackendOnMain() {
        manualTickSource?.stop()
        displayLinkBackend?.stop()
#if os(macOS)
        if let cvDisplayLink {
            CVDisplayLinkStop(cvDisplayLink)
        }
#endif
    }

    private func invalidateOnMain() {
        stateLock.lock()
        let needsInvalidation = !invalidated
        invalidated = true
        dirty = false
        running = false
        resumeScheduled = false
        immediateTickScheduled = false
        stateLock.unlock()
        guard needsInvalidation else { return }

        manualTickSource?.invalidate()
        manualTickSource = nil
        displayLinkBackend?.invalidate()
        displayLinkBackend = nil
        // Both platforms now hold observers; iOS installs its pair in init and
        // therefore has to drop them here too.
        removeWindowObservers()
#if os(macOS)
        destroyMacBackend()
        boundWindow = nil
#endif
        displayLinkTarget.driver = nil
        onTick = nil
    }

#if os(macOS)
    private func installCVDisplayLink(for window: NSWindow) {
        guard let displayID = displayID(for: window) else { return }
        var newLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &newLink) == kCVReturnSuccess,
              let newLink else { return }

        // The callback fires on a CoreVideo thread and can be in flight while
        // this driver deallocates. Pass a RETAINED target that holds only a
        // weak driver reference: the retain keeps the target alive for any
        // in-flight callback, and the weak load safely yields nil once the
        // driver is gone. Balanced by a release in destroyMacBackend.
        cvCallbackContext = Unmanaged.passRetained(displayLinkTarget)
        CVDisplayLinkSetOutputCallback(newLink, { _, _, _, _, _, context in
            guard let context else { return kCVReturnError }
            let target = Unmanaged<FrameDisplayLinkTarget>.fromOpaque(context).takeUnretainedValue()
            target.driver?.scheduleCVTickOnMain()
            return kCVReturnSuccess
        }, cvCallbackContext!.toOpaque())
        cvDisplayLink = newLink
    }

    private func displayID(for window: NSWindow) -> CGDirectDisplayID? {
        guard let number = window.screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func scheduleCVTickOnMain() {
        stateLock.lock()
        guard !invalidated, !cvTickScheduled else {
            stateLock.unlock()
            return
        }
        cvTickScheduled = true
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.cvTickScheduled = false
            let valid = !self.invalidated
            self.stateLock.unlock()
            if valid {
                self.sourceDidTick()
            }
        }
    }

    private func installScreenObserver(for window: NSWindow) {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.rebindCVDisplayLinkOnMain()
        }
    }

    /// Everything that means "nobody can see this terminal".
    ///
    /// Occlusion alone is not enough: a miniaturised window reports itself
    /// visible, and hiding the application does not change any window's
    /// occlusion state at all.
    private func installVisibilityObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        let windowNames: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in windowNames {
            visibilityObservers.append(center.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                self?.updateVisibilityOnMain()
            })
        }
        let appNames: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        for name in appNames {
            visibilityObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.updateVisibilityOnMain()
            })
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        if let screenObserver {
            center.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for observer in visibilityObservers {
            center.removeObserver(observer)
        }
        visibilityObservers.removeAll()
    }

    private func isVisibleOnMain() -> Bool {
        guard let window = boundWindow else { return false }
        if NSApp?.isHidden == true { return false }
        if window.isMiniaturized { return false }
        return window.occlusionState.contains(.visible)
    }

    private func rebindCVDisplayLinkOnMain() {
        guard let window = boundWindow, let displayID = displayID(for: window),
              let cvDisplayLink else { return }
        CVDisplayLinkSetCurrentCGDisplay(cvDisplayLink, displayID)
    }

    private func updateVisibilityOnMain() {
        setVisibilityOnMain(visible: isVisibleOnMain())
    }

    private func destroyMacBackend() {
        displayLinkBackend?.invalidate()
        displayLinkBackend = nil
        if let cvDisplayLink {
            CVDisplayLinkStop(cvDisplayLink)
            self.cvDisplayLink = nil
        }
        if let context = cvCallbackContext {
            context.release()
            cvCallbackContext = nil
        }
        stateLock.lock()
        running = false
        cvTickScheduled = false
        stateLock.unlock()
    }
#endif
}
#endif
