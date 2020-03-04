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

public class TerminalOptions {
    public var cols: Int = 80
    public var rows: Int = 25
    public var convertEol: Bool = true
    public var cursorBlink: Bool = false
    public var termName: String = "xterm"
    public var cursorStyle = CursorStyle.blinkBlock
    public var screenReaderMode: Bool = false
    public var scrollback: Int? = 1000
    public var tabStopWidth: Int? = 8
}
