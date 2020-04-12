//
//  TerminalOptions.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 2/29/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

public enum CursorStyle {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkingBar
    case steadyBar
}

public struct TerminalOptions {
    public var cols: Int
    public var rows: Int
    public var convertEol: Bool
    public var cursorBlink: Bool
    public var termName: String
    public var cursorStyle: CursorStyle
    public var screenReaderMode: Bool
    public var scrollback: Int
    public var tabStopWidth: Int

    public init(cols: Int = 80, rows: Int = 25, convertEol: Bool = true, cursorBlink: Bool = false, termName: String = "xterm", cursorStyle: CursorStyle = CursorStyle.blinkBlock, screenReaderMode: Bool = false, scrollback: Int = 500, tabStopWidth: Int = 8) {
        self.cols = cols
        self.rows = rows
        self.convertEol = convertEol
        self.cursorBlink = cursorBlink
        self.termName = termName
        self.cursorStyle = cursorStyle
        self.screenReaderMode = screenReaderMode
        self.scrollback = scrollback
        self.tabStopWidth = tabStopWidth
    }
}
