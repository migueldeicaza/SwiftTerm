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

/**
* C1 control codes
* See = https://en.wikipedia.org/wiki/C0_and_C1_control_codes
*/
struct C1 {
    static let PAD : UInt8 = 0x80
    static let HOP : UInt8 = 0x81
    static let BPH : UInt8 = 0x82
    static let NBH : UInt8 = 0x83
    static let IND : UInt8 = 0x84
    static let NEL : UInt8 = 0x85
    static let SSA : UInt8 = 0x86
    static let ESA : UInt8 = 0x87
    static let HTS : UInt8 = 0x88
    static let HTJ : UInt8 = 0x89
    static let VTS : UInt8 = 0x8a
    static let PLD : UInt8 = 0x8b
    static let PLU : UInt8 = 0x8c
    static let RI : UInt8 = 0x8d
    static let SS2 : UInt8 = 0x8e
    static let SS3 : UInt8 = 0x8f
    static let DCS : UInt8 = 0x90
    static let PU1 : UInt8 = 0x91
    static let PU2 : UInt8 = 0x92
    static let STS : UInt8 = 0x93
    static let CCH : UInt8 = 0x94
    static let MW : UInt8 = 0x95
    static let SPA : UInt8 = 0x96
    static let EPA : UInt8 = 0x97
    static let SOS : UInt8 = 0x98
    static let SGCI : UInt8 = 0x99
    static let SCI : UInt8 = 0x9a
    static let CSI : UInt8 = 0x9b
    static let ST : UInt8 = 0x9c
    static let OSC : UInt8 = 0x9d
    static let PM : UInt8 = 0x9e
    static let APC : UInt8 = 0x9f
}

public struct EscapeSequences {
    public static let CmdNewline: [UInt8] = [ 10 ]
    public static let CmdRet: [UInt8] = [ 13 ]
    public static let CmdEsc: [UInt8] = [ 0x1b ]
    public static let CmdDel: [UInt8] = [ 0x7f ]
    public static let CmdDelKey: [UInt8] = [ 0x1b, 0x5b, 0x33, 0x7e ]
    public static let MoveUpApp: [UInt8] = [ 0x1b, 0x4f, 0x41 ]
    public static let MoveUpNormal: [UInt8] = [ 0x1b, 0x5b, 0x41 ]
    public static let MoveDownApp: [UInt8] = [ 0x1b, 0x4f, 0x42 ]
    public static let MoveDownNormal: [UInt8] = [ 0x1b, 0x5b, 0x42 ]
    public static let MoveLeftApp: [UInt8] = [ 0x1b, 0x4f, 0x44 ]
    public static let MoveLeftNormal: [UInt8] = [ 0x1b, 0x5b, 0x44 ]
    public static let MoveRightApp: [UInt8] = [ 0x1b, 0x4f, 0x43 ]
    public static let MoveRightNormal: [UInt8] = [ 0x1b, 0x5b, 0x43 ]
    public static let MoveHomeApp: [UInt8] = [ 0x1b, 0x4f, 0x48 ]
    public static let MoveHomeNormal: [UInt8] = [ 0x1b, 0x5b, 0x48 ]
    public static let MoveEndApp: [UInt8] = [ 0x1b, 0x4f, 0x46 ]
    public static let MoveEndNormal: [UInt8] = [ 0x1b, 0x5b, 0x46 ]
    public static let CmdTab: [UInt8] = [ 9 ]
    public static let CmdBackTab: [UInt8] = [ 0x1b, 0x5b, 0x5a ]
    public static let CmdPageUp: [UInt8] = [ 0x1b, 0x5b, 0x35, 0x7e ]
    public static let CmdPageDown: [UInt8] = [ 0x1b, 0x5b, 0x36, 0x7e ]

    public static let CmdF: [[UInt8]] = [
         [ 0x1b, 0x4f, 0x50 ], /* F1 */
         [ 0x1b, 0x4f, 0x51 ], /* F2 */
         [ 0x1b, 0x4f, 0x52 ], /* F3 */
         [ 0x1b, 0x4f, 0x53 ], /* F4 */
         [ 0x1b, 0x5b, 0x31, 0x35, 0x7e ], /* F5 */
         [ 0x1b, 0x5b, 0x31, 0x37, 0x7e ], /* F6 */
         [ 0x1b, 0x5b, 0x31, 0x38, 0x7e ], /* F7 */
         [ 0x1b, 0x5b, 0x31, 0x39, 0x7e ], /* F8 */
         [ 0x1b, 0x5b, 0x32, 0x30, 0x7e ], /* F9 */
         [ 0x1b, 0x5b, 0x32, 0x31, 0x7e ], /* F10 */
         [ 0x1b, 0x5b, 0x32, 0x33, 0x7e ], /* F11 */
         [ 0x1b, 0x5b, 0x32, 0x34, 0x7e ], /* F12 */
    ]

}
