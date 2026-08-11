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
    private var idleTickCount = 0

    private let displayLinkTarget = FrameDisplayLinkTarget()
    private var displayLinkBackend: FrameDisplayLinkBackend?
    private var manualTickSource: ManualTickSource?

#if os(macOS)
    private weak var boundWindow: NSWindow?
    private var cvDisplayLink: CVDisplayLink?
    private var cvCallbackContext: Unmanaged<FrameDisplayLinkTarget>?
    private var cvTickScheduled = false
    private var screenObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
#endif

    init() {
        displayLinkTarget.driver = self
#if !os(macOS)
        displayLinkBackend = MobileFrameDisplayLinkBackend(target: displayLinkTarget)
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
            DispatchQueue.main.async { [weak self] in
                self?.resumeOnMainIfNeeded()
            }
        }
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
            installWindowObservers(for: window)
        }
        resumeOnMainIfNeeded()
    }
#endif

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
        }
        if !invalidated {
            if dirty {
                dirty = false
                idleTickCount = 0
                shouldCall = true
            } else if running {
                idleTickCount += 1
                if idleTickCount >= Self.idleTickLimit {
                    idleTickCount = 0
                    running = false
                    shouldPause = true
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
        if manualTickSource != nil || displayLinkBackend != nil {
            return true
        }
#if os(macOS)
        guard cvDisplayLink != nil else { return false }
        if let window = boundWindow, !window.occlusionState.contains(.visible) {
            return false
        }
        return true
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
#if os(macOS)
        removeWindowObservers()
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

    private func installWindowObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        screenObserver = center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.rebindCVDisplayLinkOnMain()
        }
        occlusionObserver = center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.occlusionChangedOnMain()
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        if let screenObserver {
            center.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let occlusionObserver {
            center.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
    }

    private func rebindCVDisplayLinkOnMain() {
        guard let window = boundWindow, let displayID = displayID(for: window),
              let cvDisplayLink else { return }
        CVDisplayLinkSetCurrentCGDisplay(cvDisplayLink, displayID)
    }

    private func occlusionChangedOnMain() {
        guard let window = boundWindow else {
            pauseForOcclusionOnMain()
            return
        }
        if window.occlusionState.contains(.visible) {
            resumeOnMainIfNeeded()
        } else {
            pauseForOcclusionOnMain()
        }
    }

    private func pauseForOcclusionOnMain() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()
        if wasRunning {
            pauseBackendOnMain()
        }
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
