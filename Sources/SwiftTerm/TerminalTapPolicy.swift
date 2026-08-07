//
//  TerminalTapPolicy.swift
//  SwiftTerm
//
//  Pure, platform-independent routing for tap gestures over the terminal grid. The iOS gesture
//  handlers only run on a device or simulator, so keeping the decision here lets the behaviour be
//  covered by the macOS/Linux test suite without standing up a UIKit gesture pipeline.
//

import Foundation

/// The action a tap over the terminal grid resolves to.
enum TerminalTapAction: Equatable {
    /// Double tap: select the word (or balanced expression) under the tap.
    case selectWord
    /// Triple tap: select the whole line under the tap.
    case selectLine
    /// Single tap that clears an existing selection (and re-enables scroll forwarding).
    case dismissSelection
    /// Single tap forwarded to the application as a mouse click (mouse reporting is on).
    case forwardClick
    /// Single tap with no selection and no mouse reporting: handled locally (e.g. cursor menu).
    case localSingleTap
}

enum TerminalTapPolicy {
    /// Resolves a tap to an action.
    ///
    /// Previously every tap was forwarded to the application whenever it had mouse reporting on,
    /// so a word or line could never be selected inside a full-screen app (vim, htop, a TUI) and
    /// an existing selection could not be cleared by tapping. This policy lets a double or triple
    /// tap select locally regardless of mouse reporting, and lets a single tap dismiss a live
    /// selection before any click is forwarded. A single tap with nothing selected still forwards
    /// the click, so interaction with mouse-reporting applications stays intact.
    ///
    /// - Parameters:
    ///   - tapCount: number of taps in the gesture (1, 2 or 3).
    ///   - hasActiveSelection: whether a text selection is currently live.
    ///   - mouseReportingActive: the application is capturing the mouse (reporting is on and the
    ///     gesture is not bypassing it, for example via a hardware shift key).
    static func action(tapCount: Int, hasActiveSelection: Bool, mouseReportingActive: Bool) -> TerminalTapAction {
        switch tapCount {
        case 3:
            return .selectLine
        case 2:
            return .selectWord
        default:
            if hasActiveSelection {
                return .dismissSelection
            }
            return mouseReportingActive ? .forwardClick : .localSingleTap
        }
    }
}
