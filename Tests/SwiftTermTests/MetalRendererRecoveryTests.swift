#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

private final class TestMetalRecoveryClock: MetalRecoveryClock {
    var now: TimeInterval = 0
}

private final class TestMetalRecoveryTask: MetalRecoveryScheduledTask {
    let delay: TimeInterval
    let action: () -> Void
    private(set) var isCancelled = false
    private(set) var hasRun = false

    init(delay: TimeInterval, action: @escaping () -> Void) {
        self.delay = delay
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func run() {
        guard !isCancelled, !hasRun else { return }
        hasRun = true
        action()
    }
}

private final class TestMetalRecoveryScheduler: MetalRecoveryScheduler {
    private(set) var tasks: [TestMetalRecoveryTask] = []

    func schedule(after delay: TimeInterval,
                  _ action: @escaping () -> Void) -> MetalRecoveryScheduledTask {
        let task = TestMetalRecoveryTask(delay: delay, action: action)
        tasks.append(task)
        return task
    }

    var activeRetryTasks: [TestMetalRecoveryTask] {
        tasks.filter { !$0.isCancelled && !$0.hasRun && $0.delay < 1 }
    }

    var activeWatchdogs: [TestMetalRecoveryTask] {
        tasks.filter { !$0.isCancelled && !$0.hasRun && $0.delay == 1 }
    }
}

@Suite struct MetalRendererRecoveryTests {
    private func makeCoordinator(
        clock: TestMetalRecoveryClock,
        scheduler: TestMetalRecoveryScheduler,
        eligible: @escaping () -> Bool = { true },
        draws: @escaping (MetalFrameRefusalReason) -> Void = { _ in },
        recoveries: @escaping (MetalRendererRecoveryReport) -> Void = { _ in }
    ) -> MetalFrameCoordinator {
        MetalFrameCoordinator(
            clock: clock,
            scheduler: scheduler,
            isRetryEligible: eligible,
            requestDraw: draws,
            requestRecovery: recoveries
        )
    }

    @Test func busyFrameRecordsPendingRedrawAndCoalescesRetry() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        let coordinator = makeCoordinator(clock: clock, scheduler: scheduler)

        _ = try #require(coordinator.beginFrame())
        #expect(coordinator.beginFrame() == nil)
        #expect(coordinator.beginFrame() == nil)
        #expect(coordinator.hasPendingRedraw)
        #expect(scheduler.activeRetryTasks.map(\.delay) == [0.016])
    }

    @Test func earlyFailureReleasesTokenAndSchedulesRetry() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        let coordinator = makeCoordinator(clock: clock, scheduler: scheduler)
        let token = try #require(coordinator.beginFrame())

        coordinator.refuse(token, reason: .missingDrawable)

        #expect(coordinator.isIdle)
        #expect(scheduler.activeRetryTasks.map(\.delay) == [0.016])
        #expect(scheduler.activeWatchdogs.count == 1)
    }

    @Test func retryTasksUseDelaySequenceAndCoalesce() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        var drawCount = 0
        let coordinator = makeCoordinator(
            clock: clock,
            scheduler: scheduler,
            draws: { _ in drawCount += 1 }
        )
        let token = try #require(coordinator.beginFrame())
        coordinator.refuse(token, reason: .missingDrawable)

        var observed: [TimeInterval] = []
        for _ in 0..<7 {
            let task = try #require(scheduler.activeRetryTasks.last)
            observed.append(task.delay)
            task.run()
        }

        #expect(observed == [0.016, 0.033, 0.066, 0.125, 0.250, 0.250, 0.250])
        #expect(drawCount == 7)
        #expect(scheduler.activeRetryTasks.count == 1)
    }

    @Test func successfulSubmissionResetsRetryDelay() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        let coordinator = makeCoordinator(clock: clock, scheduler: scheduler)
        let first = try #require(coordinator.beginFrame())
        coordinator.refuse(first, reason: .missingRenderEncoder)
        try #require(scheduler.activeRetryTasks.last).run()

        let second = try #require(coordinator.beginFrame())
        coordinator.didSubmit(second, status: { .scheduled }, error: { nil })
        coordinator.complete(second, status: .completed, error: nil)
        let third = try #require(coordinator.beginFrame())
        coordinator.refuse(third, reason: .missingDrawable)

        #expect(scheduler.activeRetryTasks.last?.delay == 0.016)
    }

    @Test func watchdogFinishesCompletedBufferOnceAndDrawsPendingFrame() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        var status = MetalTrackedCommandBufferStatus.scheduled
        var drawCount = 0
        let coordinator = makeCoordinator(
            clock: clock,
            scheduler: scheduler,
            draws: { _ in drawCount += 1 }
        )
        let token = try #require(coordinator.beginFrame())
        coordinator.didSubmit(token, status: { status }, error: { nil })
        #expect(coordinator.beginFrame() == nil)
        status = .completed
        clock.now = 1

        try #require(scheduler.activeWatchdogs.first).run()
        coordinator.complete(token, status: .completed, error: nil)

        #expect(coordinator.isIdle)
        #expect(drawCount == 1)
    }

    @Test func lateCompletionCannotReleaseNewerFrame() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        let coordinator = makeCoordinator(clock: clock, scheduler: scheduler)
        let oldToken = try #require(coordinator.beginFrame())
        coordinator.didSubmit(oldToken, status: { .completed }, error: { nil })
        coordinator.complete(oldToken, status: .completed, error: nil)
        let newToken = try #require(coordinator.beginFrame())

        coordinator.complete(oldToken, status: .completed, error: nil)

        #expect(!coordinator.isIdle)
        coordinator.refuse(newToken, reason: .missingDrawable)
    }

    @Test func nonterminalStallRequestsReplacementWithoutReleasingFrame() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        var reports: [MetalRendererRecoveryReport] = []
        let coordinator = makeCoordinator(
            clock: clock,
            scheduler: scheduler,
            recoveries: { reports.append($0) }
        )
        let token = try #require(coordinator.beginFrame())
        coordinator.didSubmit(token, status: { .scheduled }, error: { nil })
        clock.now = 1

        try #require(scheduler.activeWatchdogs.first).run()

        #expect(reports.count == 1)
        #expect(reports.first?.commandBufferStatus == .scheduled)
        #expect(!coordinator.isIdle)
    }

    @Test func submittedFrameDefersWatchdogUntilViewIsDrawable() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        var eligible = true
        var reports: [MetalRendererRecoveryReport] = []
        let coordinator = makeCoordinator(
            clock: clock,
            scheduler: scheduler,
            eligible: { eligible },
            recoveries: { reports.append($0) }
        )
        let token = try #require(coordinator.beginFrame())
        coordinator.didSubmit(token, status: { .scheduled }, error: { nil })
        eligible = false
        clock.now = 1

        try #require(scheduler.activeWatchdogs.first).run()

        #expect(reports.isEmpty)
        #expect(!coordinator.isIdle)
        #expect(scheduler.activeWatchdogs.isEmpty)

        eligible = true
        #expect(coordinator.beginFrame() == nil)
        #expect(scheduler.activeWatchdogs.count == 1)
        clock.now = 2
        try #require(scheduler.activeWatchdogs.first).run()

        #expect(reports.count == 1)
        #expect(reports.first?.commandBufferStatus == .scheduled)
    }

    @Test func visibleEarlyFailuresRequestReplacementAfterOneSecond() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        var reports: [MetalRendererRecoveryReport] = []
        let coordinator = makeCoordinator(
            clock: clock,
            scheduler: scheduler,
            recoveries: { reports.append($0) }
        )
        let token = try #require(coordinator.beginFrame())
        coordinator.refuse(token, reason: .missingRenderEncoder)
        clock.now = 0.5
        let secondToken = try #require(coordinator.beginFrame())
        coordinator.refuse(secondToken, reason: .missingRenderEncoder)
        clock.now = 1

        try #require(scheduler.activeWatchdogs.first).run()

        #expect(reports.count == 1)
        #expect(reports.first?.reason == .missingRenderEncoder)
    }

#if DEBUG
    @Test func frameGateWithoutValidOwnerRequestsReplacement() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        var reports: [MetalRendererRecoveryReport] = []
        let coordinator = makeCoordinator(
            clock: clock,
            scheduler: scheduler,
            recoveries: { reports.append($0) }
        )
        coordinator.injectHeldFrameForTesting()
        clock.now = 1

        try #require(scheduler.activeWatchdogs.first).run()

        #expect(reports.count == 1)
        #expect(reports.first?.commandBufferStatus == nil)
        #expect(!coordinator.isIdle)
    }
#endif

    @Test func hiddenViewDoesNotRunRetryLoopOrRecover() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        var eligible = false
        var drawCount = 0
        var reports: [MetalRendererRecoveryReport] = []
        let coordinator = makeCoordinator(
            clock: clock,
            scheduler: scheduler,
            eligible: { eligible },
            draws: { _ in drawCount += 1 },
            recoveries: { reports.append($0) }
        )
        let token = try #require(coordinator.beginFrame())
        coordinator.refuse(token, reason: .missingDrawable)
        clock.now = 1

        #expect(scheduler.activeRetryTasks.isEmpty)
        #expect(scheduler.activeWatchdogs.isEmpty)
        #expect(drawCount == 0)
        #expect(reports.isEmpty)

        eligible = true
        let resumed = try #require(coordinator.beginFrame())
        coordinator.refuse(resumed, reason: .missingDrawable)
        #expect(scheduler.activeRetryTasks.map(\.delay) == [0.016])
    }

    @Test func detachedViewDoesNotScheduleRetry() throws {
        let clock = TestMetalRecoveryClock()
        let scheduler = TestMetalRecoveryScheduler()
        let coordinator = makeCoordinator(
            clock: clock,
            scheduler: scheduler,
            eligible: { false }
        )
        let token = try #require(coordinator.beginFrame())

        coordinator.refuse(token, reason: .missingRenderPassDescriptor)

        #expect(scheduler.activeRetryTasks.isEmpty)
    }

    @Test func secondStallWithinThirtySecondsFallsBack() {
        var policy = MetalAutomaticRecoveryPolicy()

        #expect(policy.action(at: 10) == .replaceMetal)
        #expect(policy.action(at: 39.999) == .fallBackToCoreGraphics)
    }

    @Test func stallAfterThirtySecondsPermitsReplacement() {
        var policy = MetalAutomaticRecoveryPolicy()

        #expect(policy.action(at: 10) == .replaceMetal)
        #expect(policy.action(at: 40) == .replaceMetal)
    }
}
#endif
