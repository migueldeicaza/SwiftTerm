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

    @Test func cursorKeysKeepTheirLineCountUpToTheBurst() {
        #expect(WheelReportBudget.requestedKeys(lineCount: 0) == 0)
        #expect(WheelReportBudget.requestedKeys(lineCount: 4) == 4)
        #expect(WheelReportBudget.requestedKeys(lineCount: -4) == 4)
        #expect(WheelReportBudget.requestedKeys(lineCount: 40) == 6)
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

    @Test func diagonalInputSharesTheBurstAndAlternatesWhenOnlyOneReportRefills() {
        let start: UInt64 = 1_000_000_000
        var budget = WheelReportBudget(nowNanoseconds: start)

        let burst = budget.grant(vertical: 6, horizontal: 1, preferHorizontal: false, nowNanoseconds: start)
        #expect(burst.vertical == 5)
        #expect(burst.horizontal == 1)
        #expect(budget.grant(1, nowNanoseconds: start) == 0)

        let first = budget.grant(vertical: 6, horizontal: 1, preferHorizontal: false, nowNanoseconds: start + 10_000_000)
        let second = budget.grant(vertical: 6, horizontal: 1, preferHorizontal: false, nowNanoseconds: start + 20_000_000)
        #expect(first.vertical == 1 && first.horizontal == 0)
        #expect(second.vertical == 0 && second.horizontal == 1)

        let horizontalBurst = budget.grant(vertical: 1, horizontal: 6, preferHorizontal: true,
                                           nowNanoseconds: start + 100_000_000)
        #expect(horizontalBurst.vertical == 1 && horizontalBurst.horizontal == 5)
    }
}

@Suite struct WheelDistanceAccumulatorTests {
    @Test func fractionalDistanceDoesNotCrossAGestureBoundary() {
        var accumulator = WheelDistanceAccumulator<ProgramScrollRoute>()

        accumulator.reset()
        #expect(accumulator.takeWholeLines(distance: 15, cellHeight: 20, route: .mouse) == 0)

        accumulator.reset()
        #expect(accumulator.takeWholeLines(distance: 5, cellHeight: 20, route: .mouse) == 0)
        #expect(accumulator.takeWholeLines(distance: 15, cellHeight: 20, route: .mouse) == 1)
    }

    /// Travel banked for one route is never spent by another, in either direction: a sub-cell
    /// mouse report and a sub-cell cursor key do not add up to a whole line.
    @Test func fractionalDistanceDoesNotCrossARouteBoundary() {
        var accumulator = WheelDistanceAccumulator<ProgramScrollRoute>()

        #expect(accumulator.takeWholeLines(distance: 15, cellHeight: 20, route: .mouse) == 0)
        #expect(accumulator.takeWholeLines(distance: 5, cellHeight: 20, route: .cursorKeys) == 0)
        #expect(accumulator.takeWholeLines(distance: 15, cellHeight: 20, route: .mouse) == 0)
        #expect(accumulator.takeWholeLines(distance: 5, cellHeight: 20, route: .mouse) == 1)
        #expect(accumulator.remainder == 0)
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
