//
//  EscapeSequenceParser.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/28/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//
// The state machien has been extended to allow ":" in the CSI Param state to initiate a new
// parameter value.   This is strictly not part of the spec, but necessary to parse the
// color scheme CSI [ 48:2:R:G:B m sequence which uses ":" instead of the more common ";"
//
// Alternative approaches:
//   * only allow ":" as a CsiParam if the first param is a 48/38.
//   * create an additiona "ignoredBuffer" that is passed to functions interested in those,
//     and this could be one of those.   Would be a little stricter, and probably better

import Foundation

enum ParserState : UInt8 {
    case ground = 0
    case escape
    case escapeIntermediate
    case csiEntry
    case csiParam
    case csiIntermediate
    case csiIgnore
    case sosPmApcString
    case oscString
    case apcString
    case dcsEntry
    case dcsParam
    case dcsIgnore
    case dcsIntermediate
    case dcsPassthrough
}

typealias cstring = [UInt8]

class ParsingState {
    var position: Int
    var code: UInt8
    var currentState: ParserState
    var print: Int
    var dcs: Int
    var osc: cstring
    var apc: cstring
    var collect: cstring
    var parameters: [Int32]
    var abort: Bool
    
    init ()
    {
        position = 0
        code = 0
        currentState = .ground
        print = 0
        dcs = 0
        osc = []
        apc = []
        collect = []
        parameters = []
        abort = false
    }
}

enum ParserAction : UInt8 {
    case ignore = 0
    case error
    case print
    case execute
    case oscStart
    case oscPut
    case oscEnd
    case csiDispatch
    case param
    case collect
    case escDispatch
    case clear
    case dcsHook
    case dcsPut
    case dcsUnhook
}

class TransitionTable {
    // data is packed like this:
    // currentState << 8 | characterCode  -->  action << 4 | nextState
    var table: [UInt8]
    
    init (len: Int)
    {
        table = Array.init (repeating: 0, count: len)
    }
    
    func add (code: UInt8, state: ParserState, action: ParserAction, next: ParserState)
    {
        let v = (UInt8 (action.rawValue) << 4) | next.rawValue
        table [(Int (state.rawValue) << 8) | Int(code)] = v
    }
    
    func add (codes: [UInt8], state: ParserState, action: ParserAction, next: ParserState)
    {
        for c in codes {
            add (code: c, state: state, action: action, next: next)
        }
    }
    
    subscript (idx: Int) -> UInt8 {
        get {
            return table [idx]
        }
    }
}

protocol  DcsHandler {
    func hook (collect: cstring, parameters: [Int],  flag: UInt8)
    func put (data : ArraySlice<UInt8>)
    func unhook ()
}

/// The engine that drives the parsing of the data stream for the terminal.
///
/// It is used by the ``Terminal`` to interpret the sequence of bytes coming, and
/// it is possible for users to hook up Operating System Command handlers (OSC -
/// they begin with the two byte sequence ESC and ]).   These are typically used
/// to implement custom communication channels.
///
public class EscapeSequenceParser {
    
    static func r (low: UInt8, high: UInt8) -> [UInt8]
    {
        let c = high-low
        var ret = [UInt8]()
        for x in 0..<c {
            ret.append(low + x)
        }
        return ret;
    }
    
    static func rinclusive (low: ParserState, high: ParserState)-> [ParserState]
    {
        let c = high.rawValue-low.rawValue
        var ret = [ParserState]()
        for x in 0...c {
            ret.append(ParserState (rawValue: low.rawValue + x)!)
        }
        return ret;
    }
    
    static let NonAsciiPrintable : UInt8 = 0xa0
    
    static func buildVt500TransitionTable () -> TransitionTable
    {
        let table = TransitionTable(len: 4095)
        let states = rinclusive(low: .ground, high: .dcsPassthrough)
        
        // table with default transition
        for state in states {
            for code in 0...NonAsciiPrintable {
                table.add(code: code, state: state, action: .error, next: .ground)
            }
        }
        
        // printables
        let printables = r (low: 0x20, high: 0x7f)
        let executables = r (low: 0x00, high: 0x19) + r (low: 0x1c, high: 0x20)
        table.add (codes: printables, state: .ground, action: .print, next: .ground)
        
        // global anywhere rules
        for state in states {
            table.add (codes: [0x18, 0x1a, 0x99, 0x9a], state: state, action: .execute, next: .ground)
            table.add (codes: r (low: 0x80, high: 0x90), state: state, action: .execute, next: .ground)
            table.add (codes: r (low: 0x90, high: 0x98), state: state, action: .execute, next: .ground)
            table.add (code: 0x9c, state: state, action: .ignore, next: .ground) // ST as terminator
            table.add (code: 0x1b, state: state, action: .clear, next: .escape)  // ESC
            table.add (code: 0x9d, state: state, action: .oscStart, next: .oscString)  // OSC
            table.add (codes: [0x98, 0x9e], state: state, action: .ignore, next: .sosPmApcString)
            table.add (code: 0x9f, state: state, action: .oscStart, next: .apcString)
            table.add (code: 0x9b, state: state, action: .clear, next: .csiEntry)  // CSI
            table.add (code: 0x90, state: state, action: .clear, next: .dcsEntry)  // DCS
        }
        // rules for executable and 0x7f
        table.add (codes: executables, state: .ground, action: .execute, next: .ground)
        table.add (codes: executables, state: .escape, action: .execute, next: .escape)
        table.add (code: 0x7f, state: .escape, action: .ignore, next: .escape)
        table.add (codes: executables, state: .oscString, action: .ignore, next: .oscString)
        table.add (codes: executables, state: .apcString, action: .ignore, next: .apcString)
        table.add (codes: executables, state: .csiEntry, action: .execute, next: .csiEntry)
        table.add (code: 0x7f, state: .csiEntry, action: .ignore, next: .csiEntry)
        table.add (codes: executables, state: .csiParam, action: .execute, next: .csiParam)
        table.add (code: 0x7f, state: .csiParam, action: .ignore, next: .csiParam)
        table.add (codes: executables, state: .csiIgnore, action: .execute, next: .csiIgnore)
        table.add (codes: executables, state: .csiIntermediate, action: .execute, next: .csiIntermediate)
        table.add (code: 0x7f, state: .csiIntermediate, action: .ignore, next: .csiIntermediate)
        table.add (codes: executables, state: .escapeIntermediate, action: .execute, next: .escapeIntermediate)
        table.add (code: 0x7f, state: .escapeIntermediate, action: .ignore, next: .escapeIntermediate)
        // osc
        table.add (code: 0x5d, state: .escape, action: .oscStart, next: .oscString)
        table.add (codes: printables, state: .oscString, action: .oscPut, next: .oscString)
        table.add (code: 0x7f, state: .oscString, action: .oscPut, next: .oscString)
        table.add (codes: [0x9c, 0x1b, 0x18, 0x1a, 0x07], state: .oscString, action: .oscEnd, next: .ground)
        table.add (codes: r (low: 0x1c, high: 0x20), state: .oscString, action: .ignore, next: .oscString)
        // apc
        table.add (code: 0x5f, state: .escape, action: .oscStart, next: .apcString)
        table.add (codes: printables, state: .apcString, action: .oscPut, next: .apcString)
        table.add (code: 0x7f, state: .apcString, action: .oscPut, next: .apcString)
        table.add (codes: [0x9c, 0x1b, 0x18, 0x1a, 0x07], state: .apcString, action: .oscEnd, next: .ground)
        table.add (codes: r (low: 0x1c, high: 0x20), state: .apcString, action: .ignore, next: .apcString)
        // sos/pm does nothing
        table.add (codes: [0x58, 0x5e], state: .escape, action: .ignore, next: .sosPmApcString)
        table.add (codes: printables, state: .sosPmApcString, action: .ignore, next: .sosPmApcString)
        table.add (codes: executables, state: .sosPmApcString, action: .ignore, next: .sosPmApcString)
        table.add (code: 0x9c, state: .sosPmApcString, action: .ignore, next: .ground)
        table.add (code: 0x7f, state: .sosPmApcString, action: .ignore, next: .sosPmApcString)
        // csi entries
        table.add (code: 0x5b, state: .escape, action: .clear, next: .csiEntry)
        table.add (codes: r (low: 0x40, high: 0x7f), state: .csiEntry, action: .csiDispatch, next: .ground)
        table.add (codes: r (low: 0x30, high: 0x3a), state: .csiEntry, action: .param, next: .csiParam)
        table.add (code: 0x3b, state: .csiEntry, action: .param, next: .csiParam)
        table.add (codes: [0x3c, 0x3d, 0x3e, 0x3f], state: .csiEntry, action: .collect, next: .csiParam)
        table.add (codes: r (low: 0x30, high: 0x3a), state: .csiParam, action: .param, next: .csiParam)
        table.add (code: 0x3b, state: .csiParam, action: .param, next: .csiParam)
        table.add (codes: r (low: 0x40, high: 0x7f), state: .csiParam, action: .csiDispatch, next: .ground)
        table.add (codes: [0x3c, 0x3d, 0x3e, 0x3f], state: .csiParam, action: .ignore, next: .csiIgnore)
        
        // csi for ":"
        table.add (code: 0x3a, state: .csiParam, action: .param, next: .csiParam)
        table.add (codes: r (low: 0x20, high: 0x40), state: .csiIgnore, action: .ignore, next: .csiIgnore)
        table.add (code: 0x7f, state: .csiIgnore, action: .ignore, next: .csiIgnore)
        table.add (codes: r (low: 0x40, high: 0x7f), state: .csiIgnore, action: .ignore, next: .ground)
        //table.Add (code: 0x3a, state: .CsiEntry, action: .Ignore, next: .CsiIgnore)
        table.add (codes: r (low: 0x20, high: 0x30), state: .csiEntry, action: .collect, next: .csiIntermediate)
        table.add (codes: r (low: 0x20, high: 0x30), state: .csiIntermediate, action: .collect, next: .csiIntermediate)
        table.add (codes: r (low: 0x30, high: 0x40), state: .csiIntermediate, action: .ignore, next: .csiIgnore)
        table.add (codes: r (low: 0x40, high: 0x7f), state: .csiIntermediate, action: .csiDispatch, next: .ground)
        table.add (codes: r (low: 0x20, high: 0x30), state: .csiParam, action: .collect, next: .csiIntermediate)
        // escIntermediate
        table.add (codes: r (low: 0x20, high: 0x30), state: .escape, action: .collect, next: .escapeIntermediate)
        table.add (codes: r (low: 0x20, high: 0x30), state: .escapeIntermediate, action: .collect, next: .escapeIntermediate)
        table.add (codes: r (low: 0x30, high: 0x7f), state: .escapeIntermediate, action: .escDispatch, next: .ground)
        table.add (codes: r (low: 0x30, high: 0x50), state: .escape, action: .escDispatch, next: .ground)
        table.add (codes: r (low: 0x51, high: 0x58), state: .escape, action: .escDispatch, next: .ground)
        table.add (codes: [0x59, 0x5a, 0x5c], state: .escape, action: .escDispatch, next: .ground)
        table.add (codes: r (low: 0x60, high: 0x7f), state: .escape, action: .escDispatch, next: .ground)
        // dcs entry
        table.add (code: 0x50, state: .escape, action: .clear, next: .dcsEntry)
        table.add (codes: executables, state: .dcsEntry, action: .ignore, next: .dcsEntry)
        table.add (code: 0x7f, state: .dcsEntry, action: .ignore, next: .dcsEntry)
        table.add (codes: r (low: 0x1c, high: 0x20), state: .dcsEntry, action: .ignore, next: .dcsEntry)
        table.add (codes: r (low: 0x20, high: 0x30), state: .dcsEntry, action: .collect, next: .dcsIntermediate)
        table.add (code: 0x3a, state: .dcsEntry, action: .ignore, next: .dcsIgnore)
        table.add (codes: r (low: 0x30, high: 0x3a), state: .dcsEntry, action: .param, next: .dcsParam)
        table.add (code: 0x3b, state: .dcsEntry, action: .param, next: .dcsParam)
        table.add (codes: [0x3c, 0x3d, 0x3e, 0x3f], state: .dcsEntry, action: .collect, next: .dcsParam)
        table.add (codes: executables, state: .dcsIgnore, action: .ignore, next: .dcsIgnore)
        table.add (codes: r (low: 0x20, high: 0x80), state: .dcsIgnore, action: .ignore, next: .dcsIgnore)
        table.add (codes: r (low: 0x1c, high: 0x20), state: .dcsIgnore, action: .ignore, next: .dcsIgnore)
        table.add (codes: executables, state: .dcsParam, action: .ignore, next: .dcsParam)
        table.add (code: 0x7f, state: .dcsParam, action: .ignore, next: .dcsParam)
        table.add (codes: r (low: 0x1c, high: 0x20), state: .dcsParam, action: .ignore, next: .dcsParam)
        table.add (codes: r (low: 0x30, high: 0x3a), state: .dcsParam, action: .param, next: .dcsParam)
        table.add (code: 0x3b, state: .dcsParam, action: .param, next: .dcsParam)
        table.add (codes: [0x3a, 0x3c, 0x3d, 0x3e, 0x3f], state: .dcsParam, action: .ignore, next: .dcsIgnore)
        table.add (codes: r (low: 0x20, high: 0x30), state: .dcsParam, action: .collect, next: .dcsIntermediate)
        table.add (codes: executables, state: .dcsIntermediate, action: .ignore, next: .dcsIntermediate)
        table.add (code: 0x7f, state: .dcsIntermediate, action: .ignore, next: .dcsIntermediate)
        table.add (codes: r (low: 0x1c, high: 0x20), state: .dcsIntermediate, action: .ignore, next: .dcsIntermediate)
        table.add (codes: r (low: 0x20, high: 0x30), state: .dcsIntermediate, action: .collect, next: .dcsIntermediate)
        table.add (codes: r (low: 0x30, high: 0x40), state: .dcsIntermediate, action: .ignore, next: .dcsIgnore)
        table.add (codes: r (low: 0x40, high: 0x7f), state: .dcsIntermediate, action: .dcsHook, next: .dcsPassthrough)
        table.add (codes: r (low: 0x40, high: 0x7f), state: .dcsParam, action: .dcsHook, next: .dcsPassthrough)
        table.add (codes: r (low: 0x40, high: 0x7f), state: .dcsEntry, action: .dcsHook, next: .dcsPassthrough)
        table.add (codes: executables, state: .dcsPassthrough, action: .dcsPut, next: .dcsPassthrough)
        table.add (codes: printables, state: .dcsPassthrough, action: .dcsPut, next: .dcsPassthrough)
        table.add (code: 0x7f, state: .dcsPassthrough, action: .ignore, next: .dcsPassthrough)
        table.add (codes: [0x1b, 0x9c], state: .dcsPassthrough, action: .dcsUnhook, next: .ground)
        table.add (code: NonAsciiPrintable, state: .oscString, action: .oscPut, next: .oscString)
        table.add (code: NonAsciiPrintable, state: .apcString, action: .oscPut, next: .apcString)
        return table
    }
    
    // Array of parameters, and "collect" string
    typealias CsiHandler = ([Int],cstring) -> ()
    typealias CsiHandlerFallback = ([Int],cstring,UInt8) -> ()
    
    /// Signature for an OSC handler, it will receive the byte array containing the data to this OSC sequence
    public typealias OscHandler = (ArraySlice<UInt8>) -> ()
    
    /// If no OSC handler is found, this is the signature of a fallback method that will
    /// receive both the OSC code as the first parameter, along with a byte array containing
    /// the payload for the OSC message.
    public typealias OscHandlerFallback = (Int, ArraySlice<UInt8>) -> ()

    /// Signature for an APC handler, it will receive the byte array containing the data to this APC sequence
    public typealias ApcHandler = (ArraySlice<UInt8>) -> ()
    public typealias ApcHandlerFallback = (UInt8, ArraySlice<UInt8>) -> ()
    
    typealias DscHandlerFallback = (UInt8, [Int]) -> ()
    
    // Collect + flag
    typealias EscHandler = (cstring, UInt8) -> ()
    typealias EscHandlerFallback = (cstring, UInt8) -> ()
    
    // Range of bytes to print out
    typealias PrintHandler = (ArraySlice<UInt8>) -> ()
    
    typealias ExecuteHandler = () -> ()
    
    /// Maps an integer code to a custom OSC handler that will be invoked when this value is
    /// found. Custom handlers are checked before built-in handlers, allowing overrides.
    /// For example, to set a handler for the OSC 123, you would do:
    /// ```
    /// terminal.parser.oscHandlers [123] = { [unowned self] data in
    ///     guard let cmd = String (bytes: data, encoding: .utf8) else { return }
    ///     print ("The parameters to my OSC handler are: \(cmd)")
    /// }
    /// ```
    public var oscHandlers: [Int:OscHandler] = [:]
    
    var activeDcsHandler: DcsHandler? = nil
    var errorHandler: (ParsingState) -> ParsingState = { (state : ParsingState) -> ParsingState in return state; }

    // Reference to the terminal for direct dispatch
    unowned var terminal: Terminal?

    var initialState: ParserState = .ground
    var currentState: ParserState = .ground
    
    // buffers over several calls
    var _osc: cstring
    var _apc: cstring
    var _pars: [Int]
    var _parsTxt: [UInt8]
    var _collect: cstring
    var printHandler: PrintHandler = { (slice : ArraySlice<UInt8>) -> () in }
    var printStateReset: () -> () = {  }
    
    var table: TransitionTable
    
    init (terminal: Terminal? = nil)
    {
        self.terminal = terminal
        table = EscapeSequenceParser.buildVt500TransitionTable()
        _osc = []
        _apc = []
        _pars = [0]
        _parsTxt = []
        _collect = []
    }

    // MARK: - Dispatch Methods

    func dispatchExecute(code: UInt8) {
        guard let terminal = terminal else { return }
        switch code {
        case 7:    terminal.tdel?.bell(source: terminal)
        case 8:    terminal.cmdBackspace()
        case 9:    terminal.cmdTab()
        case 10:   terminal.cmdLineFeed()
        case 11:   terminal.cmdLineFeedBasic()
        case 12:   terminal.cmdLineFeedBasic()
        case 13:   terminal.cmdCarriageReturn()
        case 14:   terminal.cmdShiftOut()
        case 15:   terminal.cmdShiftIn()
        case 0x84: terminal.cmdIndex()
        case 0x85: terminal.cmdNextLine()
        case 0x88: terminal.cmdTabSet()
        default:   break
        }
    }

    func dispatchCsi(code: UInt8, pars: [Int], collect: cstring) {
        guard let terminal = terminal else {
            csiHandlerFallback(pars, collect, code)
            return
        }
        switch code {
        case 0x40: terminal.cmdInsertChars(pars, collect)       // @
        case 0x41: terminal.cmdCursorUp(pars, collect)          // A
        case 0x42: terminal.cmdCursorDown(pars, collect)        // B
        case 0x43: terminal.cmdCursorForward(pars, collect)     // C
        case 0x44: terminal.cmdCursorBackward(pars, collect)    // D
        case 0x45: terminal.cmdCursorNextLine(pars, collect)    // E
        case 0x46: terminal.cmdCursorPrecedingLine(pars, collect) // F
        case 0x47: terminal.cmdCursorCharAbsolute(pars, collect) // G
        case 0x48: terminal.cmdCursorPosition(pars, collect)    // H
        case 0x49: terminal.cmdCursorForwardTab(pars, collect)  // I
        case 0x4a: terminal.cmdEraseInDisplay(pars, collect)    // J
        case 0x4b: terminal.cmdEraseInLine(pars, collect)       // K
        case 0x4c: terminal.cmdInsertLines(pars, collect)       // L
        case 0x4d: terminal.cmdDeleteLines(pars, collect)       // M
        case 0x50: terminal.cmdDeleteChars(pars, collect)       // P
        case 0x53: terminal.cmdScrollUp(pars, collect)          // S
        case 0x54: terminal.csiT(pars, collect)                 // T
        case 0x58: terminal.cmdEraseChars(pars, collect)        // X
        case 0x5a: terminal.cmdCursorBackwardTab(pars, collect) // Z
        case 0x60: terminal.cmdCharPosAbsolute(pars, collect)   // `
        case 0x61: terminal.cmdHPositionRelative(pars, collect) // a
        case 0x62: terminal.cmdRepeatPrecedingCharacter(pars, collect) // b
        case 0x63: terminal.cmdSendDeviceAttributes(pars, collect) // c
        case 0x64: terminal.cmdLinePosAbsolute(pars, collect)   // d
        case 0x65: terminal.cmdVPositionRelative(pars, collect) // e
        case 0x66: terminal.cmdHVPosition(pars, collect)        // f
        case 0x67: terminal.cmdTabClear(pars, collect)          // g
        case 0x68: terminal.cmdSetMode(pars, collect)           // h
        case 0x6c: terminal.cmdResetMode(pars, collect)         // l
        case 0x6d: terminal.cmdCharAttributes(pars, collect)    // m
        case 0x6e: terminal.cmdDeviceStatus(pars, collect)      // n
        case 0x70: terminal.csiPHandler(pars, collect)          // p
        case 0x71: terminal.cmdSetCursorStyle(pars, collect)    // q
        case 0x72: terminal.cmdSetScrollRegion(pars, collect)   // r
        case 0x73:                                              // s
            if terminal.marginMode {
                terminal.cmdSetMargins(pars, collect)
            } else {
                terminal.cmdSaveCursor(pars, collect)
            }
        case 0x74: terminal.csit(pars, collect)                 // t
        case 0x75: terminal.cmdRestoreCursor(pars, collect)     // u
        case 0x76: terminal.csiCopyRectangularArea(pars, collect) // v
        case 0x78: terminal.csiX(pars, collect)                 // x (DECFRA)
        case 0x79: terminal.cmdDECRQCRA(pars, collect)          // y
        case 0x7a: terminal.csiZ(pars, collect)                 // z (DECERA)
        case 0x7b: terminal.csiOpenBrace(pars, collect)         // {
        case 0x7d: terminal.csiCloseBrace(pars, collect)        // }
        case 0x7e: terminal.cmdDeleteColumns(pars, collect)     // ~
        default:
            csiHandlerFallback(pars, collect, code)
        }
    }

    func dispatchEsc(collect: cstring, code: UInt8) {
        guard let terminal = terminal else {
            escHandlerFallback(collect, code)
            return
        }

        if collect.isEmpty {
            // Single-character ESC sequences
            switch code {
            case 0x36: terminal.columnIndex(back: true)         // 6
            case 0x37: terminal.cmdSaveCursor([], [])           // 7
            case 0x38: terminal.cmdRestoreCursor([], [])        // 8
            case 0x39: terminal.columnIndex(back: false)        // 9
            case 0x44: terminal.cmdIndex()                      // D
            case 0x45: terminal.cmdNextLine()                   // E
            case 0x48: terminal.cmdTabSet()                     // H
            case 0x4d: terminal.reverseIndex()                  // M
            case 0x3d: terminal.cmdKeypadApplicationMode()      // =
            case 0x3e: terminal.cmdKeypadNumericMode()          // >
            case 0x63: terminal.cmdReset()                      // c
            case 0x6e: terminal.setgLevel(2)                    // n
            case 0x6f: terminal.setgLevel(3)                    // o
            case 0x7c: terminal.setgLevel(3)                    // |
            case 0x7d: terminal.setgLevel(2)                    // }
            case 0x7e: terminal.setgLevel(1)                    // ~
            case 0x5c: break                                    // \ (ST terminator, no-op)
            default:
                escHandlerFallback(collect, code)
            }
        } else if collect.count == 1 {
            let prefix = collect[0]
            switch prefix {
            case 0x25: // "%" prefix
                switch code {
                case 0x40, 0x47: terminal.cmdSelectDefaultCharset() // %@ or %G
                default: escHandlerFallback(collect, code)
                }
            case 0x23: // "#" prefix
                switch code {
                case 0x33: terminal.cmdSetDoubleHeightTop()     // #3
                case 0x34: terminal.cmdSetDoubleHeightBottom()  // #4
                case 0x35: terminal.cmdSingleWidthSingleHeight() // #5
                case 0x36: terminal.cmdDoubleWidthSingleHeight() // #6
                case 0x38: terminal.cmdScreenAlignmentPattern() // #8
                default: escHandlerFallback(collect, code)
                }
            case 0x20: // " " prefix
                switch code {
                case 0x47: terminal.cmdSet8BitControls()        // space + G
                case 0x46: terminal.cmdSet7BitControls()        // space + F
                default: escHandlerFallback(collect, code)
                }
            case 0x28, 0x29, 0x2a, 0x2b, 0x2d, 0x2e, 0x2f: // ( ) * + - . /
                // Charset designation
                if CharSets.all.keys.contains(code) {
                    terminal.selectCharset([prefix, code])
                } else {
                    escHandlerFallback(collect, code)
                }
            default:
                escHandlerFallback(collect, code)
            }
        } else {
            escHandlerFallback(collect, code)
        }
    }

    func dispatchOsc(code: Int, data: ArraySlice<UInt8>) {
        // Check user-registered handlers first (allows override)
        if let handler = oscHandlers[code] {
            handler(data)
            return
        }

        guard let terminal = terminal else {
            oscHandlerFallback(code, data)
            return
        }

        switch code {
        case 0:    terminal.setTitle(text: String(bytes: data, encoding: .utf8) ?? "")
        case 1:    terminal.setIconTitle(text: String(bytes: data, encoding: .utf8) ?? "")
        case 2:    terminal.setTitle(text: String(bytes: data, encoding: .utf8) ?? "")
        case 4:    terminal.oscChangeOrQueryColorIndex(data)
        case 6:    terminal.oscSetCurrentDocument(data)
        case 7:    terminal.oscSetCurrentDirectory(data)
        case 8:    terminal.oscHyperlink(data)
        case 10:   terminal.oscSetColors(data, startAt: 0)
        case 11:   terminal.oscSetColors(data, startAt: 1)
        case 12:   terminal.oscSetColors(data, startAt: 2)
        case 52:   terminal.oscClipboard(data)
        case 104:  terminal.oscResetColor(data)
        case 112:  terminal.tdel?.setCursorColor(source: terminal, color: nil)
        case 777:  terminal.oscNotification(data)
        case 1337: terminal.osciTerm2(data)
        default:
            oscHandlerFallback(code, data)
        }
    }

    func dispatchApc(command: UInt8, content: ArraySlice<UInt8>) {
        guard let terminal = terminal else {
            apcHandlerFallback(command, content)
            return
        }

        switch command {
        case 0x47: terminal.handleKittyGraphics(content)  // G
        default:
            apcHandlerFallback(command, content)
        }
    }

    func dispatchDcs(collect: cstring, code: UInt8, pars: [Int]) -> DcsHandler? {
        guard let terminal = terminal else { return nil }

        // Match on collect + code
        if collect == [0x24] && code == 0x71 {  // "$q"
            return Terminal.DECRQSS(terminal: terminal)
        } else if collect.isEmpty && code == 0x71 {  // "q"
            return SixelDcsHandler(terminal: terminal)
        }
        return nil
    }

    var escHandlerFallback: EscHandlerFallback = { (collect: cstring, flag: UInt8) in
    }

    var dscHandlerFallback: DscHandlerFallback = { code, pars in }
    
    var executeHandlerFallback : ExecuteHandler = { () -> () in
    }
    
    var csiHandlerFallback : CsiHandlerFallback = { (pars: [Int], collect: cstring, code: UInt8) -> () in
        print ("Cannot handle ESC-\(code)")
    }
    
    var oscHandlerFallback: OscHandlerFallback = { code, data -> () in
        
    }
    var apcHandlerFallback: ApcHandlerFallback = { code, data -> () in
        
    }
    
    func reset ()
    {
        currentState = initialState
        _osc = []
        _apc = []
        _pars = [0]
        _collect = []
        activeDcsHandler = nil
        printStateReset()
    }

    var logFileCounter = 1
    func dump (_ data: ArraySlice<UInt8>)
    {
        let dir = "/tmp"
        let path = dir + "/log-\(logFileCounter)"
        do {
            let dataCopy = Data (data)
            try dataCopy.write(to: URL.init(fileURLWithPath: path))
            logFileCounter += 1
        } catch {
            // Ignore write error
            //print ("Got error while logging data dump to \(path)")
        }
    }
    
    func parse (data: ArraySlice<UInt8>)
    {
        var code : UInt8 = 0
        var transition : UInt8 = 0
        var error = false
        var currentState = self.currentState
        var print = -1
        var dcs = -1
        var osc = self._osc
        var apc = self._apc
        var collect = self._collect
        var pars = self._pars
        var parsTxt = self._parsTxt
        var dcsHandler = activeDcsHandler
        
        //dump (data)
            
        // process input string
        var i = data.startIndex
        // let len = data.count
        let end = data.endIndex
        while i < end {
            code = data [i]
            
            // 1f..80 are printable ascii characters
            // c2..f3 are valid utf8 beginning of sequence elements, and most importantly,
            // does not cover 0x90 which is the DCS initiator in 8 bit mode.
            
            // The nice code is commented out, because this ends up consuming valid utf8 code when
            // we are in the middle of things (force a small reading buffer to see more easily)
            if currentState == .ground && code > 0x1f  { // }(code > 0x1f && code < 0x80 || (code > 0xc2 && code < 0xf3)) {
                print = (~print != 0) ? print : i
                repeat {
                    i += 1
                } while i < end && data [i] > 0x1f
                continue;
            }
            
            // shortcut for CSI params
            if currentState == .csiParam && (code > 0x2f && code < 0x39) {
                let newV = pars [pars.count - 1] * 10 + Int(code) - 48
                
                // Prevent attempts at overflowing - crash 
                let willOverflow =  newV > ((Int.max/10)-10)
                pars [pars.count - 1] = willOverflow ? 0 : newV
                parsTxt.append(code)
                i += 1
                continue
            }
            
            // Normal transition and action loop
            transition = table [(Int(currentState.rawValue) << 8) | Int (UInt8 ((code < 0xa0 ? code : EscapeSequenceParser.NonAsciiPrintable)))]
            let action = ParserAction (rawValue: transition >> 4)!
            switch action {
            case .print:
                print = (~print != 0) ? print : i
            case .execute:
                if ~print != 0 {
                    printHandler (data [print..<i])
                    print = -1
                }
                dispatchExecute(code: code)
            case .ignore:
                // handle leftover print or dcs chars
                if ~print != 0 {
                    printHandler (data [print..<i])
                    print = -1
                } else if ~dcs != 0 {
                    dcsHandler?.put (data: data [dcs..<i])
                    dcs = -1
                }
            case .error:
                // chars higher than 0x9f are handled by this action
                // to keep the transition table small
                if code > 0x9f {
                    switch (currentState) {
                    case .ground:
                        print = (~print != 0) ? print : i;
                    case .csiIgnore:
                        transition |= ParserState.csiIgnore.rawValue;
                    case .dcsIgnore:
                        transition |= ParserState.dcsIgnore.rawValue;
                    case .dcsPassthrough:
                        dcs = (~dcs != 0) ? dcs : i;
                        transition |= ParserState.dcsPassthrough.rawValue;
                        break;
                    default:
                        error = true;
                        break;
                    }
                } else {
                    error = true;
                }
                // if we end up here a real error happened
                if error {
                    let state = ParsingState ()
                    state.position = i
                    state.code = code
                    state.currentState = currentState
                    state.print = print
                    state.dcs = dcs
                    state.osc = osc
                    state.apc = apc
                    state.collect = collect
                    let inject = errorHandler (state)
                    if inject.abort {
                        return;
                    }
                    error = false;
                }
            case .csiDispatch:
                _parsTxt = parsTxt
                dispatchCsi(code: code, pars: pars, collect: collect)
            case .param:
                parsTxt.append(code)
                if code == 0x3b || code == 0x3a {
                    pars.append (0)
                } else {
                    let newV = pars [pars.count - 1] * 10 + Int(code) - 48
                    
                    // Prevent attempts at overflowing - crash
                    let willOverflow =  newV > ((Int.max/10)-10)
                    pars [pars.count - 1] = willOverflow ? 0 : newV
                }
            case .escDispatch:
                dispatchEsc(collect: collect, code: code)
            case .collect:
                collect.append (code)
            case .clear:
                if ~print != 0 {
                    printHandler (data [print..<i])
                    print = -1
                }
                osc = []
                apc = []
                pars = [0]
                parsTxt = []
                collect = []
                dcs = -1
                printStateReset()
            case .dcsHook:
                if let handler = dispatchDcs(collect: collect, code: code, pars: pars) {
                    dcsHandler = handler
                    handler.hook(collect: collect, parameters: pars, flag: code)
                }
            case .dcsPut:
                dcs = (~dcs != 0) ? dcs : i
            case .dcsUnhook:
                if let d = dcsHandler {
                    if ~dcs != 0 {
                        d.put (data: data[dcs..<i])
                        d.unhook ()
                        dcsHandler = nil
                    }
                }
                if code == 0x1b {
                    transition |= ParserState.escape.rawValue
                }
                osc = []
                apc = []
                pars = [0]
                parsTxt = []
                collect = []
                dcs = -1
                printStateReset()
            case .oscStart:
                if ~print != 0 {
                    printHandler (data[print..<i])
                    print = -1
                }
                let nextState = ParserState (rawValue: transition & 15)!
                if nextState == .apcString {
                    apc = []
                } else {
                    osc = []
                }
            case .oscPut:
                var j = i
                while j < end {
                    let c = data [j]
                    if c == ControlCodes.BEL || c == ControlCodes.CAN || c == ControlCodes.ESC {
                        break
                    } else if c >= 0x20 {
                        if currentState == .apcString {
                            apc.append (c)
                        } else {
                            osc.append (c)
                        }
                    }
                    j += 1
                }
                i = j - 1
            case .oscEnd:
                if currentState == .apcString {
                    if apc.count != 0 && code != ControlCodes.CAN && code != ControlCodes.SUB {
                        let command = apc[apc.startIndex]
                        let content = apc.count > 1 ? apc[(apc.startIndex+1)...] : ArraySlice<UInt8>()
                        dispatchApc(command: command, content: content)
                    }
                } else {
                    if osc.count != 0 && code != ControlCodes.CAN && code != ControlCodes.SUB {
                        var oscCode: Int
                        var content: ArraySlice<UInt8>
                        let semiColonAscii = 59 // ';'

                        if let idx = osc.firstIndex(of: UInt8(semiColonAscii)) {
                            oscCode = EscapeSequenceParser.parseInt(osc[0..<idx])
                            content = osc[(idx+1)...]
                        } else {
                            oscCode = EscapeSequenceParser.parseInt(osc[0...])
                            content = []
                        }
                        dispatchOsc(code: oscCode, data: content)
                    }
                }
                if code == 0x1b {
                    transition |= ParserState.escape.rawValue
                }
                osc = []
                apc = []
                pars = [0]
                parsTxt = []
                collect = []
                dcs = -1
                printStateReset()
            }
            currentState = ParserState (rawValue: transition & 15)!
            i += 1
        }
        // push leftover pushable buffers to terminal
        if currentState == .ground && (~print != 0) {
            printHandler (data [print..<end])
        } else if currentState == .dcsPassthrough && (~dcs != 0) && dcsHandler != nil {
            dcsHandler!.put (data: data [dcs..<end])
        }
        // save non pushable buffers
        _osc = osc
        _apc = apc
        _collect = collect
        _pars = pars
        _parsTxt = parsTxt
        
        // save active dcs handler reference
        activeDcsHandler = dcsHandler
        
        // save state
        
        self.currentState = currentState
        
    }
    
    static func parseInt (_ str: ArraySlice<UInt8>) -> Int
    {
        var result = 0
        for x in str {
            if x < 48 || x > 57 {
                return result
            }
            
            let newV = result * 10 + Int ((x - 48))
            let willOverflow =  newV > ((Int.max/10)-10)
            if willOverflow {
                return 0
            }
            result = newV
        }
        return result
    }
}
