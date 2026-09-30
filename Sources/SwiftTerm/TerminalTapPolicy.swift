//
//  TerminalTapPolicy.swift
//  SwiftTerm
//
//  Pure, platform-independent routing for tap gestures over the terminal grid. The iOS gesture
//  handlers only run on a device or simulator, so keeping the decision here lets the behaviour be
//  covered by the macOS/Linux test suite without standing up a UIKit gesture pipeline.
//

#if !SWIFTTERM_EMBEDDED
import Foundation

/// The action a tap over the terminal grid resolves to.
enum TerminalTapAction: Equatable {
    /// Double tap: select the word (or balanced expression) under the tap.
    case selectWord
    /// Triple tap: select the whole line under the tap.
    case selectLine
    /// Single tap that clears a selection while an application owns mouse input.
    case dismissSelection
    /// Single tap forwarded to the application as a mouse click (mouse reporting is on).
    case forwardClick
    /// Single tap with no mouse reporting: handled locally (e.g. cursor menu).
    case localSingleTap
}

enum TerminalTapPolicy {
    /// A tap that clears a selection does not also open the cursor menu.
    static func showsContextMenu(nearCursor: Bool, clearedSelection: Bool) -> Bool {
        nearCursor && !clearedSelection
    }

    /// Resolves a tap to an action.
    ///
    /// Double and triple taps select text. With no application mouse reporting,
    /// a single tap clears an old selection and can route to a prompt. A tap
    /// clears an old selection when application mouse reporting is active.
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
            if hasActiveSelection && mouseReportingActive {
                return .dismissSelection
            }
            return mouseReportingActive ? .forwardClick : .localSingleTap
        }
    }
}

#endif // !SWIFTTERM_EMBEDDED
