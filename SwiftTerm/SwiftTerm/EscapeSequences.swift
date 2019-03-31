//
//  EscapeSequences.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/30/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

struct ControlCodes : UInt8 {
    static let NUL = 0x00
    static let BEL = 0x07
    static let BS  = 0x08
    static let HT  = 0x09
    static let LF  = 0x0a
    static let VT  = 0x0b
    static let FF  = 0x0c
    static let CR  = 0x0d
    static let SO  = 0x0e
    static let SI  = 0x0f
    static let CAN = 0x18
    static let SUB = 0x1a
    static let ESC = 0x1b
    static let SP  = 0x20
    static let DEL = 0x7f
}
