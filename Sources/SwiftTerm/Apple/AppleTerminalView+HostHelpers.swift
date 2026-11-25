//
//  AppleTerminalView+HostHelpers.swift
//
// Host-facing helpers historically carried on the holzschu/SwiftTerm v1.x pin
// for a-Shell. Kept here so Apps/a-Shell can consume this package without a
// nested SwiftTerm checkout.
//
#if !SWIFTTERM_EMBEDDED
#if os(iOS) || os(visionOS)
import Foundation

extension TerminalView {
    /// Returns the underlying terminal emulator for this view.
    public func getTerminal() -> Terminal {
        terminal
    }

    public var isCurrentBufferAlternate: Bool {
        withTerminal { $0.isCurrentBufferAlternate }
    }

    public func getLastLine() -> String {
        withTerminal { terminal in
            if promptline < 0 {
                return ""
            }
            if promptline >= terminal.buffer.lines.count {
                return ""
            }
            var result = ""
            for r in promptline..<terminal.buffer.lines.count {
                let line = terminal.buffer.lines[r]
                if line[0].code == 0 {
                    break
                }
                var start = 0
                if r == promptline {
                    start = promptcolumn
                }
                for i in start..<line.count {
                    if line[i].code == 0 {
                        if i > 0 && line[i - 1].width > 1 {
                            continue
                        } else {
                            break
                        }
                    }
                    result.append(line[i].getCharacter())
                }
            }
            return result
        }
    }

    public func getLastPrompt() -> String {
        withTerminal { terminal in
            if promptline < 0 {
                return ""
            }
            if promptline >= terminal.buffer.lines.count {
                return ""
            }
            var result = ""
            var r = promptline
            while r >= 0 && result.count < 50 {
                let line = terminal.buffer.lines[r]
                var end = line.count - 1
                if r == promptline {
                    end = promptcolumn - 1
                }
                r -= 1
                if end < 0 {
                    continue
                }
                for i in (0...end).reversed() {
                    if line[i].code == 0 {
                        if i > 0 && line[i - 1].code == 0 {
                            return result
                        } else {
                            continue
                        }
                    }
                    result = String(line[i].getCharacter()) + result
                }
            }
            return result
        }
    }

    public func setPromptEnd() {
        guard caretView != nil else { return }
        updateCursorPosition()
        withTerminal { terminal in
            promptline = terminal.buffer.linesTop + terminal.buffer.yBase + terminal.buffer.y
            promptcolumn = terminal.buffer.x
        }
    }

    public func getNewContent() -> String {
        withTerminal { terminal in
            let start = Position(
                col: savedCursorColumn,
                row: savedCursorLine + (savedCursorLinesTop - terminal.buffer.linesTop))
            let lastLine = terminal.buffer.lines.count - 1
            let end = Position(
                col: terminal.buffer.lines[lastLine].count,
                row: lastLine)
            return terminal.getText(start: start, end: end)
        }
    }

    public func saveCursorPosition() {
        withTerminal { terminal in
            savedCursorLinesTop = terminal.buffer.linesTop
            savedCursorLine = terminal.buffer.yBase + terminal.buffer.y
            savedCursorColumn = terminal.buffer.x
        }
    }

    public func restoreCursorPosition() {
        withTerminal { terminal in
            terminal.buffer.x = savedCursorColumn
            terminal.buffer.y = savedCursorLine - terminal.buffer.yBase
        }
    }

    /// Sets the cursor position to `(x, y)` and returns distance from the prompt end.
    public func setCursorPosition(x: Int, y: Int) -> Int? {
        enum CursorSetResult {
            case rejected
            case moved(Int)
        }
        let result: CursorSetResult = withTerminal { terminal in
            var lastUsedLine = 0
            if terminal.buffer.lines.count == terminal.rows {
                for i in (0..<terminal.buffer.lines.count).reversed() {
                    let line = terminal.buffer.lines[i]
                    if line[0].code != 0 {
                        lastUsedLine = i
                        break
                    }
                }
            } else {
                lastUsedLine = terminal.buffer.lines.count
            }

            if y + terminal.buffer.linesTop + terminal.buffer.yBase < promptline {
                return .rejected
            }

            if y + terminal.buffer.yBase >= lastUsedLine {
                terminal.buffer.y = lastUsedLine
            } else {
                terminal.buffer.y = y
            }
            if terminal.buffer.y <= promptline && x < promptcolumn {
                terminal.buffer.y = promptline
                terminal.buffer.x = promptcolumn
            } else {
                terminal.buffer.x = x
            }
            let distance = (x - promptcolumn)
                + (y + terminal.buffer.linesTop + terminal.buffer.yBase - promptline)
                * terminal.buffer.lines[promptline].count
            return .moved(distance)
        }
        switch result {
        case .rejected:
            return nil
        case .moved(let distance):
            updateCursorPosition()
            return distance
        }
    }

    public func getCurrentChar() -> String {
        withTerminal { terminal in
            let currentLine = terminal.buffer.yBase + terminal.buffer.y
            if terminal.buffer.x > 1 && terminal.buffer.lines[currentLine][terminal.buffer.x - 1].code == 0 {
                return String(terminal.buffer.lines[currentLine][terminal.buffer.x - 2].getCharacter())
            }
            if terminal.buffer.x == 0 {
                return ""
            }
            return String(terminal.buffer.lines[currentLine][terminal.buffer.x - 1].getCharacter())
        }
    }

    public func moveUpIfNeeded() {
        withTerminal { terminal in
            let currentLine = terminal.buffer.linesTop + terminal.buffer.yBase + terminal.buffer.y
            if currentLine <= promptline {
                return
            }
            if terminal.buffer.x == 0 {
                terminal.buffer.y -= 1
                terminal.buffer.x = terminal.buffer.lines[currentLine].count
            }
        }
    }

    public func moveDownIfNeeded() {
        withTerminal { terminal in
            let currentLine = terminal.buffer.yBase + terminal.buffer.y
            if currentLine >= terminal.buffer.lines.count {
                return
            }
            if terminal.buffer.x == terminal.buffer.lines[currentLine].count - 1 {
                terminal.buffer.y += 1
                terminal.buffer.x = 0
            }
        }
    }

    public func atTheEndOfTheLine() -> Bool {
        withTerminal { terminal in
            let currentLine = terminal.buffer.yBase + terminal.buffer.y
            let line = terminal.buffer.lines[currentLine]
            return terminal.buffer.x == 0 && line[line.count - 1].code != 0
        }
    }

    public func moveToBeginningOfLine() {
        withTerminal { terminal in
            terminal.buffer.x = promptcolumn
            terminal.buffer.y = promptline - terminal.buffer.yBase - terminal.buffer.linesTop
        }
    }

    public func moveToEndOfLine() {
        withTerminal { terminal in
            var lastUsedLine = 0
            if terminal.buffer.lines.count == terminal.rows {
                for i in (0..<terminal.buffer.lines.count).reversed() {
                    let line = terminal.buffer.lines[i]
                    if line[0].code != 0 {
                        lastUsedLine = i
                        break
                    }
                }
            } else {
                lastUsedLine = terminal.buffer.lines.count - 1
            }
            let lastLine = terminal.buffer.lines[lastUsedLine]
            terminal.buffer.y = lastUsedLine - terminal.buffer.yBase
            for i in 0..<lastLine.count {
                if lastLine[i].code == 0 {
                    if i > 0 && lastLine[i - 1].width > 1 {
                        continue
                    } else {
                        terminal.buffer.x = i
                        return
                    }
                }
            }
            terminal.buffer.x = lastLine.count - 1
        }
    }

    public func clearToEndOfLine() {
        withTerminal { terminal in
            let currentLine = terminal.buffer.yBase + terminal.buffer.y
            let line = terminal.buffer.lines[currentLine]
            if terminal.buffer.x < line.count {
                for x in terminal.buffer.x..<line.count {
                    line[x] = CharData.Null
                }
            }
            if terminal.buffer.yBase + terminal.buffer.y + 1 <= terminal.buffer.lines.count {
                for l in terminal.buffer.yBase + terminal.buffer.y + 1..<terminal.buffer.lines.count {
                    let clearLine = terminal.buffer.lines[l]
                    for x in 0..<clearLine.count {
                        clearLine[x] = CharData.Null
                    }
                }
            }
        }
    }

    public func wipeContents() {
        withTerminal { terminal in
            terminal.buffer.x = 0
            terminal.buffer.y = 0
            for l in 0..<terminal.buffer.lines.count {
                let line = terminal.buffer.lines[l]
                for c in 0..<line.count {
                    line[c] = CharData.Null
                }
            }
        }
    }

    public func setCursorStyle(shape: String) {
        withTerminal { terminal in
            switch shape {
            case "block":
                terminal.setCursorStyle(.steadyBlock)
            case "bar", "beam":
                terminal.setCursorStyle(.steadyBar)
            case "underline":
                terminal.setCursorStyle(.steadyUnderline)
            case "blinking-block":
                terminal.setCursorStyle(.blinkBlock)
            case "blinking-bar", "blinking-beam":
                terminal.setCursorStyle(.blinkBar)
            case "blinking-underline":
                terminal.setCursorStyle(.blinkUnderline)
            default:
                terminal.setCursorStyle(.steadyUnderline)
            }
        }
    }

    /// Moves the caret to the end of the current selection, then clears selection.
    public func moveToEndOfSelection() {
        withTerminal { terminal in
            let myPoint = Position(
                col: min(max(0, selection.end.col), terminal.cols - 1),
                row: selection.end.row)
            if let grid = myPoint.toScreenCoordinate(from: terminal.displayBuffer) {
                terminal.sendEvent(
                    buttonFlags: encodeFlags(release: false),
                    x: grid.col, y: grid.row, pixelX: 0, pixelY: 0)
            }
            selection.selectNone()
        }
        disableSelectionPanGesture()
    }

    /// Moves the caret to the start of the current selection, then clears selection.
    public func moveToBeginningOfSelection() {
        withTerminal { terminal in
            let myPoint = Position(
                col: min(max(0, selection.start.col), terminal.cols - 1),
                row: selection.start.row)
            if let grid = myPoint.toScreenCoordinate(from: terminal.displayBuffer) {
                terminal.sendEvent(
                    buttonFlags: encodeFlags(release: false),
                    x: grid.col, y: grid.row, pixelX: 0, pixelY: 0)
            }
            selection.selectNone()
        }
        disableSelectionPanGesture()
    }

    /// Deletes selected text on/after the prompt without copying (cut without clipboard).
    public func deleteSelection() {
        let text: String? = withTerminal { _ in
            guard selection.end.row >= promptline else { return nil }
            return selection.getSelectedText()
        }
        guard let text else { return }
        moveToEndOfSelection()
        let backspace: UInt8 = backspaceSendsControlH ? 8 : 0x7f
        for _ in 0..<text.count {
            send([backspace])
        }
    }
}
#endif
#endif
