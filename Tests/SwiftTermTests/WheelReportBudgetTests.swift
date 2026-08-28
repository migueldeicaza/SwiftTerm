#if canImport(AppKit) || canImport(UIKit)
import Testing

@testable import SwiftTerm

@Suite struct WheelReportBudgetTests {
    @Test func classicWheelUsesOneReportAndPreciseInputUsesTheBurstLimit() {
        #expect(WheelReportBudget.requestedReports(lineCount: 0, isPrecise: false) == 0)
        #expect(WheelReportBudget.requestedReports(lineCount: 40, isPrecise: false) == 1)
        #expect(WheelReportBudget.requestedReports(lineCount: -40, isPrecise: false) == 1)
        #expect(WheelReportBudget.requestedReports(lineCount: 4, isPrecise: true) == 4)
        #expect(WheelReportBudget.requestedReports(lineCount: -40, isPrecise: true) == 6)
    }

    @Test func tokenBucketAllowsABurstThenRefillsAtTheConfiguredRate() {
        let start: UInt64 = 1_000_000_000
        var budget = WheelReportBudget(nowNanoseconds: start)

        #expect(budget.grant(20, nowNanoseconds: start) == 6)
        #expect(budget.grant(1, nowNanoseconds: start) == 0)
        #expect(budget.grant(20, nowNanoseconds: start + 50_000_000) == 5)
        #expect(budget.grant(20, nowNanoseconds: start + 60_000_000) == 1)
        #expect(budget.grant(20, nowNanoseconds: start + 10_000_000_000) == 6)
    }

    @Test func tokenBucketDoesNotRefillWhenTheSuppliedClockMovesBackward() {
        let start: UInt64 = 2_000_000_000
        var budget = WheelReportBudget(nowNanoseconds: start)
        #expect(budget.grant(6, nowNanoseconds: start) == 6)

        #expect(budget.grant(1, nowNanoseconds: start - 1) == 0)
        #expect(budget.grant(1, nowNanoseconds: start + 9_999_999) == 0)
        #expect(budget.grant(1, nowNanoseconds: start + 10_000_000) == 1)
    }
}

@Suite struct WheelDragDistanceAccumulatorTests {
    @Test func fractionalDistanceDoesNotCrossAGestureBoundary() {
        var accumulator = WheelDragDistanceAccumulator()

        accumulator.reset()
        #expect(accumulator.takeWholeLines(distance: 15, cellHeight: 20) == 0)

        accumulator.reset()
        #expect(accumulator.takeWholeLines(distance: 5, cellHeight: 20) == 0)
        #expect(accumulator.takeWholeLines(distance: 15, cellHeight: 20) == 1)
    }
}

@Suite struct ProgramScrollRoutingTests {
    @Test func reportingGateOwnsEveryProgramRoute() {
        #expect(ProgramScrollRouting.route(
            allowMouseReporting: false,
            shiftBypassesMouseReporting: false,
            mouseTracking: true,
            alternateBuffer: true,
            alternateScrollMode: true) == .none)
        #expect(!ProgramScrollRouting.capturesGesture(
            allowMouseReporting: false,
            mouseTracking: true,
            alternateBuffer: true))
    }

    @Test func mouseTrackingWinsUnlessShiftBypassesIt() {
        #expect(ProgramScrollRouting.route(
            allowMouseReporting: true,
            shiftBypassesMouseReporting: false,
            mouseTracking: true,
            alternateBuffer: false,
            alternateScrollMode: true) == .mouse)
        #expect(ProgramScrollRouting.route(
            allowMouseReporting: true,
            shiftBypassesMouseReporting: true,
            mouseTracking: true,
            alternateBuffer: false,
            alternateScrollMode: true) == .none)
        #expect(ProgramScrollRouting.route(
            allowMouseReporting: true,
            shiftBypassesMouseReporting: true,
            mouseTracking: true,
            alternateBuffer: true,
            alternateScrollMode: true) == .none)
    }

    @Test func alternateScrollUsesCursorKeysButAlwaysCapturesTheEmptyBuffer() {
        #expect(ProgramScrollRouting.route(
            allowMouseReporting: true,
            shiftBypassesMouseReporting: false,
            mouseTracking: false,
            alternateBuffer: true,
            alternateScrollMode: true) == .cursorKeys)
        #expect(ProgramScrollRouting.route(
            allowMouseReporting: true,
            shiftBypassesMouseReporting: false,
            mouseTracking: false,
            alternateBuffer: true,
            alternateScrollMode: false) == .none)
        #expect(ProgramScrollRouting.capturesGesture(
            allowMouseReporting: true,
            mouseTracking: false,
            alternateBuffer: true))
    }
}
#endif
