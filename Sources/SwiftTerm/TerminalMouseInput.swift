/// The action of a pointer event submitted by a terminal host.
public enum TerminalMouseAction: UInt32, Sendable {
    case press = 0
    case release = 1
    case move = 2
    case wheel = 3
}

/// Protocol button identity. A release retains the button that was pressed.
public enum TerminalMouseButton: UInt32, Sendable {
    case left = 0
    case middle = 1
    case right = 2
    case none = 3
    case wheelUp = 4
    case wheelDown = 5
    case wheelLeft = 6
    case wheelRight = 7
}
