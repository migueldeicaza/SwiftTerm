//
//  EscapeSequences.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/30/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

struct ControlCodes  {
    static let NUL : UInt8 = 0x00
    static let BEL : UInt8 = 0x07
    static let BS  : UInt8 = 0x08
    static let HT  : UInt8 = 0x09
    static let LF  : UInt8 = 0x0a
    static let VT  : UInt8 = 0x0b
    static let FF  : UInt8 = 0x0c
    static let CR  : UInt8 = 0x0d
    static let SO  : UInt8 = 0x0e
    static let SI  : UInt8 = 0x0f
    static let CAN : UInt8 = 0x18
    static let SUB : UInt8 = 0x1a
    static let ESC : UInt8 = 0x1b
    static let SP  : UInt8 = 0x20
    static let DEL : UInt8 = 0x7f
}
