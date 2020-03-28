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
 * Control codes - this structure provides variables that will return strings that are either the 7-bit version of the sequence or the 8-bit one
 * See = https://en.wikipedia.org/wiki/C0_and_C1_control_codes
 */
struct CC {
    var send8bit: Bool
    
    var PAD: String { get { send8bit ? "\u{80}" : "\u{1b}@" } }
    var HOP: String { get { send8bit ? "\u{81}" : "\u{1b}A" } }
    var BPH: String { get { send8bit ? "\u{82}" : "\u{1b}B" } }
    var NBH: String { get { send8bit ? "\u{83}" : "\u{1b}C" } }
    var IND: String { get { send8bit ? "\u{84}" : "\u{1b}D" } }
    var NEL: String { get { send8bit ? "\u{85}" : "\u{1b}E" } }
    var SSA: String { get { send8bit ? "\u{86}" : "\u{1b}F" } }
    var ESA: String { get { send8bit ? "\u{87}" : "\u{1b}G" } }
    var HTS: String { get { send8bit ? "\u{88}" : "\u{1b}H" } }
    var HTJ: String { get { send8bit ? "\u{89}" : "\u{1b}I" } }
    var VTS: String { get { send8bit ? "\u{8a}" : "\u{1b}J" } }
    var PLD: String { get { send8bit ? "\u{8b}" : "\u{1b}K" } }
    var PLU: String { get { send8bit ? "\u{8c}" : "\u{1b}L" } }
    var RI: String  { get { send8bit ? "\u{8d}" : "\u{1b}M" } }
    var SS2: String { get { send8bit ? "\u{8e}" : "\u{1b}N" } }
    var SS3: String { get { send8bit ? "\u{8f}" : "\u{1b}O" } }
    var DCS: String { get { send8bit ? "\u{90}" : "\u{1b}P" } }
    var PU1: String { get { send8bit ? "\u{91}" : "\u{1b}Q" } }
    var PU2: String { get { send8bit ? "\u{92}" : "\u{1b}R" } }
    var STS: String { get { send8bit ? "\u{93}" : "\u{1b}S" } }
    var CCH: String { get { send8bit ? "\u{94}" : "\u{1b}T" } }
    var MW: String  { get { send8bit ? "\u{95}" : "\u{1b}U" } }
    var SPA: String { get { send8bit ? "\u{96}" : "\u{1b}V" } }
    var EPA: String { get { send8bit ? "\u{97}" : "\u{1b}W" } }
    var SOS: String { get { send8bit ? "\u{98}" : "\u{1b}X" } }
    var SGCI: String{ get { send8bit ? "\u{99}" : "\u{1b}Y" } }
    var SCI: String { get { send8bit ? "\u{9a}" : "\u{1b}Z" } }
    var CSI: String { get { send8bit ? "\u{9b}" : "\u{1b}[" } }
    var ST: String  { get { send8bit ? "\u{9c}" : "\u{1b}\\" } }
    var OSC: String { get { send8bit ? "\u{9d}" : "\u{1b}]" } }
    var PM: String  { get { send8bit ? "\u{9e}" : "\u{1b}^" } }
    var APC: String { get { send8bit ? "\u{9f}" : "\u{1b}_" } }
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
