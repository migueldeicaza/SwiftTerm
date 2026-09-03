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

/// A thread-safe handle that publishes work to a main-actor frame driver.
///
/// The handle contains no view, display-link, or other UI state. Its locked
/// event set also limits publication to one pending main-actor task. A producer
/// can keep this handle without keeping the terminal view or its driver alive.
final class FrameDriverSignal: Sendable {
    fileprivate struct Events: OptionSet, Sendable {
        let rawValue: UInt8

        static let dirty = Events(rawValue: 1 << 0)
        static let immediate = Events(rawValue: 1 << 1)
        static let displayLink = Events(rawValue: 1 << 2)
        static let shutdown = Events(rawValue: 1 << 3)
    }

    typealias Sink = @MainActor @Sendable () -> Void

    private struct State: Sendable {
        var pending: Events = []
        var deliveryScheduled = false
        var shutdownRequested = false
        var sinkConfigured = false
        var sink: Sink?
    }

    private let state = Locked(State())

    /// Installs the only sink this signal will use.
    @MainActor
    func configure(sink: @escaping Sink) {
        var mustDeliver = false
        state.withLock { state in
            precondition(!state.sinkConfigured, "FrameDriverSignal sink configured twice")
            state.sinkConfigured = true
            state.sink = sink
            if !state.pending.isEmpty && !state.deliveryScheduled {
                state.deliveryScheduled = true
                mustDeliver = true
            }
        }
        if mustDeliver {
            Task { @MainActor in sink() }
        }
    }

    /// Marks the next frame as dirty. Safe on any thread.
    func markDirty() {
        publish([.dirty])
    }

    /// Requests one coalesced tick without waiting for display cadence.
    func requestImmediateTick() {
        publish([.dirty, .immediate])
    }

    /// Permanently stops the attached driver. Safe on any thread.
    func requestShutdown() {
        var sink: Sink?
        state.withLock { state in
            guard !state.shutdownRequested else { return }
            state.shutdownRequested = true
            state.pending = [.shutdown]
            guard !state.deliveryScheduled, let configuredSink = state.sink else { return }
            state.deliveryScheduled = true
            sink = configuredSink
        }
        schedule(sink)
    }

    fileprivate func publishDisplayLinkTick() {
        publish([.displayLink])
    }

    @MainActor
    fileprivate func takePendingEvents() -> Events {
        state.withLock { state in
            let pending = state.pending
            state.pending = []
            state.deliveryScheduled = false
            return pending
        }
    }

    @MainActor
    fileprivate func detachSink() {
        state.withLock { state in
            state.sink = nil
            state.pending = []
            state.deliveryScheduled = false
        }
    }

    private func publish(_ events: Events) {
        var sink: Sink?
        state.withLock { state in
            guard !state.shutdownRequested else { return }
            state.pending.formUnion(events)
            guard !state.deliveryScheduled, let configuredSink = state.sink else { return }
            state.deliveryScheduled = true
            sink = configuredSink
        }
        schedule(sink)
    }

    private func schedule(_ sink: Sink?) {
        guard let sink else { return }
        Task { @MainActor in sink() }
    }
}

/// A synchronous display-link replacement for unit tests.
@MainActor
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

@MainActor
private final class FrameDisplayLinkTarget: NSObject {
    weak var driver: FrameDriver?

    @objc func displayLinkFired(_ sender: Any) {
        driver?.sourceDidTick()
    }
}

@MainActor
private protocol FrameDisplayLinkBackend: AnyObject {
    func start()
    func stop()
    func invalidate()
}

#if os(macOS)
@available(macOS 14.0, *)
@MainActor
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
@MainActor
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

/// Counters that describe frame-driver behavior over a measurement window.
struct FrameDriverCounters: Sendable {
    var ticks = 0
    var frames = 0
    var idleTicks = 0
    var pauses = 0
    var immediateTicks = 0
}

/// Coalesces terminal changes and submits them at the display cadence.
@MainActor
final class FrameDriver {
    static let idleTickLimit = 8
    private static let minimumResumeTickInterval: UInt64 = 16_000_000

    /// A producer-safe handle. It does not retain this driver.
    nonisolated let signal: FrameDriverSignal

    /// The view installs a weakly captured frame callback here.
    var onTick: (() -> Void)?

    /// Publishes the same effective visibility that controls frame suspension.
    var onVisibilityChanged: ((Bool) -> Void)?

    private var dirty = false
    private var running = false
    private var invalidated = false
    private var lastResumeTickUptimeNs: UInt64 = 0
    private var visibilitySuspended = false
    private var visibilitySuspensionEnabled = true
    private var effectivelyVisible = true
    private var lastReportedVisibility = true
    private var windowAttached = true
    private var visibilityObservers: [NSObjectProtocol] = []
    private var idleTickCount = 0
    private var counters = FrameDriverCounters()

    private let displayLinkTarget = FrameDisplayLinkTarget()
    private var displayLinkBackend: FrameDisplayLinkBackend?
    private var manualTickSource: ManualTickSource?

#if os(macOS)
    private weak var boundWindow: NSWindow?
    private var cvDisplayLink: CVDisplayLink?
    private var cvCallbackContext: Unmanaged<FrameDriverSignal>?
    private var screenObserver: NSObjectProtocol?
#endif

    init(signal: FrameDriverSignal = FrameDriverSignal()) {
        self.signal = signal
        displayLinkTarget.driver = self
#if !os(macOS)
        displayLinkBackend = MobileFrameDisplayLinkBackend(target: displayLinkTarget)
        installVisibilityObservers()
#endif
        configureSignal(signal)
    }

    init(tickSource: ManualTickSource) {
        let signal = FrameDriverSignal()
        self.signal = signal
        manualTickSource = tickSource
        displayLinkTarget.driver = self
        tickSource.attach(to: self)
        configureSignal(signal)
    }

    nonisolated deinit {
        // UI resources are released by explicit main-actor shutdown. Deinit can
        // only close the independently synchronized producer handle.
        signal.requestShutdown()
    }

    private func configureSignal(_ signal: FrameDriverSignal) {
        signal.configure { [weak self] in
            self?.consumeSignalOnMain()
        }
    }

    private func consumeSignalOnMain() {
        let events = signal.takePendingEvents()
        guard !events.isEmpty else { return }
        if events.contains(.shutdown) {
            shutdownResourcesOnMain()
            return
        }
        guard !invalidated else { return }

        if events.contains(.dirty) {
            dirty = true
            if resumeOnMainIfNeeded() {
                tickAfterResumeIfDue()
            }
        }
        if events.contains(.immediate) {
            sourceDidTick(isImmediate: true)
        }
        if events.contains(.displayLink) {
            sourceDidTick()
        }
    }

    var currentCounters: FrameDriverCounters {
        counters
    }

    func resetCounters() {
        counters = FrameDriverCounters()
    }

    /// Marks the next frame as dirty. Safe on any thread.
    nonisolated func markDirty() {
        signal.markDirty()
    }

    /// Queues one coalesced main-actor tick without waiting for vsync.
    nonisolated func requestImmediateTick() {
        signal.requestImmediateTick()
    }

    /// The clock used by the resume rate limit.
    var nowUptimeNs: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    private func tickAfterResumeIfDue() {
        let now = nowUptimeNs()
        let due = !invalidated && dirty && !visibilitySuspended
            && (lastResumeTickUptimeNs == 0
                || now &- lastResumeTickUptimeNs >= Self.minimumResumeTickInterval)
        guard due else { return }
        lastResumeTickUptimeNs = now
        sourceDidTick(isImmediate: true)
    }

    /// Permanently stops this driver and releases its UI resources.
    func shutdown() {
        signal.requestShutdown()
        consumeSignalOnMain()
    }

    /// Compatibility name for permanent main-actor shutdown.
    func invalidate() {
        shutdown()
    }

#if os(macOS)
    /// Rebinds the driver. Passing nil only unbinds the current window; it does
    /// not permanently shut down the driver.
    func bind(to view: NSView?) {
        removeWindowObservers()
        destroyMacBackend()
        boundWindow = view?.window
        windowAttached = boundWindow != nil
        if windowAttached {
            lastReportedVisibility = isVisibleOnMain()
        }
        applyVisibilityPolicyOnMain()

        guard let view, let window = view.window, !invalidated else { return }
        let forceCV = ProcessInfo.processInfo.environment["SWIFTTERM_FORCE_CVDISPLAYLINK"] == "1"
        if #available(macOS 14.0, *), !forceCV {
            displayLinkBackend = MacFrameDisplayLinkBackend(view: view,
                                                            target: displayLinkTarget)
        } else {
            installCVDisplayLink(for: window)
            installScreenObserver(for: window)
        }
        installVisibilityObservers(for: window)
        updateVisibilityOnMain()
        resumeOnMainIfNeeded()
    }
#endif

#if !os(macOS)
    private func installVisibilityObservers() {
        let center = NotificationCenter.default
        visibilityObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setVisibilityOnMain(visible: false)
            }
        })
        visibilityObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setVisibilityOnMain(visible: true)
            }
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

    func setVisibilityOnMain(visible: Bool) {
        lastReportedVisibility = visible
        applyVisibilityPolicyOnMain()
    }

    /// Reports whether the view has a window without permanently stopping the
    /// driver. Mobile views can leave and later re-enter a window hierarchy, so
    /// attachment is a reversible visibility input, not a shutdown event.
    func setWindowAttachedOnMain(_ attached: Bool) {
        windowAttached = attached
        applyVisibilityPolicyOnMain()
    }

#if os(macOS)
    func setVisibilitySuspensionEnabledOnMain(_ enabled: Bool) {
        visibilitySuspensionEnabled = enabled
        applyVisibilityPolicyOnMain()
    }

    var isVisibilitySuspensionEnabled: Bool {
        visibilitySuspensionEnabled
    }
#endif

    private func applyVisibilityPolicyOnMain() {
        let visible = lastReportedVisibility && windowAttached
        let visibilityChanged = effectivelyVisible != visible
        effectivelyVisible = visible
        if visibilityChanged {
            onVisibilityChanged?(visible)
        }
        let shouldSuspend = visibilitySuspensionEnabled && !visible
        let changed = visibilitySuspended != shouldSuspend
        let wasRunning = running
        visibilitySuspended = shouldSuspend
        if shouldSuspend {
            running = false
        }
        guard changed else { return }

        if !shouldSuspend {
            if resumeOnMainIfNeeded() {
                tickAfterResumeIfDue()
            }
        } else if wasRunning {
            pauseBackendOnMain()
        }
    }

    var isVisibilitySuspended: Bool {
        visibilitySuspended
    }

    fileprivate func sourceDidTick() {
        // A producer can mark the frame dirty immediately before the display
        // callback runs. Consume that pending value signal first, so this
        // cadence tick sees the change even if its queued main-actor delivery
        // has not run yet. A running backend still does not draw until here.
        consumeSignalOnMain()
        sourceDidTick(isImmediate: false)
    }

    private func sourceDidTick(isImmediate: Bool) {
        guard !invalidated else { return }
        var shouldCall = false
        var shouldPause = false

        if isImmediate {
            counters.immediateTicks += 1
        }
        counters.ticks += 1
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

        if shouldCall {
            onTick?()
        }
        if shouldPause {
            pauseBackendOnMain()
        }
    }

    @discardableResult
    private func resumeOnMainIfNeeded() -> Bool {
        let shouldStart = !invalidated && dirty && !running
        guard shouldStart, canRunBackendOnMain() else { return false }

        startBackendOnMain()
        if !invalidated {
            running = true
            idleTickCount = 0
            return true
        }
        return false
    }

    private func canRunBackendOnMain() -> Bool {
        if visibilitySuspended {
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

    private func shutdownResourcesOnMain() {
        guard !invalidated else { return }
        invalidated = true
        dirty = false
        running = false

        manualTickSource?.invalidate()
        manualTickSource = nil
        displayLinkBackend?.invalidate()
        displayLinkBackend = nil
        removeWindowObservers()
#if os(macOS)
        destroyMacBackend()
        boundWindow = nil
#endif
        displayLinkTarget.driver = nil
        onTick = nil
        signal.detachSink()
    }

#if os(macOS)
    private func installCVDisplayLink(for window: NSWindow) {
        guard let displayID = displayID(for: window) else { return }
        var newLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &newLink) == kCVReturnSuccess,
              let newLink else { return }

        // Core Video can call this on its private thread. The retained context
        // contains only the checked-Sendable signal. That signal coalesces the
        // callback and explicitly enters MainActor before it reaches UI state.
        cvCallbackContext = Unmanaged.passRetained(signal)
        CVDisplayLinkSetOutputCallback(newLink, { _, _, _, _, _, context in
            guard let context else { return kCVReturnError }
            let signal = Unmanaged<FrameDriverSignal>
                .fromOpaque(context).takeUnretainedValue()
            signal.publishDisplayLinkTick()
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

    private func installScreenObserver(for window: NSWindow) {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebindCVDisplayLinkOnMain()
            }
        }
    }

    private func installVisibilityObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        let windowNames: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in windowNames {
            visibilityObservers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateVisibilityOnMain()
                }
            })
        }
        let appNames: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        for name in appNames {
            visibilityObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateVisibilityOnMain()
                }
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
        guard let window = boundWindow,
              let displayID = displayID(for: window),
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
        running = false
    }
#endif
}
#endif
