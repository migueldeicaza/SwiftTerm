#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import Metal
#if canImport(os)
import os
#endif

/// The current state of the optional Metal terminal renderer.
public struct MetalRendererStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case disabled
        case waitingForFirstFrame
        case healthy
        case recovering
        case fellBackToCoreGraphics
    }

    public let state: State
    public let presentedFrameCount: UInt64
    public let lastFramePresentedAt: Date?

    public init(state: State,
                presentedFrameCount: UInt64,
                lastFramePresentedAt: Date?) {
        self.state = state
        self.presentedFrameCount = presentedFrameCount
        self.lastFramePresentedAt = lastFramePresentedAt
    }
}

public extension Notification.Name {
    /// Posted when a terminal view's Metal renderer state changes or presents a frame.
    static let terminalViewMetalRendererStatusDidChange = Notification.Name(
        "SwiftTerm.TerminalView.metalRendererStatusDidChange"
    )
}

enum MetalFrameRefusalReason: String, Equatable, Sendable {
    case activeFrame
    case missingDrawable
    case missingRenderPassDescriptor
    case missingCommandBuffer
    case missingRenderEncoder
}

enum MetalTrackedCommandBufferStatus: String, Equatable, Sendable {
    case notEnqueued
    case enqueued
    case committed
    case scheduled
    case completed
    case error

    init(_ status: MTLCommandBufferStatus) {
        switch status {
        case .notEnqueued:
            self = .notEnqueued
        case .enqueued:
            self = .enqueued
        case .committed:
            self = .committed
        case .scheduled:
            self = .scheduled
        case .completed:
            self = .completed
        case .error:
            self = .error
        @unknown default:
            self = .error
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .error
    }
}

struct MetalRendererRecoveryReport: Equatable, Sendable {
    let reason: MetalFrameRefusalReason
    let failureDuration: TimeInterval
    let commandBufferStatus: MetalTrackedCommandBufferStatus?
    let commandBufferError: String?
}

struct MetalAutomaticRecoveryPolicy: Sendable {
    enum Action: Equatable, Sendable {
        case replaceMetal
        case fallBackToCoreGraphics
    }

    private(set) var lastReplacementAt: TimeInterval?

    mutating func action(at now: TimeInterval) -> Action {
        if let lastReplacementAt, now - lastReplacementAt < 30 {
            return .fallBackToCoreGraphics
        }
        lastReplacementAt = now
        return .replaceMetal
    }

    mutating func reset() {
        lastReplacementAt = nil
    }
}

#if canImport(os)
enum MetalRecoverySignpost {
    static let log = OSLog(subsystem: "org.tirania.SwiftTerm", category: "MetalProfile")
    static let isEnabled = ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE"] == "1"

    static func begin() -> OSSignpostID? {
        guard isEnabled else { return nil }
        let identifier = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Metal.Recovery", signpostID: identifier)
        return identifier
    }

    static func end(_ identifier: OSSignpostID?) {
        guard let identifier else { return }
        os_signpost(.end, log: log, name: "Metal.Recovery", signpostID: identifier)
    }
}
#endif

protocol MetalRecoveryClock: AnyObject {
    var now: TimeInterval { get }
}

protocol MetalRecoveryScheduledTask: AnyObject {
    func cancel()
}

protocol MetalRecoveryScheduler: AnyObject {
    func schedule(after delay: TimeInterval,
                  _ action: @escaping () -> Void) -> MetalRecoveryScheduledTask
}

private final class SystemMetalRecoveryClock: MetalRecoveryClock {
    var now: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

private final class DispatchMetalRecoveryTask: MetalRecoveryScheduledTask {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

private final class DispatchMetalRecoveryScheduler: MetalRecoveryScheduler {
    func schedule(after delay: TimeInterval,
                  _ action: @escaping () -> Void) -> MetalRecoveryScheduledTask {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return DispatchMetalRecoveryTask(item: item)
    }
}

/// Coordinates one in-flight frame, refused-frame retries, and watchdog recovery.
///
/// All mutable state is protected by `lock`. Callbacks run without the lock.
final class MetalFrameCoordinator {
    struct Token: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    private struct CommandBufferProbe {
        let status: () -> MetalTrackedCommandBufferStatus
        let error: () -> String?
    }

    private struct ActiveFrame {
        let token: Token
        let startedAt: TimeInterval
        var commandBuffer: CommandBufferProbe?
        var pendingRedraw = false
        var recoveryRequested = false
        var watchdog: MetalRecoveryScheduledTask?
    }

    private static let retryDelays: [TimeInterval] = [0.016, 0.033, 0.066, 0.125, 0.250]
    private static let watchdogDelay: TimeInterval = 1.0

    private let lock = NSLock()
    private let clock: MetalRecoveryClock
    private let scheduler: MetalRecoveryScheduler
    private let isRetryEligible: () -> Bool
    private let requestDraw: (MetalFrameRefusalReason) -> Void
    private let requestRecovery: (MetalRendererRecoveryReport) -> Void
    private let becameIdle: () -> Void

    private var nextToken: UInt64 = 1
    private var activeFrame: ActiveFrame?
    private var retryIndex = 0
    private var retryTask: MetalRecoveryScheduledTask?
    private var failureStartedAt: TimeInterval?
    private var lastFailureReason: MetalFrameRefusalReason?
    private var failureWatchdog: MetalRecoveryScheduledTask?
    private var failureRecoveryRequested = false
    private var invalidated = false

    convenience init(isRetryEligible: @escaping () -> Bool,
                     requestDraw: @escaping (MetalFrameRefusalReason) -> Void,
                     requestRecovery: @escaping (MetalRendererRecoveryReport) -> Void,
                     becameIdle: @escaping () -> Void) {
        self.init(clock: SystemMetalRecoveryClock(),
                  scheduler: DispatchMetalRecoveryScheduler(),
                  isRetryEligible: isRetryEligible,
                  requestDraw: requestDraw,
                  requestRecovery: requestRecovery,
                  becameIdle: becameIdle)
    }

    init(clock: MetalRecoveryClock,
         scheduler: MetalRecoveryScheduler,
         isRetryEligible: @escaping () -> Bool,
         requestDraw: @escaping (MetalFrameRefusalReason) -> Void,
         requestRecovery: @escaping (MetalRendererRecoveryReport) -> Void,
         becameIdle: @escaping () -> Void = {}) {
        self.clock = clock
        self.scheduler = scheduler
        self.isRetryEligible = isRetryEligible
        self.requestDraw = requestDraw
        self.requestRecovery = requestRecovery
        self.becameIdle = becameIdle
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeFrame == nil
    }

    var hasPendingRedraw: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeFrame?.pendingRedraw ?? false
    }

    func beginFrame() -> Token? {
        lock.lock()
        if var activeFrame {
            activeFrame.pendingRedraw = true
            if activeFrame.watchdog == nil,
               !activeFrame.recoveryRequested,
               isRetryEligible() {
                let token = activeFrame.token
                activeFrame.watchdog = scheduler.schedule(after: Self.watchdogDelay) { [weak self] in
                    self?.frameWatchdogFired(token: token)
                }
            }
            self.activeFrame = activeFrame
            scheduleRetryLocked(reason: .activeFrame)
            lock.unlock()
            return nil
        }
        guard !invalidated else {
            lock.unlock()
            return nil
        }

        let token = Token(value: nextToken)
        nextToken &+= 1
        var frame = ActiveFrame(token: token, startedAt: clock.now)
        if isRetryEligible() {
            frame.watchdog = scheduler.schedule(after: Self.watchdogDelay) { [weak self] in
                self?.frameWatchdogFired(token: token)
            }
        }
        activeFrame = frame
        lock.unlock()
        return token
    }

    func refuse(_ token: Token, reason: MetalFrameRefusalReason) {
        var notifyIdle = false
        lock.lock()
        guard activeFrame?.token == token else {
            lock.unlock()
            return
        }
        activeFrame?.watchdog?.cancel()
        activeFrame = nil
        notifyIdle = true
        startFailureEpisodeLocked(reason: reason)
        scheduleRetryLocked(reason: reason)
        lock.unlock()
        if notifyIdle {
            becameIdle()
        }
    }

    func didSubmit(_ token: Token, commandBuffer: MTLCommandBuffer) {
        didSubmit(token,
                  status: { MetalTrackedCommandBufferStatus(commandBuffer.status) },
                  error: { commandBuffer.error.map(String.init(describing:)) })
    }

    func didSubmit(_ token: Token,
                   status: @escaping () -> MetalTrackedCommandBufferStatus,
                   error: @escaping () -> String?) {
        lock.lock()
        guard var activeFrame, activeFrame.token == token else {
            lock.unlock()
            return
        }
        activeFrame.commandBuffer = CommandBufferProbe(status: status, error: error)
        self.activeFrame = activeFrame
        resetFailureEpisodeLocked()
        lock.unlock()
    }

    func complete(_ token: Token,
                  status: MetalTrackedCommandBufferStatus,
                  error: String?) {
        var needsRedraw = false
        var report: MetalRendererRecoveryReport?
        lock.lock()
        guard let activeFrame, activeFrame.token == token else {
            lock.unlock()
            return
        }
        needsRedraw = activeFrame.pendingRedraw
        activeFrame.watchdog?.cancel()
        self.activeFrame = nil
        if status == .error && !invalidated {
            report = MetalRendererRecoveryReport(
                reason: .activeFrame,
                failureDuration: max(0, clock.now - activeFrame.startedAt),
                commandBufferStatus: status,
                commandBufferError: error
            )
        }
        lock.unlock()

        becameIdle()
        if let report {
            requestRecovery(report)
        } else if needsRedraw && !isInvalidated {
            requestDraw(.activeFrame)
        }
    }

    func invalidate() {
        var notifyIdle = false
        lock.lock()
        invalidated = true
        retryTask?.cancel()
        retryTask = nil
        failureWatchdog?.cancel()
        failureWatchdog = nil
        if let activeFrame, activeFrame.commandBuffer == nil {
            activeFrame.watchdog?.cancel()
            self.activeFrame = nil
            notifyIdle = true
        }
        lock.unlock()
        if notifyIdle {
            becameIdle()
        }
    }

#if DEBUG
    func injectHeldFrameForTesting() {
        _ = beginFrame()
    }
#endif

    private var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    private func scheduleRetryLocked(reason: MetalFrameRefusalReason) {
        guard !invalidated, retryTask == nil, isRetryEligible() else {
            return
        }
        let index = min(retryIndex, Self.retryDelays.count - 1)
        let delay = Self.retryDelays[index]
        retryIndex = min(retryIndex + 1, Self.retryDelays.count - 1)
        retryTask = scheduler.schedule(after: delay) { [weak self] in
            self?.retryFired(reason: reason)
        }
    }

    private func retryFired(reason: MetalFrameRefusalReason) {
        lock.lock()
        retryTask = nil
        guard !invalidated, isRetryEligible() else {
            lock.unlock()
            return
        }
        lock.unlock()

        requestDraw(reason)

        lock.lock()
        scheduleRetryLocked(reason: reason)
        lock.unlock()
    }

    private func startFailureEpisodeLocked(reason: MetalFrameRefusalReason) {
        lastFailureReason = reason
        guard isRetryEligible() else {
            failureStartedAt = nil
            failureWatchdog?.cancel()
            failureWatchdog = nil
            failureRecoveryRequested = false
            retryIndex = 0
            return
        }
        if failureStartedAt == nil {
            failureStartedAt = clock.now
            failureRecoveryRequested = false
            failureWatchdog = scheduler.schedule(after: Self.watchdogDelay) { [weak self] in
                self?.failureWatchdogFired()
            }
        }
    }

    private func resetFailureEpisodeLocked() {
        retryTask?.cancel()
        retryTask = nil
        retryIndex = 0
        failureWatchdog?.cancel()
        failureWatchdog = nil
        failureStartedAt = nil
        lastFailureReason = nil
        failureRecoveryRequested = false
    }

    private func frameWatchdogFired(token: Token) {
        var probe: CommandBufferProbe?
        var startedAt: TimeInterval = 0
        lock.lock()
        guard var activeFrame,
              activeFrame.token == token,
              !activeFrame.recoveryRequested,
              !invalidated else {
            lock.unlock()
            return
        }
        activeFrame.watchdog = nil
        guard isRetryEligible() else {
            self.activeFrame = activeFrame
            lock.unlock()
            return
        }
        activeFrame.recoveryRequested = true
        self.activeFrame = activeFrame
        probe = activeFrame.commandBuffer
        startedAt = activeFrame.startedAt
        lock.unlock()

        let status = probe?.status()
        let error = probe?.error()
        if status == .completed {
            complete(token, status: .completed, error: nil)
            return
        }
        if status == .error {
            complete(token, status: .error, error: error)
            return
        }

        requestRecovery(MetalRendererRecoveryReport(
            reason: .activeFrame,
            failureDuration: max(0, clock.now - startedAt),
            commandBufferStatus: status,
            commandBufferError: error
        ))
    }

    private func failureWatchdogFired() {
        var report: MetalRendererRecoveryReport?
        lock.lock()
        failureWatchdog = nil
        if !invalidated && !isRetryEligible() {
            failureStartedAt = nil
            lastFailureReason = nil
            failureRecoveryRequested = false
            retryIndex = 0
            lock.unlock()
            return
        }
        if !invalidated,
           !failureRecoveryRequested,
           let startedAt = failureStartedAt,
           let reason = lastFailureReason {
            failureRecoveryRequested = true
            report = MetalRendererRecoveryReport(
                reason: reason,
                failureDuration: max(0, clock.now - startedAt),
                commandBufferStatus: nil,
                commandBufferError: nil
            )
        }
        lock.unlock()
        if let report {
            requestRecovery(report)
        }
    }
}
#endif
