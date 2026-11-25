//
//  TerminalTapGestureRecognizer.swift
//
//  The single tap recognizer of the iOS and visionOS TerminalView. It records
//  the type of the touch, because a finger and a pointer activate links
//  differently.
//

#if !SWIFTTERM_EMBEDDED
#if os(iOS) || os(visionOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// How a touch on a link activates it. See ``TerminalView/touchLinkActivation``.
public enum TouchLinkActivation: Sendable {
    /// A tap on a link calls ``TerminalViewDelegate/requestOpenLink(source:request:)``.
    case tap
    /// A touch never activates a link. A tap on a link focuses the view or
    /// shows the menu, as a tap on other text does. Use
    /// ``TerminalView/linkRequest(at:)`` to find links for your own gesture or menu.
    case none
}

/// A tap recognizer that records the type of the last touch it received.
class TerminalTapGestureRecognizer: UITapGestureRecognizer {
    /// The type of the touch of the current tap, or nil before the first touch.
    var touchType: UITouch.TouchType?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touchType = touches.first?.type
        super.touchesBegan(touches, with: event)
    }
}
#endif
#endif // !SWIFTTERM_EMBEDDED
