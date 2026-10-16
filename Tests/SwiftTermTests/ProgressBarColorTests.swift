//
//  ProgressBarColorTests.swift
//  SwiftTermTests
//
//  A host that themes the terminal tints the OSC 9;4 progress bar, but the
//  error and paused states have to keep their system colors to stay readable.
//
#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
struct ProgressBarColorTests {

    private func makeBar() -> TerminalProgressBarView {
        TerminalProgressBarView(frame: CGRect(x: 0, y: 0, width: 200, height: 3))
    }

    @Test func untintedBarUsesTheAccentColor() {
        let bar = makeBar()

        #expect(bar.color(for: .set) == .controlAccentColor)
        #expect(bar.color(for: .indeterminate) == .controlAccentColor)
    }

    @Test func tintColorsTheRunningStatesOnly() {
        let bar = makeBar()
        bar.tint = .systemPurple

        #expect(bar.color(for: .set) == .systemPurple)
        #expect(bar.color(for: .indeterminate) == .systemPurple)
        #expect(bar.color(for: .error) == .systemRed)
        #expect(bar.color(for: .pause) == .systemOrange)
    }

    @Test func clearingTheTintRestoresTheAccentColor() {
        let bar = makeBar()
        bar.tint = .systemPurple
        bar.tint = nil

        #expect(bar.color(for: .set) == .controlAccentColor)
    }

    /// A bar that is already on screen takes the new color without waiting for
    /// the next report.
    @Test func tintRecolorsARunningBar() {
        let bar = makeBar()
        bar.apply(state: .set, progress: 40)
        bar.tint = .systemPurple

        #expect(bar.barColor == NSColor.systemPurple.cgColor)
    }

    @Test func viewExposesTheProgressBarColor() {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: nil,
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 100))

        #expect(view.progressBarColor == nil)
        view.progressBarColor = .systemPurple
        #expect(view.progressBarColor == .systemPurple)
        view.progressBarColor = nil
        #expect(view.progressBarColor == nil)
    }
}
#endif
