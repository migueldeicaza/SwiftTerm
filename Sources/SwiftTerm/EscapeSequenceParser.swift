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
#if canImport(os)
import os
#endif

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
    /// The transition table does not produce this action. This case makes all
    /// four-bit values valid before `decode` reinterprets one as an action.
    case reserved
}

extension ParserAction {
    /// Decodes the action nibble from a transition-table entry.
    @inline(__always)
    static func decode (_ raw: UInt8) -> ParserAction {
        assert (ParserAction (rawValue: raw) != nil)
        return unsafeBitCast (raw, to: ParserAction.self)
    }
}

final class TransitionTable: Sendable {
    // data is packed like this:
    // currentState << 8 | characterCode  -->  action << 4 | nextState
    let table: [UInt8]
    
    fileprivate init (_ table: [UInt8])
    {
        self.table = table
    }

    subscript (idx: Int) -> UInt8 {
        table [idx]
    }
}

fileprivate struct TransitionTableBuilder {
    var table: [UInt8]

    init (len: Int)
    {
        table = Array.init (repeating: 0, count: len)
    }
    
    mutating func add (code: UInt8, state: ParserState, action: ParserAction, next: ParserState)
    {
        let v = (UInt8 (action.rawValue) << 4) | next.rawValue
        table [(Int (state.rawValue) << 8) | Int(code)] = v
    }
    
    mutating func add (codes: [UInt8], state: ParserState, action: ParserAction, next: ParserState)
    {
        for c in codes {
            add (code: c, state: state, action: action, next: next)
        }
    }
}

protocol  DcsHandler {
    func hook (collect: cstring, parameters: [Int],  flag: UInt8)
    func put (data : ArraySlice<UInt8>)
    func unhook ()
}

/// One OSC sequence observed at the parser boundary.
///
/// The payload is an owned copy. It stays valid after parser dispatch returns.
public struct TerminalOscEvent: Equatable, Sendable {
    /// The numeric OSC command.
    public let code: Int

    /// The bytes after the OSC command and separator.
    public let payload: [UInt8]

    public init(code: Int, payload: [UInt8]) {
        self.code = code
        self.payload = payload
    }
}

/// Keeps one OSC event observation active.
///
/// Retain this value for as long as events are required. Deinitialization calls
/// ``cancel()``. Cancellation is idempotent. A delivery that already passed
/// its cancellation check can finish, but cancellation suppresses later
/// queued deliveries.
public final class TerminalOscObservation: Sendable {
    private let cancellation: @Sendable () -> Void

    fileprivate init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    /// Stops this observation.
    public func cancel() {
        cancellation()
    }

    deinit {
        cancellation()
    }
}

/// Copies parser events and sends them on a serial queue.
final class TerminalOscEventDispatcher: Sendable {
    private struct Registration: Sendable {
        let id: UInt64
        let handler: @Sendable (TerminalOscEvent) -> Void
    }

    private struct State {
        var nextID: UInt64 = 0
        var registrations: [Registration] = []
    }

    private let state = Locked(State())
    private let deliveryQueue = DispatchQueue(label: "org.tirania.SwiftTerm.osc-events")

    func observe(
        _ handler: @escaping @Sendable (TerminalOscEvent) -> Void
    ) -> TerminalOscObservation {
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID &+= 1
            state.registrations.append(Registration(id: id, handler: handler))
            return id
        }

        return TerminalOscObservation { [weak self] in
            self?.cancel(id: id)
        }
    }

    func publish(code: Int, payload: ArraySlice<UInt8>) {
        let registrations = state.withLock { $0.registrations }
        guard !registrations.isEmpty else { return }
        let event = TerminalOscEvent(code: code, payload: Array(payload))

        deliveryQueue.async { [self] in
            for registration in registrations {
                let isActive = state.withLock { state in
                    state.registrations.contains { $0.id == registration.id }
                }
                if isActive {
                    registration.handler(event)
                }
            }
        }
    }

    private func cancel(id: UInt64) {
        state.withLock { state in
            state.registrations.removeAll { $0.id == id }
        }
    }
}

/// The engine that drives the parsing of the data stream for the terminal.
///
/// It is used by the ``Terminal`` to interpret the sequence of bytes coming, and
/// it is possible for users to hook up Operating System Command handlers (OSC -
/// they begin with the two byte sequence ESC and ]).   These are typically used
/// to implement custom communication channels.
///
final class EscapeSequenceParser {
#if canImport(os)
    private static let profileLog = OSLog(subsystem: "org.tirania.SwiftTerm", category: "ParserProfile")
    private static let profileEnabled = ProcessInfo.processInfo.environment["SWIFTTERM_PROFILE"] == "1"
#endif
    
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
        var table = TransitionTableBuilder(len: 4095)
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
        table.add (codes: [0x1b, 0x18, 0x1a, 0x07], state: .oscString, action: .oscEnd, next: .ground)
        // Keep C1 ST as payload in the table. The `oscPut` action decides
        // whether a 0x9c byte ends the sequence or is a UTF-8 continuation
        // byte, so the hot parse loop needs no per-byte test for it.
        table.add (code: 0x9c, state: .oscString, action: .oscPut, next: .oscString)
        table.add (codes: r (low: 0x1c, high: 0x20), state: .oscString, action: .ignore, next: .oscString)
        // apc
        table.add (code: 0x5f, state: .escape, action: .oscStart, next: .apcString)
        table.add (codes: printables, state: .apcString, action: .oscPut, next: .apcString)
        table.add (code: 0x7f, state: .apcString, action: .oscPut, next: .apcString)
        table.add (codes: [0x1b, 0x18, 0x1a, 0x07], state: .apcString, action: .oscEnd, next: .ground)
        table.add (code: 0x9c, state: .apcString, action: .oscPut, next: .apcString)
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
        return TransitionTable(table.table)
    }
    
    /// Signature for a synchronous OSC override. The slice is borrowed and is
    /// valid only for the duration of the call.
    typealias OscHandler = (ArraySlice<UInt8>) -> ()
    
    /// Maps an integer code to a custom OSC handler that will be invoked when this value is
    /// found. Custom handlers are checked before built-in handlers, allowing overrides.
    ///
    /// Register these through the terminal rather than reaching for the parser,
    /// which is no longer accessible from outside the module:
    /// ```
    /// terminal.registerOscHandler (code: 123) { [weak self] data in
    ///     guard let cmd = String (bytes: data, encoding: .utf8) else { return }
    ///     print ("The parameters to my OSC handler are: \(cmd)")
    /// }
    /// ```
    var oscHandlers: [Int:OscHandler] = [:]

    var activeDcsHandler: DcsHandler? = nil
    var dcsHandlerFactory: ((cstring, UInt8, [Int]) -> DcsHandler?)? = nil

    var initialState: ParserState = .ground
    var currentState: ParserState = .ground
    
    // buffers over several calls
    var _osc: cstring
    var _oscLimitExceeded: Bool
    var _apc: cstring
    var _apcLimitExceeded: Bool
    var _pars: [Int]
    /// Bit `i` is set when CSI parameters `i` and `i + 1` use `:`.
    var _parsColonMask: UInt64
    var _collect: cstring
    var _parameterLimitExceeded: Bool
    let maximumOscBytes: Int
    private var didResetDuringParse = false
    private var resetSerial = 0
    private var parseDepth = 0
    
    private static let sharedVt500Table = EscapeSequenceParser.buildVt500TransitionTable()

    /// CSI and DCS parameter values use the same 16-bit saturating range as Ghostty.
    static let maximumParameterValue = Int(UInt16.max)

    /// Sequences beyond this limit are dropped instead of growing parser state without bound.
    static let maximumParameterCount = 24
    /// Maximum bytes accepted for one untrusted OSC sequence.
    ///
    /// This default permits large payloads such as clipboard and inline-file commands.
    static let maximumOscBytes = 65 * 1024 * 1024
    /// An oversized OSC must not pin its peak allocation for the terminal's
    /// lifetime after the sequence ends.
    static let maximumRetainedOscBytes = 1024 * 1024
    /// Kitty-compatible upper bound for one APC sequence.
    static let maximumApcBytes = 65 * 1024 * 1024
    /// An APC accumulator up to this size keeps its capacity between sequences,
    /// which avoids a reallocation for every graphics command. A larger one
    /// releases its storage instead: a single oversized sequence would
    /// otherwise pin up to `maximumApcBytes` for the life of the terminal.
    static let maximumRetainedApcBytes = 1024 * 1024

    /// Clears the APC accumulator, releasing storage that is too large to keep.
    @inline(__always)
    static func resetApc (_ apc: inout cstring, _ limitExceeded: inout Bool)
    {
        if limitExceeded || apc.capacity > maximumRetainedApcBytes {
            apc = []
        } else if !apc.isEmpty {
            apc.removeAll (keepingCapacity: true)
        }
        limitExceeded = false
    }

    /// Clears the OSC accumulator and releases large retained storage.
    @inline(__always)
    static func resetOsc (_ osc: inout cstring, _ limitExceeded: inout Bool)
    {
        if limitExceeded || osc.capacity > maximumRetainedOscBytes {
            osc = []
        } else if !osc.isEmpty {
            osc.removeAll (keepingCapacity: true)
        }
        limitExceeded = false
    }
    let table: TransitionTable
    
    init (maximumOscBytes: Int = EscapeSequenceParser.maximumOscBytes)
    {
        table = EscapeSequenceParser.sharedVt500Table
        self.maximumOscBytes = max (0, maximumOscBytes)
        _osc = []
        _oscLimitExceeded = false
        _apc = []
        _apcLimitExceeded = false
        _pars = [0]
        _parsColonMask = 0
        _collect = []
        _parameterLimitExceeded = false
    }

    @inline(__always)
    private static func appendingParameterDigit(_ code: UInt8, to currentValue: Int) -> Int {
        let digit = Int(code) - 48
        if currentValue > (maximumParameterValue - digit) / 10 {
            return maximumParameterValue
        }
        return currentValue * 10 + digit
    }

    // MARK: - Dispatch Methods

    func dispatchExecute(code: UInt8, _ terminal: Terminal) {
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
        default:   terminal.log ("SwiftTerm: Unknown EXECUTE code")
        }
    }

    func dispatchCsi(code: UInt8, pars: [Int], collect: cstring, _ terminal: Terminal) {
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
        case 0x53:                                              // S
            if collect == [32] {
                terminal.cmdSelectPresentationDirection(pars, collect) // SPD
            } else {
                terminal.cmdScrollUp(pars, collect)
            }
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
        case 0x6b:                                              // k
            if collect == [32] {
                terminal.cmdSelectCharacterPath(pars, collect) // SCP
            }
        case 0x6c: terminal.cmdResetMode(pars, collect)         // l
        case 0x6d: terminal.cmdCsiM(pars, collect)              // m
        case 0x6e: terminal.cmdDeviceStatus(pars, collect)      // n
        case 0x70: terminal.csiPHandler(pars, collect)          // p
        case 0x71:                                              // q
            if collect == [UInt8(ascii: ">")] {
                terminal.cmdXTVERSION(pars, collect)
            } else {
                terminal.cmdSetCursorStyle(pars, collect)
            }
        case 0x72:                                              // r
            if collect == [UInt8(ascii: "?")] {
                terminal.cmdRestorePrivateModes(pars)
            } else {
                terminal.cmdSetScrollRegion(pars, collect)
            }
        case 0x73:                                              // s
            // Plain CSI s is overloaded between save-cursor and DECSLRM, and
            // CSI > Ps s is XTSHIFTESCAPE. Sequences with any other intermediate
            // must not be routed to either save-cursor or DECSLRM.
            if collect == [UInt8 (ascii: ">")] {
                terminal.cmdSetShiftEscape(pars)
            } else if collect == [UInt8(ascii: "?")] {
                terminal.cmdSavePrivateModes(pars)
            } else if collect.isEmpty {
                if terminal.marginMode {
                    terminal.cmdSetMargins(pars, collect)
                } else {
                    terminal.cmdSaveCursor(pars, collect)
                }
            }
        case 0x74: terminal.csit(pars, collect)                 // t
        case 0x75: terminal.cmdCsiU(pars, collect)              // u
        case 0x76: terminal.csiCopyRectangularArea(pars, collect) // v
        case 0x78: terminal.csiX(pars, collect)                 // x (DECFRA)
        case 0x79: terminal.cmdDECRQCRA(pars, collect)          // y
        case 0x7a: terminal.csiZ(pars, collect)                 // z (DECERA)
        case 0x7b: terminal.csiOpenBrace(pars, collect)         // {
        case 0x7d: terminal.csiCloseBrace(pars, collect)        // }
        case 0x7e: terminal.cmdDeleteColumns(pars, collect)     // ~
        default:
            let ch = Character(UnicodeScalar(code))
            terminal.log ("SwiftTerm: Unknown CSI Code (collect=\(collect) code=\(ch) pars=\(pars))")
        }
    }

    func dispatchEsc(collect: cstring, code: UInt8, _ terminal: Terminal) {
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
                terminal.log ("SwiftTerm: Unknown ESC Code: ESC + \(Character(Unicode.Scalar (code))) txt=\(collect)")
            }
        } else if collect.count == 1 {
            let prefix = collect[0]
            switch prefix {
            case 0x25: // "%" prefix
                switch code {
                case 0x40, 0x47: terminal.cmdSelectDefaultCharset() // %@ or %G
                default: terminal.log ("SwiftTerm: Unknown ESC Code: ESC + \(Character(Unicode.Scalar (code))) txt=\(collect)")
                }
            case 0x23: // "#" prefix
                switch code {
                case 0x33: terminal.cmdSetDoubleHeightTop()     // #3
                case 0x34: terminal.cmdSetDoubleHeightBottom()  // #4
                case 0x35: terminal.cmdSingleWidthSingleHeight() // #5
                case 0x36: terminal.cmdDoubleWidthSingleHeight() // #6
                case 0x38: terminal.cmdScreenAlignmentPattern() // #8
                default: terminal.log ("SwiftTerm: Unknown ESC Code: ESC + \(Character(Unicode.Scalar (code))) txt=\(collect)")
                }
            case 0x20: // " " prefix
                switch code {
                case 0x47: terminal.cmdSet8BitControls()        // space + G
                case 0x46: terminal.cmdSet7BitControls()        // space + F
                default: terminal.log ("SwiftTerm: Unknown ESC Code: ESC + \(Character(Unicode.Scalar (code))) txt=\(collect)")
                }
            case 0x28, 0x29, 0x2a, 0x2b, 0x2d, 0x2e, 0x2f: // ( ) * + - . /
                // Charset designation
                if CharSets.all.keys.contains(code) {
                    terminal.selectCharset([prefix, code])
                } else {
                    terminal.log ("SwiftTerm: Unknown ESC Code: ESC + \(Character(Unicode.Scalar (code))) txt=\(collect)")
                }
            default:
                terminal.log ("SwiftTerm: Unknown ESC Code: ESC + \(Character(Unicode.Scalar (code))) txt=\(collect)")
            }
        } else {
            terminal.log ("SwiftTerm: Unknown ESC Code: ESC + \(Character(Unicode.Scalar (code))) txt=\(collect)")
        }
    }

    func dispatchOsc(
        code: Int,
        data: ArraySlice<UInt8>,
        terminator: KittyClipboardOSCTerminator,
        _ terminal: Terminal
    ) {
        // Publish at encounter time. If a synchronous override performs a
        // nested feed, the outer event stays before the nested event.
        terminal.publishOscEvent(code: code, payload: data)

        // Check user-registered handlers first (allows override)
        if let handler = oscHandlers[code] {
            handler(data)
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
        case 9:
            if !terminal.oscProgressReport(data) {
                terminal.log ("SwiftTerm: Unknown OSC code: \(code)")
            }
        case 10:   terminal.oscSetColors(data, startAt: 0)
        case 11:   terminal.oscSetColors(data, startAt: 1)
        case 12:   terminal.oscSetColors(data, startAt: 2)
        case 52:   terminal.oscClipboard(data)
        case 104:  terminal.oscResetColor(data)
        case 112:  terminal.tdel?.setCursorColor(source: terminal, color: nil)
        case 133:  terminal.oscSemanticPrompt(data)
        case 777:  terminal.oscNotification(data)
        case 1337: terminal.osciTerm2(data)
        case 5522: terminal.oscKittyClipboard(data, terminator: terminator)
        default:
            terminal.log ("SwiftTerm: Unknown OSC code: \(code)")
        }
    }

    func dispatchApc(command: UInt8, content: ArraySlice<UInt8>, _ terminal: Terminal) {
        switch command {
        case 0x47: terminal.handleKittyGraphics(content)  // G
        default:
            if let scalar = UnicodeScalar(Int(command)) {
                terminal.log ("SwiftTerm: Unknown APC code: \(Character(scalar))")
            } else {
                terminal.log ("SwiftTerm: Unknown APC code: \(command)")
            }
        }
    }

    func dispatchDcs(collect: cstring, code: UInt8, pars: [Int], _ terminal: Terminal) -> DcsHandler? {
        if let handler = dcsHandlerFactory?(collect, code, pars) {
            return handler
        }

        // Match on collect + code
        if collect == [0x24] && code == 0x71 {  // "$q"
            return Terminal.DECRQSS(terminal: terminal)
        } else if collect.isEmpty && code == 0x71 {  // "q"
            return SixelDcsHandler(terminal: terminal)
        }
        return nil
    }
    
    func reset (_ terminal: Terminal)
    {
        if parseDepth > 0 {
            didResetDuringParse = true
            resetSerial &+= 1
        }
        currentState = initialState
        _osc = []
        _oscLimitExceeded = false
        _apc = []
        _apcLimitExceeded = false
        _pars = [0]
        _parsColonMask = 0
        _collect = []
        _parameterLimitExceeded = false
        activeDcsHandler = nil
        terminal.printStateReset()
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
    
    /// Resets the parser buffers that end an OSC, APC or DCS string.
    ///
    /// The `oscPut` and `oscEnd` actions both end a sequence, so they share
    /// this tail. It takes the parse-loop buffers as `inout` parameters so
    /// that the loop does not have to capture them.
    func endStringSequence(
        osc: inout [UInt8],
        oscLimitExceeded: inout Bool,
        apc: inout [UInt8],
        apcLimitExceeded: inout Bool,
        pars: inout [Int],
        parsColonMask: inout UInt64,
        collect: inout cstring,
        parameterLimitExceeded: inout Bool,
        dcs: inout Int,
        _ terminal: Terminal)
    {
        EscapeSequenceParser.resetOsc (&osc, &oscLimitExceeded)
        EscapeSequenceParser.resetApc (&apc, &apcLimitExceeded)
        if pars.isEmpty {
            pars.append (0)
        } else {
            if pars.count > 1 { pars.removeLast (pars.count - 1) }
            pars [0] = 0
        }
        parsColonMask = 0
        if !collect.isEmpty { collect.removeAll (keepingCapacity: true) }
        parameterLimitExceeded = false
        dcs = -1
        terminal.printStateReset()
    }

    /// True when the tail of the accumulated OSC payload is an incomplete
    /// UTF-8 scalar, so the next byte is a continuation byte rather than a
    /// C1 string terminator.
    static func oscExpectsUTF8Continuation(_ osc: [UInt8]) -> Bool {
        var continuationCount = 0
        for byte in osc.reversed() {
            if byte >= 0x80 && byte <= 0xbf {
                continuationCount += 1
                if continuationCount == 3 { return false }
                continue
            }
            let expectedSize = UnicodeUtil.expectedSizeFromFirstByte(byte)
            guard expectedSize > 1 else { return false }
            return continuationCount < expectedSize - 1
        }
        return false
    }

    /// Splits an accumulated OSC payload into its code and content, and
    /// dispatches it. Takes the payload as a parameter so that the parse loop
    /// does not have to capture its accumulation buffer.
    func dispatchAccumulatedOsc(
        _ osc: [UInt8],
        limitExceeded: Bool,
        terminator: KittyClipboardOSCTerminator,
        _ terminal: Terminal)
    {
        guard !limitExceeded, !osc.isEmpty else { return }
        let oscCode: Int?
        let content: ArraySlice<UInt8>
        if let index = osc.firstIndex(of: UInt8(ascii: ";")) {
            oscCode = EscapeSequenceParser.parseDecimal(osc[..<index])
            content = osc[osc.index(after: index)...]
        } else {
            oscCode = EscapeSequenceParser.parseDecimal(osc[...])
            content = []
        }
        if let oscCode {
            dispatchOsc(
                code: oscCode,
                data: content,
                terminator: terminator,
                terminal)
        }
    }

    func parse (data: ArraySlice<UInt8>, _ terminal: Terminal)
    {
        parseBorrowed(data.span, terminal)
    }

    func parseBorrowed(_ data: Span<UInt8>, _ terminal: Terminal)
    {
        parseDepth += 1
        defer { parseDepth -= 1 }
        let resetSerialAtStart = resetSerial
#if canImport(os)
        let signpostID = OSSignpostID(log: EscapeSequenceParser.profileLog)
        if EscapeSequenceParser.profileEnabled {
            os_signpost(.begin, log: EscapeSequenceParser.profileLog, name: "Parser.Parse", signpostID: signpostID)
        }
        defer {
            if EscapeSequenceParser.profileEnabled {
                os_signpost(.end, log: EscapeSequenceParser.profileLog, name: "Parser.Parse", signpostID: signpostID)
            }
        }
#endif
        var code : UInt8 = 0
        var transition : UInt8 = 0
        var error = false
        var currentState = self.currentState.rawValue
        var print = -1
        var dcs = -1
        var osc = self._osc
        self._osc = []
        var oscLimitExceeded = self._oscLimitExceeded
        self._oscLimitExceeded = false
        var apc = self._apc
        self._apc = []
        var apcLimitExceeded = self._apcLimitExceeded
        self._apcLimitExceeded = false
        var collect = self._collect
        self._collect = []
        var pars = self._pars
        self._pars = []
        var parsColonMask = self._parsColonMask
        self._parsColonMask = 0
        var parameterLimitExceeded = self._parameterLimitExceeded
        let tableData = table.table
        var dcsHandler = activeDcsHandler

        func ownedSlice(_ range: Range<Int>) -> ArraySlice<UInt8> {
            let result = data.extracting(range).copiedBytes()
            return result[...]
        }

        // These helpers take the accumulation buffers as `inout` parameters
        // rather than capturing them. A nested function that captures a
        // mutable local boxes that local, and every access in the hot parse
        // loop then goes through a dynamic exclusivity check.
        func appendBytes(_ range: Range<Int>, to output: inout [UInt8]) {
            output.reserveCapacity(output.count + range.count)
            for index in range {
                output.append(data[index])
            }
        }

        func appendApcBytes(
            _ range: Range<Int>,
            to apc: inout [UInt8],
            _ apcLimitExceeded: inout Bool)
        {
            guard !apcLimitExceeded else { return }
            let remaining = EscapeSequenceParser.maximumApcBytes - apc.count
            if range.count > remaining {
                if remaining > 0 {
                    appendBytes(range.lowerBound..<(range.lowerBound + remaining), to: &apc)
                }
                apcLimitExceeded = true
                return
            }
            appendBytes(range, to: &apc)
        }

        func appendOscBytes(
            _ range: Range<Int>,
            to osc: inout [UInt8],
            _ oscLimitExceeded: inout Bool)
        {
            guard !oscLimitExceeded else { return }
            let remaining = maximumOscBytes - osc.count
            if range.count > remaining {
                if remaining > 0 {
                    appendBytes(range.lowerBound..<(range.lowerBound + remaining), to: &osc)
                }
                oscLimitExceeded = true
                terminal.log ("SwiftTerm: OSC sequence exceeded the maximum size of \(maximumOscBytes) bytes and was dropped")
                return
            }
            appendBytes(range, to: &osc)
        }
        
        //dump (data)
            
        // process input string
        var i = 0
        let end = data.count
        var input = data
        while !input.isEmpty {
            code = input[0]
            
            // 1f..80 are printable ascii characters
            // c2..f3 are valid utf8 beginning of sequence elements, and most importantly,
            // does not cover 0x90 which is the DCS initiator in 8 bit mode.
            
            // The nice code is commented out, because this ends up consuming valid utf8 code when
            // we are in the middle of things (force a small reading buffer to see more easily)
            if currentState == ParserState.ground.rawValue && code > 0x1f  { // }(code > 0x1f && code < 0x80 || (code > 0xc2 && code < 0xf3)) {
                print = (~print != 0) ? print : i
                let next = ByteRunScanner.firstC0Byte(in: data, from: i)
                input = input.extracting(droppingFirst: next - i)
                i = next
                continue;
            }
            
            // shortcut for CSI params
            if currentState == ParserState.csiParam.rawValue && (code > 0x2f && code < 0x3a) {
                if !parameterLimitExceeded {
                    pars [pars.count - 1] = EscapeSequenceParser.appendingParameterDigit(
                        code,
                        to: pars [pars.count - 1])
                }
                input = input.extracting(droppingFirst: 1)
                i += 1
                continue
            }
            
            // Normal transition and action loop
            transition = tableData [(Int(currentState) << 8) | Int (UInt8 ((code < 0xa0 ? code : EscapeSequenceParser.NonAsciiPrintable)))]
            let action = ParserAction.decode (transition >> 4)
            var consumed = 1
            switch action {
            case .print:
                print = (~print != 0) ? print : i
            case .execute:
                if ~print != 0 {
                    terminal.handlePrintBorrowed(data.extracting(print..<i))
                    print = -1
                }
                dispatchExecute(code: code, terminal)
            case .ignore:
                // handle leftover print or dcs chars
                if ~print != 0 {
                    terminal.handlePrintBorrowed(data.extracting(print..<i))
                    print = -1
                } else if ~dcs != 0 {
                    dcsHandler?.put(data: ownedSlice(dcs..<i))
                    dcs = -1
                }
            case .error:
                let decodedCurrentState = ParserState (rawValue: currentState)!
                // chars higher than 0x9f are handled by this action
                // to keep the transition table small
                if code > 0x9f {
                    switch decodedCurrentState {
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
                    state.currentState = decodedCurrentState
                    state.print = print
                    state.dcs = dcs
                    state.osc = osc
                    state.apc = apc
                    state.collect = collect
                    terminal.log ("SwiftTerm: Parsing error, state: \(state)")
                    if state.abort {
                        return;
                    }
                    error = false;
                }
            case .csiDispatch:
                if !parameterLimitExceeded {
                    // cmdCharAttributes is the only reader of separator type.
                    if code == 0x6d { _parsColonMask = parsColonMask }
                    dispatchCsi(code: code, pars: pars, collect: collect, terminal)
                }
            case .param:
                if code == 0x3b || code == 0x3a {
                    if pars.count >= EscapeSequenceParser.maximumParameterCount {
                        parameterLimitExceeded = true
                    } else if !parameterLimitExceeded {
                        if code == 0x3a {
                            parsColonMask |= UInt64(1) << UInt64(pars.count - 1)
                        }
                        pars.append (0)
                    }
                } else if !parameterLimitExceeded {
                    pars [pars.count - 1] = EscapeSequenceParser.appendingParameterDigit(
                        code,
                        to: pars [pars.count - 1])
                }
            case .escDispatch:
                dispatchEsc(collect: collect, code: code, terminal)
            case .collect:
                collect.append (code)
            case .clear:
                if ~print != 0 {
                    terminal.handlePrintBorrowed(data.extracting(print..<i))
                    print = -1
                }
                EscapeSequenceParser.resetOsc (&osc, &oscLimitExceeded)
                EscapeSequenceParser.resetApc (&apc, &apcLimitExceeded)
                if pars.isEmpty {
                    pars.append (0)
                } else {
                    if pars.count > 1 { pars.removeLast (pars.count - 1) }
                    pars [0] = 0
                }
                parsColonMask = 0
                if !collect.isEmpty { collect.removeAll (keepingCapacity: true) }
                parameterLimitExceeded = false
                dcs = -1
                terminal.printStateReset()
            case .dcsHook:
                if !parameterLimitExceeded,
                   let handler = dispatchDcs(collect: collect, code: code, pars: pars, terminal) {
                    dcsHandler = handler
                    handler.hook(collect: collect, parameters: pars, flag: code)
                }
            case .dcsPut:
                dcs = (~dcs != 0) ? dcs : i
            case .dcsUnhook:
                if let d = dcsHandler {
                    if ~dcs != 0 {
                        d.put(data: ownedSlice(dcs..<i))
                        d.unhook ()
                        dcsHandler = nil
                    }
                }
                if code == 0x1b {
                    transition |= ParserState.escape.rawValue
                }
                EscapeSequenceParser.resetOsc (&osc, &oscLimitExceeded)
                EscapeSequenceParser.resetApc (&apc, &apcLimitExceeded)
                if pars.isEmpty {
                    pars.append (0)
                } else {
                    if pars.count > 1 { pars.removeLast (pars.count - 1) }
                    pars [0] = 0
                }
                parsColonMask = 0
                if !collect.isEmpty { collect.removeAll (keepingCapacity: true) }
                parameterLimitExceeded = false
                dcs = -1
                terminal.printStateReset()
            case .oscStart:
                if ~print != 0 {
                    terminal.handlePrintBorrowed(data.extracting(print..<i))
                    print = -1
                }
                let nextState = transition & 15
                if nextState == ParserState.apcString.rawValue {
                    apc = []
                    apcLimitExceeded = false
                } else {
                    osc = []
                    oscLimitExceeded = false
                }
            case .oscPut:
                var j: Int
                var c1Terminated = false
                if currentState == ParserState.apcString.rawValue {
                    j = ByteRunScanner.firstC0Byte(in: data, from: i)
                    appendApcBytes(i..<j, to: &apc, &apcLimitExceeded)
                } else if oscLimitExceeded {
                    // The payload is already dropped, so C1 ST stays payload
                    // and only a C0 byte ends the run.
                    j = ByteRunScanner.firstC0Byte(in: data, from: i)
                } else {
                    // One pass finds the run boundary, which is either a C0
                    // byte or a C1 ST byte that ends the sequence.
                    var appendedThrough = i
                    var searchStart = i
                    while true {
                        j = ByteRunScanner.firstC0OrByte(0x9c, in: data, from: searchStart)
                        guard j < data.count, data[j] == 0x9c else { break }
                        appendOscBytes(appendedThrough..<j, to: &osc, &oscLimitExceeded)
                        appendedThrough = j
                        guard oscLimitExceeded
                                || EscapeSequenceParser.oscExpectsUTF8Continuation(osc)
                        else {
                            c1Terminated = true
                            break
                        }
                        appendOscBytes(j..<(j + 1), to: &osc, &oscLimitExceeded)
                        appendedThrough = j + 1
                        searchStart = j + 1
                        if oscLimitExceeded {
                            j = ByteRunScanner.firstC0Byte(in: data, from: searchStart)
                            break
                        }
                    }
                    appendOscBytes(appendedThrough..<j, to: &osc, &oscLimitExceeded)
                    if c1Terminated {
                        // The transition table keeps 0x9c as payload, so this
                        // action ends the sequence and consumes the byte.
                        dispatchAccumulatedOsc(
                            osc,
                            limitExceeded: oscLimitExceeded,
                            terminator: .c1StringTerminator,
                            terminal)
                        endStringSequence(
                            osc: &osc,
                            oscLimitExceeded: &oscLimitExceeded,
                            apc: &apc,
                            apcLimitExceeded: &apcLimitExceeded,
                            pars: &pars,
                            parsColonMask: &parsColonMask,
                            collect: &collect,
                            parameterLimitExceeded: &parameterLimitExceeded,
                            dcs: &dcs,
                            terminal)
                        transition = (transition & 0xf0) | ParserState.ground.rawValue
                    }
                }
                // Let the transition table process the boundary byte. This
                // keeps OSC and APC behavior independent of input chunking.
                // A C1 ST is the one boundary this action handles itself.
                consumed = c1Terminated ? j - i + 1 : j - i
            case .oscEnd:
                if currentState == ParserState.apcString.rawValue {
                    if !apcLimitExceeded && apc.count != 0 && code != ControlCodes.CAN && code != ControlCodes.SUB {
                        let command = apc[apc.startIndex]
                        let content = apc.count > 1 ? apc[(apc.startIndex+1)...] : ArraySlice<UInt8>()
                        dispatchApc(command: command, content: content, terminal)
                    }
                } else {
                    if code != ControlCodes.CAN && code != ControlCodes.SUB {
                        dispatchAccumulatedOsc(
                            osc,
                            limitExceeded: oscLimitExceeded,
                            terminator: code == ControlCodes.BEL ? .bell : .stringTerminator,
                            terminal)
                    }
                }
                if code == 0x1b {
                    transition |= ParserState.escape.rawValue
                }
                EscapeSequenceParser.resetOsc (&osc, &oscLimitExceeded)
                EscapeSequenceParser.resetApc (&apc, &apcLimitExceeded)
                if pars.isEmpty {
                    pars.append (0)
                } else {
                    if pars.count > 1 { pars.removeLast (pars.count - 1) }
                    pars [0] = 0
                }
                parsColonMask = 0
                if !collect.isEmpty { collect.removeAll (keepingCapacity: true) }
                parameterLimitExceeded = false
                dcs = -1
                terminal.printStateReset()
            case .reserved:
                break
            }
            currentState = transition & 15
            input = input.extracting(droppingFirst: consumed)
            i += consumed
        }
        // push leftover pushable buffers to terminal
        if currentState == ParserState.ground.rawValue && (~print != 0) {
            terminal.handlePrintBorrowed(data.extracting(print..<end))
        } else if currentState == ParserState.dcsPassthrough.rawValue && (~dcs != 0) && dcsHandler != nil {
            dcsHandler!.put(data: ownedSlice(dcs..<end))
        }
        if didResetDuringParse && resetSerial != resetSerialAtStart {
            if parseDepth == 1 {
                didResetDuringParse = false
            }
            return
        }

        // save non pushable buffers
        _osc = osc
        _oscLimitExceeded = oscLimitExceeded
        _apc = apc
        _apcLimitExceeded = apcLimitExceeded
        _collect = collect
        _pars = pars
        _parsColonMask = parsColonMask
        _parameterLimitExceeded = parameterLimitExceeded
        
        // save active dcs handler reference
        activeDcsHandler = dcsHandler
        
        // save state
        
        self.currentState = ParserState (rawValue: currentState)!
        
    }
    
    /// Parses a complete decimal value, rejecting malformed input and integer overflow.
    static func parseDecimal (_ str: ArraySlice<UInt8>) -> Int?
    {
        guard !str.isEmpty else { return nil }

        var result = 0
        for x in str {
            guard x >= 48 && x <= 57 else { return nil }

            let digit = Int(x - 48)
            guard result <= (Int.max - digit) / 10 else {
                return nil
            }
            result = result * 10 + digit
        }
        return result
    }
}
