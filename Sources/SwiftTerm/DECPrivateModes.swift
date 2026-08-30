enum DECModeReportState: Int, Sendable {
    case notRecognized = 0
    case set = 1
    case reset = 2
    case permanentlySet = 3
    case permanentlyReset = 4
}

enum SpecialDECPrivateMode: Int, CaseIterable, Sendable {
    case bracketedPaste = 2004
    case synchronizedOutput = 2026
    case colorSchemeReports = 2031
    case visibilityReports = 2033
    case inBandSizeReports = 2048
    case kittyPasteEvents = 5522
}

/// The visibility state that a host reports to terminal applications.
public enum TerminalVisibility: Int, Sendable {
    case potentiallyVisible = 1
    case notVisible = 2
}

/// One complete committed terminal layout in device pixels.
public struct TerminalPixelGeometry: Sendable, Equatable {
    public var rows: Int
    public var columns: Int
    public var cellWidth: Int
    public var cellHeight: Int

    public init(rows: Int, columns: Int, cellWidth: Int, cellHeight: Int) {
        self.rows = rows
        self.columns = columns
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }
}
