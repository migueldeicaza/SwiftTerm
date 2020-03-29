//
//  Terminal.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/27/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//
// TODO: review every place that sets cursor to use setCursor
// TODO: audit every location to use restrictCursor

import Foundation

/**
 * The terminal delegate is a protocol that must be implemented by a class
 * that would provide a user interface for the terminal, and it is used by the
 * `Terminal` to notify of important changes on the underlying terminal
 */
public protocol TerminalDelegate {
    
    func showCursor (source: Terminal)
    
    /**
     * This method is invoked when the terminal needs to set the title for the window,
     * a UI toolkit would react by setting the terminal title in the window or any other
     * user visible element
     */
    func setTerminalTitle (source: Terminal, title: String)

    /**
     * This method is invoked when the terminal needs to set the title for the minimized icon,
     * a UI toolkit would react by setting the terminal title in the icon or any other
     * user visible element
     */
    func setTerminalIconTitle (source: Terminal, title: String)

    /**
     * These are various commands that are sent by the client.  They are rare,
     * and if you do not know what to return, just return nil, the terminal
     * will return a suitable value.
     *
     * The response string needs to be suitable for the Xterm CSI Ps ; Ps ; Ps t command
     * see the WindowManipulationCommand enumeration for those that need to return values
     */
    @discardableResult
    func windowCommand (source: Terminal, command: Terminal.WindowManipulationCommand) -> String?
    
    /**
     * This method is invoked when the terminal dimensions have changed in response
     * to an escape sequence that triggers a terminal resize, the user interface toolkit
     * should attempt to accomodate the new window size
     *
     * TODO: This is not wired up
     */
    func sizeChanged (source: Terminal)
    
    /**
     * Sends the byte data to the client.
     */
    func send (source: Terminal, data: ArraySlice<UInt8>)
    
    // callbacks
    
    // Callback - the window was scrolled, new yDisplay passed
    func scrolled (source: Terminal, yDisp: Int)
    
    // callback a newline was generated
    func linefeed (source: Terminal)
    
    // This method is invoked when the buffer changes from Normal to Alternate, or Alternate to Normal
    func bufferActivated (source: Terminal)
    
    // Should raise the bell
    func bell (source: Terminal)
    
    /**
     * This is invoked when the selection has changed, or has been turned on.   The status is
     * available in `terminal.selection.active`, and the range relative to the buffer is
     * in `terminal.selection.start` and `terminal.selection.end`
     */
    func selectionChanged (source: Terminal)
    
    /**
     * This method should return `true` if operations that can read the buffer back should be allowed,
     * otherwise, return false.   This is useful to run some applications that attempt to checksum the
     * contents of the screen (unit tests)
     */
    func isProcessTrusted () -> Bool
}

/**
 * The `Terminal` class provides the terminal emulation engine, and can be used to feed data to the
 * terminal emulator.   Typically users will intereact with a higher-level implementation that provides a
 * UI toolkit-specific rendering and connects the input to the UI toolkit.
 *
 * A front-end would draw the contents of the terminal, and take input from the user, which is in turn
 * either mapped to one of the public APIs here, or if it is user input is passed to the `feed`  methods here.
 *
 * The terminal is also connected to a backend that is conneted to the client, and data from this
 * client is fed into the emulator by calling the `sendResponse method`
 *
 * The behavior of the terminal is configured by implementing the `TerminalDelegate` protocol
 * that is provided in the constructor call.
 */
public class Terminal {
    let MINIMUM_COLS = 2
    let MINIMUM_ROWS = 1
    
    // Options
    var cols : Int = 80
    var rows : Int = 25
    var tabStopWidth : Int = 8
    var options: TerminalOptions = TerminalOptions()
    
    // The current buffers
    var buffers : BufferSet!
    
    // Whether the terminal is operating in application keypad mode
    var applicationKeypad : Bool = false
    // Whether the terminal is operating in application cursor mode
    var applicationCursor : Bool = false
    
    // You can ignore most of the defaults set here, the function
    // reset() will do that again
    var sendFocus: Bool = false
    var cursorHidden : Bool = false
    
    /// Controls the origin mode (DECOM), when set, the screen is limited to the top and bottom margins
    var originMode: Bool = false
    
    /// Controls whether it is possible to set left and right margin modes
    var marginMode: Bool = false
    
    /// Saved state for the origin mode
    var savedOriginMode : Bool = false
    var savedMarginMode: Bool = false
    
    public var insertMode : Bool = false
    var bracketedPasteMode : Bool = false
    public var charset : [UInt8:String]? = nil
    var gcharset : Int = 0
    public var wraparound : Bool = false
    var savedWraparound : Bool = false
    public var reverseWraparound: Bool = false
    var savedReverseWraparound: Bool = false
    var tdel : TerminalDelegate
    var curAttr : Int32 = CharData.defaultAttr
    var gLevel: UInt8 = 0
    
    var parser : EscapeSequenceParser
    var x10Mouse: Bool = false
    var utfMouse: Bool = false
    var vt200Mouse: Bool = false
    
    /// If set, this instructs the terminal to send 8-bit control sequences instead of 7-bit sequences (S8C1T vs S7C1T)
    var mouseEvents = false
    var mouseSendsRelease = false
    var mouseSendsAllMotion = false
    var mouseSendsWheel = false
    var mouseSendsModifiers = false
    var mouseSendsMotionWhenPressed = false
    var sgrMouse = false
    var urxvtMouse = false

    var refreshStart = Int.max
    var refreshEnd = -1
    var userScrolling = false
    
    // These are described in user coordinates (1..80 for example, rather than 0..79)
    var marginLeft: Int = 1
    var marginRight: Int = 1
    
    static let defaultColor: Int32 = 256
    static let defaultInvertedColor: Int32 = 257
    
    // Control codes provides an API to send either 8bit sequences or 7bit sequences for C0 and C1 depending on the terminal state
    var cc: CC
    
    public func getDims () -> (cols: Int,rows: Int)
    {
        return (cols, rows)
    }
    
    public init (delegate : TerminalDelegate, options: TerminalOptions? = nil)
    {
        tdel = delegate
        self.options = options ?? TerminalOptions ()
        // This duplicates the setup above, but
        parser = EscapeSequenceParser ()
        cc = CC(send8bit: false)
        configureParser (parser)
        setup ()
    }
    
    /**
     * Returns the active buffer (either the normal buffer or the alternative buffer)
     */
    var buffer: Buffer {
        get {
            buffers!.active
        }
    }
    
    func setup ()
    {
        // Sadly a duplicate of much of what lives in init() due to Swift not allowing me to
        // call this
        cols = max (options.cols, MINIMUM_COLS)
        rows = max (options.rows, MINIMUM_ROWS)
        buffers = BufferSet(self)
        cursorHidden = false
        
        // modes
        applicationKeypad = false
        applicationCursor = false
        originMode = false
        marginMode = false
        insertMode = false
        wraparound = true
        bracketedPasteMode = false
        
        // charset'
        charset = nil
        gcharset = 0
        gLevel = 0
        curAttr = CharData.defaultAttr
        
        // Mouse
        mouseEvents = false

        mouseSendsRelease = false
        mouseSendsAllMotion = false
        mouseSendsWheel = false
        mouseSendsModifiers = false
        mouseSendsMotionWhenPressed = false
        
        sgrMouse = false
        urxvtMouse = false
        marginLeft = 1
        marginRight = cols
        
        cc.send8bit = false
    }
    
    // DCS $ q Pt ST
    // DECRQSS (https://vt100.net/docs/vt510-rm/DECRQSS.html)
    //   Request Status String (DECRQSS), VT420 and up.
    // Response: DECRPSS (https://vt100.net/docs/vt510-rm/DECRPSS.html)
    class DECRQSS : DcsHandler {
        var data: [UInt8]
        var terminal: Terminal

        public init (terminal: Terminal)
        {
            self.terminal = terminal
            data = []
        }

        func hook (collect: cstring, parameters: [Int],  flag: UInt8)
        {
            data = []
        }
        
        func put (data : ArraySlice<UInt8>)
        {
            for x in data {
                self.data.append(x)
            }
        }
        
        func unhook ()
        {
            let newData = String (bytes: data, encoding: .ascii)
            
            switch (newData) {
            case "\"q": // DECCSA - Set Character Attribute
                terminal.sendResponse("\(terminal.cc.DCS)1$r0\"q$\(terminal.cc.ST)")
            case "\"p": // DECSCL - conformance level
                terminal.sendResponse ("\(terminal.cc.DCS)1$r61\"p$\(terminal.cc.ST)")
            case "r": // DECSTBM - the top and bottom margins
                terminal.sendResponse ("\(terminal.cc.DCS)1$r$\(terminal.buffer.scrollTop + 1);\(terminal.buffer.scrollBottom + 1)r\(terminal.cc.ST)")
            case "m": // SGR - the set graphic rendition
                // TODO: report real settings instead of 0m
                terminal.sendResponse ("\(terminal.cc.DCS)1$r0m$\(terminal.cc.ST)")
            case " q": // DECSCUSR - the set cursor style
                // TODO this should send a number for the current cursor style 2 for block, 4 for underline and 6 for bar
                let style = "2" // block
                terminal.sendResponse ("\(terminal.cc.DCS)1$r$\(style) q$\(terminal.cc.ST)")
            default:
                // invalid: DCS 0 $ r Pt ST (xterm)
                terminal.error ("Unknown DCS + \(newData!)")
                terminal.sendResponse ("\(terminal.cc.DCS)0$r$\(terminal.cc.ST)")

            }
        }
    }

    // Configures the EscapeSequenceParser
    func configureParser (_ parser: EscapeSequenceParser)
    {
        parser.csiHandlerFallback = { (pars: [Int], collect: cstring, code: UInt8) -> () in
            let ch = Character(UnicodeScalar(code))
            self.error ("Unknown CSI Code (collect=\(collect) code=\(ch) pars=\(pars))")
        }
        parser.escHandlerFallback = { (txt: cstring, flag: UInt8) in
            self.error ("Unknown ESC Code: ESC + \(Character(Unicode.Scalar (flag))) txt=\(txt)")
        }
        parser.executeHandlerFallback = {
            self.error ("Unknown EXECUTE code")
        }
        parser.oscHandlerFallback = { (code: Int) in
            self.error ("Unknown OSC code: \(code)")
        }
        parser.printHandler = handlePrint
        parser.printStateReset = printStateReset
        
        // CSI handler
        parser.csiHandlers [0x40 /* @ */] = cmdInsertChars
        parser.csiHandlers [0x41 /* A */] = cmdCursorUp
        parser.csiHandlers [0x42 /* B */] = cmdCursorDown
        parser.csiHandlers [0x43 /* C */] = cmdCursorForward
        parser.csiHandlers [0x44 /* D */] = cmdCursorBackward
        parser.csiHandlers [0x45 /* E */] = cmdCursorNextLine
        parser.csiHandlers [0x46 /* F */] = cmdCursorPrecedingLine
        parser.csiHandlers [0x47 /* G */] = cmdCursorCharAbsolute
        parser.csiHandlers [0x48 /* H */] = cmdCursorPosition
        parser.csiHandlers [0x49 /* I */] = cmdCursorForwardTab
        parser.csiHandlers [0x4a /* J */] = cmdEraseInDisplay
        parser.csiHandlers [0x4b /* K */] = cmdEraseInLine
        parser.csiHandlers [0x4c /* L */] = cmdInsertLines
        parser.csiHandlers [0x4d /* M */] = cmdDeleteLines
        parser.csiHandlers [0x50 /* P */] = cmdDeleteChars
        parser.csiHandlers [0x53 /* S */] = cmdScrollUp
        parser.csiHandlers [0x54 /* T */] = cmdScrollDown
        parser.csiHandlers [0x58 /* X */] = cmdEraseChars
        parser.csiHandlers [0x5a /* Z */] = cmdCursorBackwardTab
        parser.csiHandlers [0x60 /* ` */] = cmdCharPosAbsolute
        parser.csiHandlers [0x61 /* a */] = cmdHPositionRelative
        parser.csiHandlers [0x62 /* b */] = cmdRepeatPrecedingCharacter
        parser.csiHandlers [0x63 /* c */] = cmdSendDeviceAttributes
        parser.csiHandlers [0x64 /* d */] = cmdLinePosAbsolute
        parser.csiHandlers [0x65 /* e */] = cmdVPositionRelative
        parser.csiHandlers [0x66 /* f */] = cmdHVPosition
        parser.csiHandlers [0x67 /* g */] = cmdTabClear
        parser.csiHandlers [0x68 /* h */] = cmdSetMode
        parser.csiHandlers [0x6c /* l */] = cmdResetMode
        parser.csiHandlers [0x6d /* m */] = cmdCharAttributes
        parser.csiHandlers [0x6e /* n */] = cmdDeviceStatus
        parser.csiHandlers [0x70 /* p */] = cmdSoftReset
        parser.csiHandlers [0x71 /* q */] = cmdSetCursorStyle
        parser.csiHandlers [0x72 /* r */] = cmdSetScrollRegion
        parser.csiHandlers [0x73 /* s */] = { args, cstring in
            // "CSI s" is overloaded, can mean save cursor, but also set the margins with DECSLRM
            if self.marginMode {
                self.cmdSetMargins (args, cstring)
            } else {
                self.cmdSaveCursor (args, cstring)
            }
        }
        parser.csiHandlers [0x74 /* t */] = cmdWindowOptions
        parser.csiHandlers [0x75 /* u */] = cmdRestoreCursor
        parser.csiHandlers [0x76 /* v */] = csiCopyRectangularArea
        parser.csiHandlers [0x78 /* x */] = csiX                    /* x DECFRA - could be overloaded */
        parser.csiHandlers [0x79 /* y */] = cmdDECRQCRA             /* y - Checksum Region */
        parser.csiHandlers [0x7a /* z */] = cmdEraseRectangularArea /* DECERA */
        parser.csiHandlers [0x7b /* { */] = cmdSelectiveEraseRectangularArea /* DECSERA */
        parser.csiHandlers [0x7e /* ~ */] = cmdDeleteColumns

        parser.executeHandlers [7]  = { self.tdel.bell (source: self) }
        parser.executeHandlers [10] = cmdLineFeed
        parser.executeHandlers [11] = cmdLineFeedBasic   // VT Vertical Tab - ignores auto-new-line behavior in ConvertEOL
        parser.executeHandlers [12] = cmdLineFeedBasic
        parser.executeHandlers [13] = cmdCarriageReturn
        parser.executeHandlers [8]  = cmdBackspace
        parser.executeHandlers [9]  = cmdTab
        parser.executeHandlers [14] = cmdShiftOut
        parser.executeHandlers [15] = cmdShiftIn
        
        parser.executeHandlers [0x84] = cmdIndex
        parser.executeHandlers [0x85] = cmdNextLine
        parser.executeHandlers [0x88] = cmdTabSet

        //
        // OSC handler
        //
        //   0 - icon name + title
        parser.oscHandlers [0] = { data in self.tdel.setTerminalTitle(source: self, title: String (bytes: data, encoding: .utf8) ?? "")}
        //   1 - icon name
        //   2 - title
        parser.oscHandlers [2] = { data in self.tdel.setTerminalTitle(source: self, title: String (bytes: data, encoding: .utf8) ?? "")}
        //   3 - set property X in the form "prop=value"
        //   4 - Change Color Number()
        //   5 - Change Special Color Number
        //   6 - Enable/disable Special Color Number c
        //   7 - current directory? (not in xterm spec, see https://gitlab.com/gnachman/iterm2/issues/3939)
        //  10 - Change VT100 text foreground color to Pt.
        parser.oscHandlers [10] = oscSetTextForeground
        //  11 - Change VT100 text background color to Pt.
        parser.oscHandlers [11] = oscSetTextBackground
        //  12 - Change text cursor color to Pt.
        //  13 - Change mouse foreground color to Pt.
        //  14 - Change mouse background color to Pt.
        //  15 - Change Tektronix foreground color to Pt.
        //  16 - Change Tektronix background color to Pt.
        //  17 - Change highlight background color to Pt.
        //  18 - Change Tektronix cursor color to Pt.
        //  19 - Change highlight foreground color to Pt.
        //  46 - Change Log File to Pt.
        //  50 - Set Font to Pt.
        //  51 - reserved for Emacs shell.
        //  52 - Manipulate Selection Data.
        // 104 ; c - Reset Color Number c.
        parser.oscHandlers [104] = oscResetColor
        
        // 105 ; c - Reset Special Color Number c.
        // 106 ; c; f - Enable/disable Special Color Number c.
        // 110 - Reset VT100 text foreground color.
        // 111 - Reset VT100 text background color.
        // 112 - Reset text cursor color.
        // 113 - Reset mouse foreground color.
        // 114 - Reset mouse background color.
        // 115 - Reset Tektronix foreground color.
        // 116 - Reset Tektronix background color.

        //
        // ESC handlers
        //
        parser.setEscHandler ("7",  { collect, flag in self.cmdSaveCursor ([], []) })
        parser.setEscHandler ("8",  { collect, flag in self.cmdRestoreCursor ([], []) })
        parser.setEscHandler ("D",  { collect, flag in self.cmdIndex() })
        parser.setEscHandler ("E",  { collect, flag in self.cmdNextLine () })
        parser.setEscHandler ("H",  { collect, flag in self.cmdTabSet ()})
        parser.setEscHandler ("M",  { collect, flag in self.reverseIndex() })
        parser.setEscHandler ("=",  { collect, flags in self.cmdKeypadApplicationMode ()})
        parser.setEscHandler (">",  { collect, flags in self.cmdKeypadNumericMode ()})
        parser.setEscHandler ("c",  { collect, flags in self.cmdReset () })
        parser.setEscHandler ("n",  { collect, flag in self.setgLevel (2) })
        parser.setEscHandler ("o",  { collect, flag in self.setgLevel (3) })
        parser.setEscHandler ("|",  { collect, flag in self.setgLevel (3) })
        parser.setEscHandler ("}",  { collect, flag in self.setgLevel (2) })
        parser.setEscHandler ("~",  { collect, flag in self.setgLevel (1) })
        parser.setEscHandler ("%@", { collect, flag in self.cmdSelectDefaultCharset () })
        parser.setEscHandler ("%G", { collect, flag in self.cmdSelectDefaultCharset () })
        parser.setEscHandler ("#8", { collect, flag in self.cmdScreenAlignmentPattern () })
        parser.setEscHandler (" G") { collect, flags in self.cmdSet8BitControls () }
        parser.setEscHandler (" F") { collect, flags in self.cmdSet7BitControls () }
        for bflag in CharSets.all.keys {
            let flag = String (UnicodeScalar (bflag))
            
            parser.setEscHandler ("(" + flag, { code, f in self.selectCharset ([0x28] + [f]) })
            parser.setEscHandler (")" + flag, { code, f in self.selectCharset ([0x29] + [f]) })
            parser.setEscHandler ("*" + flag, { code, f in self.selectCharset ([0x2a] + [f]) })
            parser.setEscHandler ("+" + flag, { code, f in self.selectCharset ([0x2b] + [f]) })
            parser.setEscHandler ("-" + flag, { code, f in self.selectCharset ([0x2d] + [f]) })
            parser.setEscHandler ("." + flag, { code, f in self.selectCharset ([0x2e] + [f]) })
            parser.setEscHandler ("/" + flag, { code, f in self.selectCharset ([0x2f] + [f]) })
        }

        // Error handler
        parser.errorHandler = { state in
            self.error ("Parsing error, state: \(state)")
            return state
        }

        // DCS Handler
        parser.setDcsHandler ("$q", DECRQSS (terminal: self))
    }
    
    func cmdSet8BitControls ()
    {
        cc.send8bit = true
    }

    func cmdSet7BitControls ()
    {
        cc.send8bit = false
    }

    func emitScroll (_ x: Int)
    {
        // In the original code, it is mediocre accessibility, so likely will remove this
    }
    
    func emitChar (_ ch: Character)
    {
        // In the original code, it is mediocre accessibility, so likely will remove this
    }

    //
    // Because data might not be complete, we need to put back data that we read to process on
    // a future read.  To prepare for reading, on every call to parse, the prepare method is
    // given the new ArraySlice to read from.
    //
    // the `hasNext` describes whether there is more data left on the buffer, and `bytesLeft`
    // returnes the number of bytes left.   The `getNext` method fetches either the next
    // value from the putback buffer, or when it is empty, it returns it from the buffer that
    // was passed during prepare.
    //
    // Additionally, the terminal parser needs to reset the parser state on demand, and
    // that is surfaced via reset
    //
    struct ReadingBuffer {
        var putbackBuffer: [UInt8] = []
        var rest:ArraySlice<UInt8> = [][...]
        var idx = 0
        var count:Int = 0
        
        // Invoke this method at the beginnign of parse
        mutating func prepare (_ data: ArraySlice<UInt8>)
        {
            assert (rest.count == 0)
            rest = data
            count = putbackBuffer.count + data.count
            idx = 0
        }
        
        func hasNext () -> Bool {
            idx < count
        }
        
        func bytesLeft () -> Int
        {
            count-idx
        }
        
        mutating func getNext () -> UInt8
        {
            if idx < putbackBuffer.count {
                let v = putbackBuffer [idx]
                idx += 1
                return v
            }
            let v = rest [idx-putbackBuffer.count+rest.startIndex]
            idx += 1
            return v
        }
        
        // Puts back the code, and everything that was pending
        mutating func putback (_ code: UInt8)
        {
            var newPutback: [UInt8] = [code]
            let left = bytesLeft()
            for _ in 0..<left {
                newPutback.append (getNext ())
            }
            putbackBuffer = newPutback
            rest = [][...]
        }
        
        mutating func done  ()
        {
            if idx < putbackBuffer.count {
                putbackBuffer.removeFirst(idx)
            } else {
                putbackBuffer = []
            }
            rest = [][...]
        }
        
        mutating func reset ()
        {
            putbackBuffer = []
            idx = 0
        }
    }
    
    var readingBuffer = ReadingBuffer ()
    
    func printStateReset ()
    {
        readingBuffer.reset ()
    }
    
    func handlePrint (_ data: ArraySlice<UInt8>)
    {
        readingBuffer.prepare(data)
        let screenReaderMode = options.screenReaderMode
        var bufferRow = buffer.lines [buffer.y + buffer.yBase]

        updateRange (buffer.y)
        while readingBuffer.hasNext() {
            var ch: Character = " "
            var chWidth: Int = 0
            let code = readingBuffer.getNext()
            
            let n = UnicodeUtil.expectedSizeFromFirstByte(code)

            if n == -1 || n == 1 {
                // n == -1 means an Invalid UTF-8 sequence, client sent us some junk, happens if we run
                // with the wrong locale set for example if LANG=en, still we handle it here

                // get charset replacement character
                // charset are only defined for ASCII, therefore we only
                // search for an replacement char if code < 127
                var chSet = false
                if code < 127 && charset != nil {
                    
                    // Notice that the charset mapping can contain the dutch unicode sequence for "ij",
                    // so it is not a simple byte, it is a Character
                    if let str = charset! [UInt8 (code)] {
                        ch = str.first!
                        
                        // Every single mapping in the charset only takes one slot
                        chWidth = 1
                        chSet = true
                    }
                }
                
                if chSet == false {
                    let rune = UnicodeScalar (code)
                    chWidth = UnicodeUtil.columnWidth(rune: rune)
                    ch = Character (rune)
                }
            } else if readingBuffer.bytesLeft() >= (n-1) {
                var x : [UInt8] = [code]
                for _ in 1..<n {
                    x.append (readingBuffer.getNext())
                }
                x.withUnsafeBytes { ptr in
                    let unsafeBound = ptr.bindMemory(to: UInt8.self)
                    let unsafePointer = unsafeBound.baseAddress!
                    
                    let s = String (cString: unsafePointer)
                    ch = s.first ?? Character (" ")

                    // Now the challenge is that we have a character, not a rune, and we want to compute
                    // the width of it.
                    if ch.unicodeScalars.count == 1 {
                        chWidth = UnicodeUtil.columnWidth(rune: ch.unicodeScalars.first!)
                    } else {
                        chWidth = 0
                        for scalar in ch.unicodeScalars {
                            chWidth = max (chWidth, UnicodeUtil.columnWidth(rune: scalar))
                        }
                    }
                }
            } else {
                readingBuffer.putback (code)
                return
            }

            // There are two problems with the set of assignments below.
            // The input stream are bytes, and we have at this point enough data to assemble
            // a UnicodeScalar if we are lucky (data might still be missing and might come in the
            // next batch).
            //
            // The current code does not cope with this, I will need to preserve that state and resume
            // the assembly process of the UnicodeScalar, this will require to redo this function.   In
            // addition, even if we have UnicodeScalars, this code now needs to assemble higher-level
            // Character() values that might be made up of multiple unicode scalars, and only then, emit
            // the displayed character.
            //
            // To get this off the ground, none of these operations are done.   Notice that neither
            // the JS or C# implementations solve this yet.
            if screenReaderMode {
                emitChar (ch)
            }

            // insert combining char at last cursor position
            // FIXME: needs handling after cursor jumps
            // buffer.x should never be 0 for a combining char
            // since they always follow a cell consuming char
            // therefore we can test for buffer.x to avoid overflow left
            if chWidth == 0 && buffer.x > 0 {
                // MIGUEL TODO: in the original code the getter might return a null value
                // does this mean that JS returns null for out of bounsd?
                if buffer.x >= 1 && buffer.x < bufferRow.count {
                    var chMinusOne = bufferRow [buffer.x - 1]
                    if chMinusOne.width == 0 {
                        // found empty cell after fullwidth, need to go 2 cells back
                        // it is save to step 2 cells back here
                        // since an empty cell is only set by fullwidth chars
                        if buffer.x >= 2 {
                            var chMinusTwo = bufferRow [buffer.x - 2]

                            // TODO: I added size as 1, but need to validate this later
                            chMinusTwo.setValue(char: ch, size: 1)
                            bufferRow [buffer.x - 2] = chMinusTwo // must be set explicitly now
                        }
                    } else {
                        chMinusOne.setValue(char: ch, size: Int32 (chMinusOne.width))
                        bufferRow [buffer.x - 1] = chMinusOne // must be set explicitly now
                    }
                }
                continue
            }

            // goto next line if ch would overflow
            // TODO: needs a global min terminal width of 2
            // FIXME: additionally ensure chWidth fits into a line
            //   -->  maybe forbid cols<xy at higher level as it would
            //        introduce a bad runtime penalty here
            if buffer.x + chWidth - 1 >= cols {
                // autowrap - DECAWM
                // automatically wraps to the beginning of the next line
                if wraparound {
                    buffer.x = 0

                    if buffer.y >= buffer.scrollBottom {
                        scroll (isWrapped: true)
                    } else {
                        // The line already exists (eg. the initial viewport), mark it as a
                        // wrapped line
                        buffer.y += 1
                        buffer.lines [buffer.y].isWrapped = true
                    }
                    // row changed, get it again
                    bufferRow = buffer.lines [buffer.y + buffer.yBase]
                } else {
                    if (chWidth == 2) {
                        // FIXME: check for xterm behavior
                        // What to do here? We got a wide char that does not fit into last cell
                        continue;
                    }
                    // FIXME: Do we have to set buffer.x to cols - 1, if not wrapping?
                    buffer.x = cols - 1;
                }
            }

            var empty = CharData.Null
            empty.attribute = curAttr
            // insert mode: move characters to right
            if insertMode {
                // right shift cells according to the width
                bufferRow.insertCells (pos: buffer.x, n: chWidth, fillData: empty)
                // test last cell - since the last cell has only room for
                // a halfwidth char any fullwidth shifted there is lost
                // and will be set to eraseChar
                let lastCell = bufferRow [cols - 1]
                if lastCell.width == 2 {
                    bufferRow [cols - 1] = empty
                }
            }

            // write current char to buffer and advance cursor
            let charData = CharData (attribute: curAttr, char: ch, size: Int8 (chWidth))
            bufferRow [buffer.x] = charData
            buffer.x += 1

            // fullwidth char - also set next cell to placeholder stub and advance cursor
            // for graphemes bigger than fullwidth we can simply loop to zero
            // we already made sure above, that buffer.x + chWidth will not overflow right
            if chWidth > 0 {
                chWidth -= 1
                while chWidth != 0 {
                    bufferRow [buffer.x] = empty
                    buffer.x += 1
                    chWidth -= 1
                }
            }
        }
        updateRange (buffer.y)
        readingBuffer.done ()
    }

    func cmdLineFeed ()
    {
        if options.convertEol {
            buffer.x = 0
        }
        cmdLineFeedBasic ()
    }
    
    func cmdLineFeedBasic ()
    {
        let by = buffer.y
        
        // If we are inside the scroll region, or we hit the last row of the display
        if by == buffer.scrollBottom || by == rows - 1 {
                scroll(isWrapped: false)
        } else {
                buffer.y = by + 1
        }
        
        // If the end of the line is hit, prevent this action from wrapping around to the next line.
        if buffer.x >= cols {
            buffer.x -= 1
        }
        
        // This event is emitted whenever the terminal outputs a LF or NL.
        emitLineFeed()
    }
    
    //
    // Backspace handler (Control-h)
    //
    func cmdBackspace ()
    {
        let buffer = self.buffer
        restrictCursor(!reverseWraparound)
        if buffer.x > 0 {
            buffer.x -= 1
        } else if reverseWraparound {
            print ("Reverse with buffer.x == \(buffer.x) \(buffer.y) \(buffer.scrollTop) \(buffer.scrollBottom)")
            if buffer.x == 0 {
                if buffer.y > buffer.scrollTop && buffer.y <= buffer.scrollBottom && buffer.lines [buffer.y + buffer.yBase].isWrapped {
                    buffer.lines [buffer.y + buffer.yBase].isWrapped = false
                    
                    buffer.y -= 1
                    buffer.x = buffer.cols - 1
                // TODO: find actual last cell based on width used
                } else if buffer.y == buffer.scrollTop {
                    buffer.x = buffer.cols - 1
                    buffer.y = buffer.scrollBottom
                }
            }
        }
    }
    
    func cmdCarriageReturn ()
    {
        buffer.x = 0
    }
    
    //
    // Horizontal tab (control-i)
    //
    func cmdTab ()
    {
        buffer.x = buffer.nextTabStop ()
    }

    // SO
    // ShiftOut (Control-N) Switch to alternate character set.  This invokes the G1 character set
    func cmdShiftOut ()
    {
        setgLevel (1)
    }
    
    // SI
    // ShiftIn (Control-O) Switch to standard character set.  This invokes the G0 character set
    func cmdShiftIn ()
    {
        setgLevel(0)
    }
    
    // Operating System Commands (OSC)
    
    func resetAllColors ()
    {
        // Nothing to do today, as we do not allow color changing
    }
    
    func resetColor (_ number: Int)
    {
        // Nothing to do today as we do not allow color changing
    }
    
    func oscResetColor (_ data: ArraySlice<UInt8>)
    {
        let str = String (bytes:data, encoding: .ascii) ?? ""
        log ("Attempt to reset color definitions \(str)")
        if let param = String (bytes: data, encoding: .ascii) {
            let colors = param.split(separator: ";")
            for color in colors {
                resetColor (Int (color) ?? 0)
            }
        } else {
            resetAllColors ()
        }
    }
    
    func oscSetTextForeground (_ data: ArraySlice<UInt8>)
    {
        let str = String (bytes:data, encoding: .ascii) ?? ""
        log ("Attempt to set the text Foreground color \(str)")
        // Nothing to do now
    }

    func oscSetTextBackground (_ data: ArraySlice<UInt8>)
    {
        let str = String (bytes:data, encoding: .ascii) ?? ""
        log ("Attempt to set the text Background color \(str)")
        // Nothing to do now
    }

    //
    // ESC E
    // C1.NEL
    //   DEC mnemonic: NEL (https://vt100.net/docs/vt510-rm/NEL)
    //   Moves cursor to first position on next line.
    //
    func cmdNextLine ()
    {
            buffer.x = 0
            cmdIndex ()
    }

    /**
     * ESC H
     * C1.HTS
     *   DEC mnemonic: HTS (https://vt100.net/docs/vt510-rm/HTS.html)
     *   Sets a horizontal tab stop at the column position indicated by
     *   the value of the active column when the terminal receives an HTS.
     *
     * @vt: #Y   C1    HTS   "Horizontal Tabulation Set" "\x88"    "Places a tab stop at the current cursor position."
     * @vt: #Y   ESC   HTS   "Horizontal Tabulation Set" "ESC H"   "Places a tab stop at the current cursor position."
     */
    func cmdTabSet ()
    {
        buffer.tabSet (pos: buffer.x)
    }
    
    //
    // CSI Ps @
    // Insert Ps (Blank) Character(s) (default = 1) (ICH).
    //
    func cmdInsertChars (_ pars: [Int], _ collect: cstring)
    {
        restrictCursor()
        let cd = CharData (attribute: eraseAttr ())

        buffer.lines [buffer.y + buffer.yBase].insertCells (pos: buffer.x, n: pars.count > 0 ? pars [0] : 1, fillData: cd)

        updateRange (buffer.y)
    }
    
    //
    // CSI Ps A
    // Cursor Up Ps Times (default = 1) (CUU).
    //
    func cmdCursorUp (_ pars: [Int], _ collect: cstring)
    {
        let param = max (pars.count > 0 ? pars [0] : 1, 1)
        if (buffer.y - param < 0) {
            buffer.y = 0
        } else {
            buffer.y -= param
        }
    }
    
    //
    // CSI Ps B
    // Cursor Down Ps Times (default = 1) (CUD).
    //
    func cmdCursorDown (_ pars: [Int], _ collect: cstring)
    {
        let param = max (pars.count > 0 ? pars [0] : 1, 1)
        let newY = buffer.y + param

        // review
        //if (buffer.Y > buffer.ScrollBottom)
        //      buffer.Y = buffer.ScrollBottom - 1;
        if newY >= rows {
                buffer.y = rows - 1
        } else {
                buffer.y = newY
        }
        // If the end of the line is hit, prevent this action from wrapping around to the next line.
        if buffer.x >= cols {
                buffer.x -= 1
        }
    }
    
    //
    // CSI Ps B
    // Cursor Forward Ps Times (default = 1) (CUF).
    //
    func cmdCursorForward (_ pars: [Int], _ collect: cstring)
    {
        let param = max (pars.count > 0 ? pars [0] : 1, 1)
        buffer.x += param
        if buffer.x > cols {
            buffer.x = cols - 1
        }
    }

    //
    // CSI Ps D
    // Cursor Backward Ps Times (default = 1) (CUB).
    //
    func cmdCursorBackward (_ pars: [Int], _ collect: cstring)
    {
        let param = max (pars.count > 0 ? pars [0] : 1, 1)

        // If the end of the line is hit, prevent this action from wrapping around to the next line.
        if buffer.x >= cols {
                buffer.x -= 1
        }
        buffer.x -= param
        if buffer.x < 0 {
                buffer.x = 0
        }
    }

    //
    // CSI Ps I
    //   Cursor Forward Tabulation Ps tab stops (default = 1) (CHT).
    //
    func cmdCursorForwardTab (_ pars: [Int], _ collect: cstring)
    {
        let param = max (pars.count > 0 ? pars [0] : 1, 1)
        for _ in 0..<param {
            buffer.x = buffer.nextTabStop ()
        }
    }
    
    /**
     * Restrict cursor to viewport size / scroll margin (origin mode)
     * - Parameter limitCols: by default it is true, but the reverseWraparound mechanism in Backspace needs `x` to go beyond.
     */
    func restrictCursor(_ limitCols: Bool = true)
    {
        buffer.x = min (cols - (limitCols ? 1 : 0), max (0, buffer.x))
        buffer.y = originMode
            ? min (buffer.scrollBottom, max (buffer.scrollTop, buffer.y))
            : min (rows - 1, max (0, buffer.y))
        
        updateRange(buffer.y)
    }

    //
    // CSI Ps ; Ps H
    // Cursor Position [row;column] (default = [1,1]) (CUP).
    //
    func cmdCursorPosition (_ pars: [Int], _ collect: cstring)
    {
        setCursor (col: pars.count >= 2 ? (pars [1]-1) : 0, row: pars [0] - 1)
    }
    
    func setCursor (col: Int, row: Int)
    {
        updateRange(buffer.y)
        if originMode {
            buffer.x = col
            buffer.y = buffer.scrollTop + row
        } else {
            buffer.x = col
            buffer.y = row
        }
        restrictCursor ()
    }

    //
    // CSI Ps E
    // Cursor Next Line Ps Times (default = 1) (CNL).
    // same as CSI Ps B?
    //
    func cmdCursorNextLine (_ pars: [Int], _ collect: cstring)
    {
        let param = max (pars.count > 0 ? pars [0] : 1, 1)
        let newY = buffer.y + param

        if newY >= rows {
            buffer.y = rows - 1
        } else {
            buffer.y = newY
        }
        buffer.x = 0
    }

    //
    // CSI Ps F
    // Cursor Preceding Line Ps Times (default = 1) (CNL).
    // reuse CSI Ps A ?
    //
    func cmdCursorPrecedingLine (_ pars: [Int], _ collect: cstring)
    {
        let param = max (pars.count > 0 ? pars [0] : 1, 1)

        buffer.y -= param
        let newY = buffer.y - param
        if newY < 0 {
                buffer.y = 0
        } else {
                buffer.y = newY
        }
        buffer.x = 0
    }

    //
    // CSI Ps G
    // Cursor Character Absolute  [column] (default = [row,1]) (CHA).
    //
    func cmdCursorCharAbsolute (_ pars: [Int], _ collect: cstring)
    {
            let param = max (pars.count > 0 ? pars [0] : 1, 1)

            buffer.x = param - 1
    }

    //
    // CSI Ps K  Erase in Line (EL).
    //     Ps = 0  -> Erase to Right (default).
    //     Ps = 1  -> Erase to Left.
    //     Ps = 2  -> Erase All.
    // CSI ? Ps K
    //   Erase in Line (DECSEL).
    //     Ps = 0  -> Selective Erase to Right (default).
    //     Ps = 1  -> Selective Erase to Left.
    //     Ps = 2  -> Selective Erase All.
    //
    func cmdEraseInLine (_ pars: [Int], _ collect: cstring)
    {
        let p = pars.count == 0 ? 0 : pars [0]
        
        switch p {
        case 0:
            eraseInBufferLine (y: buffer.y, start: buffer.x, end: cols)
        case 1:
            eraseInBufferLine (y: buffer.y, start: 0, end: buffer.x + 1)
        case 2:
            eraseInBufferLine (y: buffer.y, start: 0, end: cols)
        default:
            break
        }
        updateRange (buffer.y)
    }

    //
    // CSI Ps J  Erase in Display (ED).
    //     Ps = 0  -> Erase Below (default).
    //     Ps = 1  -> Erase Above.
    //     Ps = 2  -> Erase All.
    //     Ps = 3  -> Erase Saved Lines (xterm).
    // CSI ? Ps J
    //   Erase in Display (DECSED).
    //     Ps = 0  -> Selective Erase Below (default).
    //     Ps = 1  -> Selective Erase Above.
    //     Ps = 2  -> Selective Erase All.
    //
    func cmdEraseInDisplay (_ pars: [Int], _ collect: cstring)
    {
        let p = pars.count == 0 ? 0 : pars [0]
        var j: Int
        switch p {
        case 0:
            j = buffer.y
            updateRange (j)
            eraseInBufferLine (y: j, start: buffer.x, end: cols, clearWrap: buffer.x == 0)
            j += 1
            while j < rows {
                resetBufferLine (y: j)
                j += 1
            }
            updateRange (j - 1)
            
        case 1:
            j = buffer.y
            updateRange (j)
            // Deleted front part of line and everything before. This line will no longer be wrapped.
            eraseInBufferLine (y: j, start: 0, end: buffer.x + 1, clearWrap: true)
            if buffer.x + 1 >= cols {
                // Deleted entire previous line. This next line can no longer be wrapped.
                buffer.lines [j + 1].isWrapped = false
            }
            while (j != 0) {
                j -= 1
                resetBufferLine (y: j)
            }
            updateRange (0)
        case 2:
            j = rows
            updateRange (j - 1)
            while (j != 0) {
                j -= 1
                resetBufferLine (y: j)
            }
            updateRange (0)
        case 3:
            // Clear scrollback (everything not in viewport)
            let scrollBackSize = buffer.lines.count - rows
            if scrollBackSize > 0 {
                buffer.lines.trimStart (count: scrollBackSize);
                buffer.yBase = max (buffer.yBase - scrollBackSize, 0)
                buffer.lines.trimStart (count: scrollBackSize)
                buffer.yBase = max (buffer.yBase - scrollBackSize, 0)
                buffer.yDisp = max (buffer.yDisp - scrollBackSize, 0)
                // Force a scroll event to refresh viewport
                emitScroll (0)
            }
            break;
        default:
            break
        }
    }

    //
    // Helper method to erase cells in a terminal row.
    // The cell gets replaced with the eraseChar of the terminal.
    // - Parameter y: row index
    // - Parameter start: first cell index to be erased
    // - Parameter end:   end - 1 is last erased cell
    //
    func eraseInBufferLine (y: Int, start: Int, end: Int, clearWrap: Bool = false)
    {
        let line = buffer.lines [buffer.yBase + y]
        let cd = CharData (attribute: eraseAttr ())
        line.replaceCells (start: start, end: end, fillData: cd)
        if clearWrap {
            line.isWrapped = false
        }
    }
    
    //
    // CSI Ps L
    // Insert Ps Line(s) (default = 1) (IL).
    //
    func cmdInsertLines (_ pars: [Int], _ collect: cstring)
    {
        restrictCursor()
        var p = max (pars.count == 0 ? 1 : pars [0], 1)
        let row = buffer.y + buffer.yBase
        
        let scrollBottomRowsOffset = rows - 1 - buffer.scrollBottom
        let scrollBottomAbsolute = rows - 1 + buffer.yBase - scrollBottomRowsOffset + 1
        
        let ea = eraseAttr ()
        for _ in 0..<p {
            p -= 1
            // test: echo -e '\e[44m\e[1L\e[0m'
            // blankLine(true) - xterm/linux behavior
            buffer.lines.splice (start: scrollBottomAbsolute - 1, deleteCount: 1, items: [])
            let newLine = buffer.getBlankLine (attribute: ea)
            buffer.lines.splice (start: row, deleteCount: 0, items: [newLine])
        }
        
        // this.maxRange();
        updateRange (buffer.y)
        updateRange (buffer.scrollBottom)
    }
    
    //
    // ESC ( C
    //   Designate G0 Character Set, VT100, ISO 2022.
    // ESC ) C
    //   Designate G1 Character Set (ISO 2022, VT100).
    // ESC * C
    //   Designate G2 Character Set (ISO 2022, VT220).
    // ESC + C
    //   Designate G3 Character Set (ISO 2022, VT220).
    // ESC - C
    //   Designate G1 Character Set (VT300).
    // ESC . C
    //   Designate G2 Character Set (VT300).
    // ESC / C
    //   Designate G3 Character Set (VT300). C = A  -> ISO Latin-1 Supplemental. - Supported?
    //
    func selectCharset (_ p: ArraySlice<UInt8>)
    {
        if p.count == 2 {
            print ("Settin charset to \(p[1])")
        }
        
        if (p.count != 2) {
            cmdSelectDefaultCharset ()
        }
        var ch: UInt8
        var charset: [UInt8:String]?
        
        if CharSets.all.keys.contains(p [1]){
            charset = CharSets.all [p [1]]!
        } else {
            charset = nil
        }
        
        switch p [0] {
        case 0x28: // '('
            ch = 0
        case 0x29: // )
            ch = 1
        case 0x2d: // -
            ch = 1
        case 0x2a: // *
            ch = 2
        case 0x2e: // .
            ch = 2
        case 0x2b: // +
            ch = 3
        default:
            // includes '/' -> unsupported? (MIGUEL TODO)
            return;
        }
        setgCharset (ch, charset: charset)
    }
    
    //
    // ESC # NUMBER
    //
    func cmdDoubleWidthSingleHeight ()
    {
        abort ()
    }
    
    //
    // dhtop
    //
    func cmdSetDoubleHeightTop ()
    {
        abort ()
    }
    
    // dhbot
    func cmdSetDoubleHeightBottom ()
    {
        abort ()
    }
    
    //
    // swsh
    //
    func cmdSingleWidthSingleHeight ()
    {
        abort ()
    }
    
    // ESC # 8
    func cmdScreenAlignmentPattern ()
    {
        let cell = CharData(attribute: curAttrCleared(), char: "E")

        setCursor (col: 0, row: 0)
        for yOffset in 0..<rows {
            let rowN = buffer.y + buffer.yBase + yOffset
            buffer.lines [rowN].fill(with: cell)
            buffer.lines [rowN].isWrapped = false
        }
        updateFullScreen()
        setCursor(col: 0, row: 0)
    }
    
    //

    func cmdRestoreCursor (_ pars: [Int], _ collect: cstring)
    {
        buffer.x = buffer.savedX
        buffer.y = buffer.savedY
        curAttr = buffer.savedAttr
        originMode = savedOriginMode
        marginMode = savedMarginMode
        wraparound = savedWraparound
        reverseWraparound = savedReverseWraparound
    }

    //
    // Validates optional arguments for top, left, bottom, right sent by various escape sequences and returns validated
    //
    func getRectangleFromRequest (_ pars: ArraySlice<Int>) -> (top: Int, left: Int, bottom: Int, right: Int)
    {
        let b = pars.startIndex
        var top = max (1, pars.count > 0 ? pars [b] : 0)
        var left = max (pars.count > 1 ? pars [b+1] : 1, 0)
        var bottom = pars.count > 2 ? pars [b+2] : -1
        var right = pars.count > 3 ? pars [b+3] : -1

        if bottom < 0 {
            bottom = rows-1
        }
        if right < 0 {
            right = cols-1
        }
        if right >= cols {
            right = cols-1
        }
        if bottom >= rows {
            bottom = rows - 1
        }
        if originMode {
            top += buffer.scrollTop
            bottom += buffer.scrollBottom
        }
        top = min (top, bottom)
        left = min (left, right)
        return (top, left, bottom, right)
    }
    
    //
    // Copy Rectangular Area (DECCRA), VT400 and up.
    // CSI Pt ; Pl ; Pb ; Pr ; Pp ; Pt ; Pl ; Pp $ v
    //  Pt ; Pl ; Pb ; Pr denotes the rectangle.
    //  Pp denotes the source page.
    //  Pt ; Pl denotes the target location.
    //  Pp denotes the target page.
    func csiCopyRectangularArea (_ pars: [Int], _ collect: cstring)
    {
        if collect == [36] && pars.count == 8 {
            // We only support copying on the same page, and the page being 1
            if pars [4] == pars [7] && pars [4] == 1 {
                let (top, left, bottom, right) = getRectangleFromRequest(pars [0...3])
                var lines: [[CharData]] = []
                for row in top...bottom {
                    let line = buffer.lines [row+buffer.yBase-1]
                    var lineCopy: [CharData] = []
                    for col in left...right {
                        lineCopy.append(line [col-1])
                    }
                    lines.append(lineCopy)
                }
                
                let roffset = pars [5]
                let coffset = pars [6]
                for row in 0..<(bottom-top) {
                    if row+roffset >= buffer.rows {
                        break
                    }
                    let line = buffer.lines [row+roffset+buffer.yBase-1]
                    let lr = lines [row]
                    for col in 0..<(right-left) {
                        if col >= buffer.cols {
                            break
                        }
                        line [coffset+col-1] = lr [col]
                    }
                }
            }
        }
    }

    // CSI Ps x  Request Terminal Parameters (DECREQTPARM).
    // CSI Ps * x Select Attribute Change Extent (DECSACE), VT420 and up.
    // CSI Pc ; Pt ; Pl ; Pb ; Pr $ x Fill Rectangular Area (DECFRA), VT420 and up.
    func csiX (_ pars: [Int], _ collect: cstring)
    {
        if collect == [0x24] && pars.count > 0{
            // DECFRA
            let (top, left, bottom, right) = getRectangleFromRequest(pars [1...])
            for row in top...bottom {
                let line = buffer.lines [row+buffer.yBase-1]
                for col in left...right {
                    line [col-1] = CharData(attribute: curAttr, char: Character (UnicodeScalar (pars [0]) ?? " "))
                }
            }
        } else {
            print ("Not implemented CSI x with collect: collect=\(collect) and pars=\(pars)")
        }
    }

    // Required by the test suite
    // CSI Pi ; Pg ; Pt ; Pl ; Pb ; Pr * y
    // Request Checksum of Rectangular Area (DECRQCRA), VT420 and up.
    // Response is
    // DCS Pi ! ~ x x x x ST
    //   Pi is the request id.
    //   Pg is the page number.
    //   Pt ; Pl ; Pb ; Pr denotes the rectangle.
    //   The x's are hexadecimal digits 0-9 and A-F.
    func cmdDECRQCRA (_ pars: [Int], _ collect: cstring)
    {
        var checksum: UInt32 = 0
        let rid = pars.count > 0 ? pars [0] : 1
        let _ = pars.count > 1 ? pars [1] : 0
        var result = "0000"
        // Still need to imeplemnt the checksum here
        // Which is just the sum of the rune values
        if tdel.isProcessTrusted() {
            let (top, left, bottom, right) = getRectangleFromRequest(pars [2...])
            for row in top...bottom {
                let line = buffer.lines [row+buffer.yBase-1]
                for col in left...right {
                    let cd = line [col-1]
                    let ch = cd.getCharacter()
                    for scalar in ch.unicodeScalars {
                        checksum += scalar.value
                    }
                }
            }
            result = String(format: "%04x", checksum)
        }
        sendResponse ("\(cc.DCS)\(rid)!~\(result)\(cc.ST)")
    }

    // DECERA - Erase Rectangular Area
    // CSI Pt ; Pl ; Pb ; Pr ; $ z
    func cmdEraseRectangularArea (_ pars: [Int], _ collect: cstring)
    {
        if collect == [0x24]  {
            let (top, left, bottom, right) = getRectangleFromRequest(pars [0...])
            
            for row in top...bottom {
                let line = buffer.lines [row+buffer.yBase-1]
                for col in left...right {
                    line [col-1] = CharData(attribute: curAttr, char: " ", size: 1)
                }
            }
        }
    }

    // DECSERA - Selective Erase Rectangular Area
    // CSI Pt ; Pl ; Pb ; Pr ; $ {
    func cmdSelectiveEraseRectangularArea (_ pars: [Int], _ collect: cstring)
    {
        if collect == [0x24]  {
            let (top, left, bottom, right) = getRectangleFromRequest(pars [0...])
            
            for row in top...bottom {
                let line = buffer.lines [row+buffer.yBase-1]
                for col in left...right {
                    var cd = line [col-1]
                    cd.setValue(char: " ", size: 1)
                    line [col-1] = cd
                }
            }
        }
    }
    /**
     * Commands send to the `windowCommand` delegate for the front-end to implement capabilities
     * on behalf of the client.  The expected return strings in some of these enumeration values is documented
     * below.   Returns are only expected for the enum values that start with the prefix `report`
     */
    public enum WindowManipulationCommand {
        /// Raised when the backend should deiconify a window, no return expected
        case deiconifyWindow
        /// Raised when the backend should iconify  a window, no return expected
        case iconifyWindow
        /// Raised when the client would like the window to be moved to the x,y position int he screen, not return expected
        case moveWindowTo(x: Int, y: Int)
        /// Raised when the client would like the window to be resized to the specified widht and heigh in pixels, not return expected
        case resizeWindowTo(width: Int, height: Int)
        /// Raised to bring the terminal to the front
        case bringToFront
        /// Send the terminal to the back if possible
        case sendToBack
        /// Trigger a terminal refresh
        case refreshWindow
        /// Request that the size of the terminal be changed to the specified cols and rows
        case resizeTo(cols: Int, rows: Int)
        case restoreMaximizedWindow
        /// Attempt to maximize the window
        case maximizeWindow
        /// Attempt to maximize the window vertically
        case maximizeWindowVertically
        /// Attempt to maximize the window horizontally
        case maximizeWindowHorizontally
        case undoFullScreen
        case switchToFullScreen
        case toggleFullScreen
        case reportTerminalState
        case reportTerminalPosition
        case reportTextAreaPosition
        case reporttextAreaPixelDimension
        case reportSizeOfScreenInPixels
        case reportCellSizeInPixels
        case reportTextAreaCharacters
        case reportScreenSizeCharacters
        case reportIconLabel
        case reportWindowTitle
        case resizeTo (lines: Int)
    }

    //
    // CSI Ps ; Ps ; Ps t - Various window manipulations and reports (xterm)
    // See https://invisible-island.net/xterm/ctlseqs/ctlseqs.html for a full
    // list of commans for this escape sequence
    func cmdWindowOptions (_ pars: [Int], _ collect: cstring)
    {
        switch pars {
        case [1]:
            tdel.windowCommand(source: self, command: .deiconifyWindow)
        case [2]:
            tdel.windowCommand(source: self, command: .iconifyWindow)
        case _ where pars.count == 3 && pars.first == 3:
            tdel.windowCommand(source: self, command: .moveWindowTo(x: pars [1], y: pars[2]))
        case _ where pars.count == 3 && pars.first == 4:
            tdel.windowCommand(source: self, command: .moveWindowTo(x: pars [1], y: pars[2]))
        case [5]:
            tdel.windowCommand(source: self, command: .bringToFront)
        case [6]:
            tdel.windowCommand(source: self, command: .sendToBack)
        case [7]:
            tdel.windowCommand(source: self, command: .refreshWindow)
        case _ where pars.count == 3 && pars.first == 8:
            tdel.windowCommand(source: self, command: .resizeTo(cols: pars [1], rows: pars [2]))
        case [9, 0]:
            tdel.windowCommand(source: self, command: .restoreMaximizedWindow)
        case [9, 1]:
            tdel.windowCommand(source: self, command: .maximizeWindow)
        case [9, 2]:
            tdel.windowCommand(source: self, command: .maximizeWindowVertically)
        case [9, 3]:
            tdel.windowCommand(source: self, command: .maximizeWindowHorizontally)
        case [10, 0]:
            tdel.windowCommand(source: self, command: .undoFullScreen)
        case [10, 1]:
            tdel.windowCommand(source: self, command: .switchToFullScreen)
        case [10, 2]:
            tdel.windowCommand(source: self, command: .toggleFullScreen)
        case [15]: // Report size in pixels
            let r = tdel.windowCommand(source: self, command: .reportSizeOfScreenInPixels) ?? "\(cc.CSI)5;768;1024t"
            sendResponse(r)
        case [16]: // Report cell size in pixels
            // If no value is returned send 16x10
            // TODO: should surface that to the UI, should not do this here
            let r = tdel.windowCommand(source: self, command: .reportCellSizeInPixels) ?? "\(cc.CSI)6;16;10t"
            sendResponse(r)
        case [18]:
            let r = tdel.windowCommand(source: self, command: .reportCellSizeInPixels) ?? "\(cc.CSI)8;\(rows);\(cols)t"
            sendResponse(r)
        case [19]:
            let r = tdel.windowCommand(source: self, command: .reportScreenSizeCharacters) ?? "\(cc.CSI)9;\(rows);\(cols)t"
            sendResponse(r)
        case [20]:
            let it = iconTitle.replacingOccurrences(of: "\\", with: "")
            sendResponse ("\u{1b}]L\(it)\\")
        case [21]:
            let tt = terminalTitle.replacingOccurrences(of: "\\", with: "")
            sendResponse ("\u{1b}]l\(tt)\\")
        case [22, 0]:
            terminalTitleStack = terminalTitleStack + [terminalTitle]
            terminalIconStack = terminalIconStack + [iconTitle]
        case [22, 1]:
            terminalIconStack = terminalIconStack + [iconTitle]
        case [22, 2]:
            terminalTitleStack = terminalTitleStack + [terminalTitle]
        case [23, 0]:
            if let nt = terminalTitleStack.last {
                terminalTitleStack = terminalTitleStack.dropLast()
                setTitle(text: nt)
            }
            if let nt = terminalIconStack.last {
                terminalIconStack = terminalIconStack.dropLast()
                setIconTitle(text: nt)
            }
        case [23, 1]:
            if let nt = terminalTitleStack.last {
                terminalTitleStack = terminalTitleStack.dropLast()
                setTitle(text: nt)
            }
        case [23, 2]:
            if let nt = terminalIconStack.last {
                terminalIconStack = terminalIconStack.dropLast()
                setIconTitle(text: nt)
            }

        default:
            break
        }
    }

    func cmdSetMargins (_ pars: [Int], _ collect: cstring)
    {
        var left = (pars.count > 0 ? pars[0] : 1) - 1
        let right = (pars.count > 1 ? pars [1] : cols) - 1
        
        left = min (left, right)
        marginLeft = left
        marginRight = right
    }
    
    //
    //  CSI s (sometimes, if the margin mode is false)
    //  ESC 7
    //   Save cursor (ANSI.SYS).
    //
    func cmdSaveCursor (_ pars: [Int], _ collect: cstring)
    {
        buffer.savedX = buffer.x
        buffer.savedY = buffer.y
        buffer.savedAttr = curAttr
        savedWraparound = wraparound
        savedOriginMode = originMode
        savedMarginMode = marginMode
        savedReverseWraparound = reverseWraparound
    }

    //
    // CSI Ps ; Ps r
    //   Set Scrolling Region [top;bottom] (default = full size of window) (DECSTBM).
    // CSI ? Pm r
    //
    func cmdSetScrollRegion (_ pars: [Int], _ collect: cstring)
    {
        if collect != [] {
            return
        }
        buffer.scrollTop = pars.count > 0 ? max (pars [0] - 1, 0) : 0
        buffer.scrollBottom = (pars.count > 1 ? min (pars [1], rows) : rows) - 1
        buffer.scrollTop = min (buffer.scrollTop, buffer.scrollBottom)
        setCursor(col: 0, row: 0)
    }

    func setCursorStyle (_ style: CursorStyle)
    {
        // TODO: should this call the delegate?
    }
    
    //
    // CSI Ps SP q  Set cursor style (DECSCUSR, VT520).
    //   Ps = 0  -> blinking block.
    //   Ps = 1  -> blinking block (default).
    //   Ps = 2  -> steady block.
    //   Ps = 3  -> blinking underline.
    //   Ps = 4  -> steady underline.
    //   Ps = 5  -> blinking bar (xterm).
    //   Ps = 6  -> steady bar (xterm).
    //
    func cmdSetCursorStyle (_ pars: [Int], _ collect: cstring)
    {
        if (collect != [32]){ /* space */
            return
        }
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        switch (p) {
        case 1:
            setCursorStyle (.blinkBlock)
        case 2:
            setCursorStyle (.steadyBlock)
        case 3:
            setCursorStyle (.blinkUnderline)
        case 4:
            setCursorStyle (.steadyUnderline)
        case 5:
            setCursorStyle (.blinkingBar)
        case 6:
            setCursorStyle (.steadyBar)
        default:
            break;
        }
    }

    //
    // CSI ! p   Soft terminal reset (DECSTR).
    // http://vt100.net/docs/vt220-rm/table4-10.html
    //
    func cmdSoftReset (_ pars: [Int], _ collect: cstring)
    {
        if collect != [0x21] /* ! */ {
            return
        }

        cursorHidden = false
        insertMode = false
        originMode = false
        marginMode = false
        savedWraparound = false
        savedOriginMode = false
        savedMarginMode = false
        reverseWraparound = false
        savedReverseWraparound = false
        wraparound = true  // defaults: xterm - true, vt100 - false
        applicationKeypad = false
        syncScrollArea ()
        applicationCursor = false
        buffer.scrollTop = 0
        buffer.scrollBottom = rows - 1
        curAttr = CharData.defaultAttr
        buffer.x = 0
        buffer.y = 0
        buffer.savedAttr = CharData.defaultAttr
        buffer.savedY = 0
        buffer.savedX = 0
        marginRight = cols
        marginLeft = 1
        charset = nil
        setgLevel (0)

        // MIGUEL TODO:
        // TODO: audit any new variables, those in setup might be useful
    }

    //
    // CSI Ps n  Device Status Report (DSR).
    //     Ps = 5  -> Status Report.  Result (``OK'') is
    //   CSI 0 n
    //     Ps = 6  -> Report Cursor Position (CPR) [row;column].
    //   Result is
    //   CSI r ; c R
    // CSI ? Ps n
    //   Device Status Report (DSR, DEC-specific).
    //     Ps = 6  -> Report Cursor Position (CPR) [row;column] as CSI
    //     ? r ; c R (assumes page is zero).
    //     Ps = 1 5  -> Report Printer status as CSI ? 1 0  n  (ready).
    //     or CSI ? 1 1  n  (not ready).
    //     Ps = 2 5  -> Report UDK status as CSI ? 2 0  n  (unlocked)
    //     or CSI ? 2 1  n  (locked).
    //     Ps = 2 6  -> Report Keyboard status as
    //   CSI ? 2 7  ;  1  ;  0  ;  0  n  (North American).
    //   The last two parameters apply to VT400 & up, and denote key-
    //   board ready and LK01 respectively.
    //     Ps = 5 3  -> Report Locator status as
    //   CSI ? 5 3  n  Locator available, if compiled-in, or
    //   CSI ? 5 0  n  No Locator, if not.
    //
    func cmdDeviceStatus (_ pars: [Int], _ collect: cstring)
    {
        if collect.count == 0 {
            switch (pars [0]) {
            case 5:
                // status report
                sendResponse ("\(cc.CSI)0n")
            case 6:
                // cursor position
                let y = buffer.y + 1
                let x = buffer.x + 1
                sendResponse ("\(cc.CSI)\(y);\(x)R")
            default:
                break;
            }
        } else if (collect == [0x3f /* ? */ ]) {
            // modern xterm doesnt seem to
            // respond to any of these except ?6, 6, and 5
            switch pars [0] {
            case 6:
                // cursor position
                let y = buffer.y + 1
                let x = buffer.x + 1
                sendResponse ("\(cc.CSI)?\(y);${\(x)R")
            case 15:
                // TODO: no printer
                // this.handler(C0.ESC + '[?11n');
                break;
            case 25:
                // TODO: dont support user defined keys
                // this.handler(C0.ESC + '[?21n');
                break;
            case 26:
                // TODO: north american keyboard
                // this.handler(C0.ESC + '[?27;1;0;0n');
                break;
            case 53:
                // TODO: no dec locator/mouse
                // this.handler(C0.ESC + '[?50n');
                break;
            default:
                break
            }
        }
    }

    //
    // CSI Pm m  Character Attributes (SGR).
    //     Ps = 0  -> Normal (default).
    //     Ps = 1  -> Bold.
    //     Ps = 2  -> Faint, decreased intensity (ISO 6429).
    //     Ps = 4  -> Underlined.
    //     Ps = 5  -> Blink (appears as Bold).
    //     Ps = 7  -> Inverse.
    //     Ps = 8  -> Invisible, i.e., hidden (VT300).
    //     Ps = 9  -> Crossed out character
    //     Ps = 2 2  -> Normal (neither bold nor faint).
    //     Ps = 2 4  -> Not underlined.
    //     Ps = 2 5  -> Steady (not blinking).
    //     Ps = 2 7  -> Positive (not inverse).
    //     Ps = 2 8  -> Visible, i.e., not hidden (VT300).
    //     Ps = 2 9  -> Not crossed out
    //     Ps = 3 0  -> Set foreground color to Black.
    //     Ps = 3 1  -> Set foreground color to Red.
    //     Ps = 3 2  -> Set foreground color to Green.
    //     Ps = 3 3  -> Set foreground color to Yellow.
    //     Ps = 3 4  -> Set foreground color to Blue.
    //     Ps = 3 5  -> Set foreground color to Magenta.
    //     Ps = 3 6  -> Set foreground color to Cyan.
    //     Ps = 3 7  -> Set foreground color to White.
    //     Ps = 3 9  -> Set foreground color to default (original).
    //     Ps = 4 0  -> Set background color to Black.
    //     Ps = 4 1  -> Set background color to Red.
    //     Ps = 4 2  -> Set background color to Green.
    //     Ps = 4 3  -> Set background color to Yellow.
    //     Ps = 4 4  -> Set background color to Blue.
    //     Ps = 4 5  -> Set background color to Magenta.
    //     Ps = 4 6  -> Set background color to Cyan.
    //     Ps = 4 7  -> Set background color to White.
    //     Ps = 4 9  -> Set background color to default (original).
    //
    //   If 16-color support is compiled, the following apply.  Assume
    //   that xterm's resources are set so that the ISO color codes are
    //   the first 8 of a set of 16.  Then the aixterm colors are the
    //   bright versions of the ISO colors:
    //     Ps = 9 0  -> Set foreground color to Black.
    //     Ps = 9 1  -> Set foreground color to Red.
    //     Ps = 9 2  -> Set foreground color to Green.
    //     Ps = 9 3  -> Set foreground color to Yellow.
    //     Ps = 9 4  -> Set foreground color to Blue.
    //     Ps = 9 5  -> Set foreground color to Magenta.
    //     Ps = 9 6  -> Set foreground color to Cyan.
    //     Ps = 9 7  -> Set foreground color to White.
    //     Ps = 1 0 0  -> Set background color to Black.
    //     Ps = 1 0 1  -> Set background color to Red.
    //     Ps = 1 0 2  -> Set background color to Green.
    //     Ps = 1 0 3  -> Set background color to Yellow.
    //     Ps = 1 0 4  -> Set background color to Blue.
    //     Ps = 1 0 5  -> Set background color to Magenta.
    //     Ps = 1 0 6  -> Set background color to Cyan.
    //     Ps = 1 0 7  -> Set background color to White.
    //
    //   If xterm is compiled with the 16-color support disabled, it
    //   supports the following, from rxvt:
    //     Ps = 1 0 0  -> Set foreground and background color to
    //     default.
    //
    //   If 88- or 256-color support is compiled, the following apply.
    //     Ps = 3 8  ; 5  ; Ps -> Set foreground color to the second
    //     Ps.
    //     Ps = 4 8  ; 5  ; Ps -> Set background color to the second
    //     Ps.
    //
    func cmdCharAttributes (_ pars: [Int], _ collect: cstring)
    {
        // Optimize a single SGR0.
        if pars.count == 1 && pars [0] == 0 {
            curAttr = CharData.defaultAttr
            return;
        }

        let parCount = pars.count
        let empty = CharacterAttribute (attribute: 0)
        var flags = CharacterAttribute (attribute: curAttr)
        var fg = (curAttr >> 9) & 0x1ff
        var bg = curAttr & 0x1ff
        let def = CharData.defaultAttr

        var i = 0
        while i < parCount {
            var p = Int32 (pars [i])
            if p >= 30 && p <= 37 {
                // fg color 8
                fg = p - 30
            } else if p >= 40 && p <= 47 {
                // bg color 8
                bg = p - 40
            } else if p >= 90 && p <= 97 {
                // fg color 16
                p += 8
                fg = p - 90
            } else if p >= 100 && p <= 107 {
                // bg color 16
                p += 8;
                bg = p - 100;
            } else if p == 0 {
                // default

                flags = CharacterAttribute (rawValue: UInt8 (def >> 18))
                fg = (def >> 9) & 0x1ff
                bg = def & 0x1ff
                // flags = 0;
                // fg = 0x1ff;
                // bg = 0x1ff;
            } else if p == 1 {
                // bold text
                flags = [flags, .bold]
            } else if p == 3 {
                // italic text
                flags = [flags, .italic]
            } else if p == 4 {
                // underlined text
                flags = [flags, .underline]
            } else if p == 5 {
                // blink
                flags = [flags, .blink]
            } else if p == 7 {
                // inverse and positive
                // test with: echo -e '\e[31m\e[42mhello\e[7mworld\e[27mhi\e[m'
                flags = [flags, .inverse]
            } else if p == 8 {
                // invisible
                flags = [flags, .invisible]
            } else if p == 9 {
                flags = [flags, .crossedOut]
            } else if p == 2 {
                // dimmed text
                flags = [flags, .dim]
            } else if p == 22 {
                // not bold nor faint
                flags = flags.remove (.bold) ?? empty
                flags = flags.remove (.dim) ?? empty
            } else if p == 23 {
                // not italic
                flags = flags.remove (.italic) ?? empty
            } else if p == 24 {
                // not underlined
                flags = flags.remove (.underline) ?? empty
            } else if p == 25 {
                // not blink
                flags = flags.remove (.blink) ?? empty
            } else if p == 27 {
                // not inverse
                flags = flags.remove (.inverse) ?? empty
            } else if p == 28 {
                // not invisible
                flags = flags.remove (.invisible) ?? empty
            } else if p == 29 {
                // not crossed out
                flags = flags.remove (.crossedOut) ?? empty
            } else if p == 39 {
                // reset fg
                fg = (CharData.defaultAttr >> 9) & 0x1ff
            } else if p == 49 {
                // reset bg
                bg = CharData.defaultAttr & 0x1ff
            } else if p == 38 {
                // fg color 256
                if pars [i + 1] == 2 {
                    
                    i += 2
                    fg = matchColor (
                        pars [i] & 0xff,
                        pars [i + 1] & 0xff,
                        pars [i + 2] & 0xff)
                    if fg == -1 {
                        fg = 0x1ff
                    }
                    i += 2;
                } else if pars [i + 1] == 5 {
                    i += 2
                    p = Int32 (pars [i] & 0xff)
                    fg = p
                }
            } else if p == 48 {
                // bg color 256
                if pars [i + 1] == 2 {
                    i += 2
                    bg = matchColor (
                        pars [i] & 0xff,
                        pars [i + 1] & 0xff,
                        pars [i + 2] & 0xff);
                    if bg == -1 {
                        bg = 0x1ff
                    }
                    i += 2;
                } else if pars [i + 1] == 5 {
                    i += 2
                    p = Int32 (pars [i] & 0xff)
                    bg = p
                }
            } else if p == 100 {
                // reset fg/bg
                fg = (def >> 9) & 0x1ff
                bg = def & 0x1ff
            } else {
                error ("Unknown SGR attribute: \(p)")
            }
            i += 1
        }
        curAttr = (Int32 (flags.rawValue) << 18) | (fg << 9) | bg
    }

    //
    //CSI Pm l  Reset Mode (RM).
    //    Ps = 2  -> Keyboard Action Mode (AM).
    //    Ps = 4  -> Replace Mode (IRM).
    //    Ps = 1 2  -> Send/receive (SRM).
    //    Ps = 2 0  -> Normal Linefeed (LNM).
    //CSI ? Pm l
    //  DEC Private Mode Reset (DECRST).
    //    Ps = 1  -> Normal Cursor Keys (DECCKM).
    //    Ps = 2  -> Designate VT52 mode (DECANM).
    //    Ps = 3  -> 80 Column Mode (DECCOLM).
    //    Ps = 4  -> Jump (Fast) Scroll (DECSCLM).
    //    Ps = 5  -> Normal Video (DECSCNM).
    //    Ps = 6  -> Normal Cursor Mode (DECOM).
    //    Ps = 7  -> No Wraparound Mode (DECAWM).
    //    Ps = 8  -> No Auto-repeat Keys (DECARM).
    //    Ps = 9  -> Don't send Mouse X & Y on button press.
    //    Ps = 1 0  -> Hide toolbar (rxvt).
    //    Ps = 1 2  -> Stop Blinking Cursor (att610).
    //    Ps = 1 8  -> Don't print form feed (DECPFF).
    //    Ps = 1 9  -> Limit print to scrolling region (DECPEX).
    //    Ps = 2 5  -> Hide Cursor (DECTCEM).
    //    Ps = 3 0  -> Don't show scrollbar (rxvt).
    //    Ps = 3 5  -> Disable font-shifting functions (rxvt).
    //    Ps = 4 0  -> Disallow 80 -> 132 Mode.
    //    Ps = 4 1  -> No more(1) fix (see curses resource).
    //    Ps = 4 2  -> Disable Nation Replacement Character sets (DEC-
    //    NRCM).
    //    Ps = 4 4  -> Turn Off Margin Bell.
    //    Ps = 4 5  -> No Reverse-wraparound Mode.
    //    Ps = 4 6  -> Stop Logging.  (This is normally disabled by a
    //    compile-time option).
    //    Ps = 4 7  -> Use Normal Screen Buffer.
    //    Ps = 6 6  -> Numeric keypad (DECNKM).
    //    Ps = 6 7  -> Backarrow key sends delete (DECBKM).
    //    Ps = 1 0 0 0  -> Don't send Mouse X & Y on button press and
    //    release.  See the section Mouse Tracking.
    //    Ps = 1 0 0 1  -> Don't use Hilite Mouse Tracking.
    //    Ps = 1 0 0 2  -> Don't use Cell Motion Mouse Tracking.
    //    Ps = 1 0 0 3  -> Don't use All Motion Mouse Tracking.
    //    Ps = 1 0 0 4  -> Don't send FocusIn/FocusOut events.
    //    Ps = 1 0 0 5  -> Disable Extended Mouse Mode.
    //    Ps = 1 0 1 0  -> Don't scroll to bottom on tty output
    //    (rxvt).
    //    Ps = 1 0 1 1  -> Don't scroll to bottom on key press (rxvt).
    //    Ps = 1 0 3 4  -> Don't interpret "meta" key.  (This disables
    //    the eightBitInput resource).
    //    Ps = 1 0 3 5  -> Disable special modifiers for Alt and Num-
    //    Lock keys.  (This disables the numLock resource).
    //    Ps = 1 0 3 6  -> Don't send ESC  when Meta modifies a key.
    //    (This disables the metaSendsEscape resource).
    //    Ps = 1 0 3 7  -> Send VT220 Remove from the editing-keypad
    //    Delete key.
    //    Ps = 1 0 3 9  -> Don't send ESC  when Alt modifies a key.
    //    (This disables the altSendsEscape resource).
    //    Ps = 1 0 4 0  -> Do not keep selection when not highlighted.
    //    (This disables the keepSelection resource).
    //    Ps = 1 0 4 1  -> Use the PRIMARY selection.  (This disables
    //    the selectToClipboard resource).
    //    Ps = 1 0 4 2  -> Disable Urgency window manager hint when
    //    Control-G is received.  (This disables the bellIsUrgent
    //    resource).
    //    Ps = 1 0 4 3  -> Disable raising of the window when Control-
    //    G is received.  (This disables the popOnBell resource).
    //    Ps = 1 0 4 7  -> Use Normal Screen Buffer, clearing screen
    //    first if in the Alternate Screen.  (This may be disabled by
    //    the titeInhibit resource).
    //    Ps = 1 0 4 8  -> Restore cursor as in DECRC.  (This may be
    //    disabled by the titeInhibit resource).
    //    Ps = 1 0 4 9  -> Use Normal Screen Buffer and restore cursor
    //    as in DECRC.  (This may be disabled by the titeInhibit
    //    resource).  This combines the effects of the 1 0 4 7  and 1 0
    //    4 8  modes.  Use this with terminfo-based applications rather
    //    than the 4 7  mode.
    //    Ps = 1 0 5 0  -> Reset terminfo/termcap function-key mode.
    //    Ps = 1 0 5 1  -> Reset Sun function-key mode.
    //    Ps = 1 0 5 2  -> Reset HP function-key mode.
    //    Ps = 1 0 5 3  -> Reset SCO function-key mode.
    //    Ps = 1 0 6 0  -> Reset legacy keyboard emulation (X11R6).
    //    Ps = 1 0 6 1  -> Reset keyboard emulation to Sun/PC style.
    //    Ps = 2 0 0 4  -> Reset bracketed paste mode.
    //
    func cmdResetMode (_ pars: [Int], _ collect: cstring)
    {
        if pars.count == 0 {
            return
        }

        if pars.count > 1 {
            for i in 0..<pars.count {
                resetMode (pars [i], [])
            }
            return
        }
        resetMode (pars [0], collect)
    }

    func resetMode (_ par: Int, _ collect: cstring)
    {
        if collect == [] {
            switch (par) {
            case 4:
                insertMode = false
            case 20:
                // this._t.convertEol = false;
                break
            default:
                break
            }
        } else if collect == [0x3f /*?*/] {
            switch (par) {
            case 1:
                applicationCursor = false
            case 3:
                // DECCOLM
                resize (cols: 80, rows: rows)
                tdel.sizeChanged(source: self)
                reset()
            case 5:
                // Reset default color
                curAttr = CharData.defaultAttr
            case 6:
                // DECOM Reset
                originMode = false
            case 7:
                wraparound = false
            case 12:
                // this.cursorBlink = false;
                break;
            case 45:
                reverseWraparound = false
            case 66:
                log ("Switching back to normal keypad.");
                applicationKeypad = false
                syncScrollArea ()
            case 69:
                // DECSLRM
                marginMode = false

            case 9: // X10 Mouse
                mouseEvents = false
            case 1000: // vt200 mouse
                mouseEvents = false
            case 1002: // button event mouse
                mouseSendsMotionWhenPressed = false
            case 1003: // any event mouse
                mouseSendsAllMotion = false
            case 1004: // send focusin/focusout events
                sendFocus = false
            case 1005: // utf8 ext mode mouse
                utfMouse = false
            case 1006: // sgr ext mode mouse
                sgrMouse = false
            case 1015: // urxvt ext mode mouse
                urxvtMouse = false
            case 25: // hide cursor
                cursorHidden = true
            case 1048: // alt screen cursor
                cmdRestoreCursor ([], [])
            case 1049: // alt screen buffer cursor
                fallthrough
            case 47: // normal screen buffer
                fallthrough
            case 1047: // normal screen buffer - clearing it first
                   // Ensure the selection manager has the correct buffer
                buffers!.activateNormalBuffer ()
                if (par == 1049){
                    cmdRestoreCursor ([], [])
                }
                refresh (startRow: 0, endRow: rows - 1)
                syncScrollArea ()
                showCursor ()
                tdel.bufferActivated(source: self)
                
            case 2004: // bracketed paste mode (https://cirw.in/blog/bracketed-paste)
                bracketedPasteMode = false
                break
            default:
                break
            }
        }
    }

    //
    // CSI Pm h  Set Mode (SM).
    //     Ps = 2  -> Keyboard Action Mode (AM).
    //     Ps = 4  -> Insert Mode (IRM).
    //     Ps = 1 2  -> Send/receive (SRM).
    //     Ps = 2 0  -> Automatic Newline (LNM).
    // CSI ? Pm h
    //   DEC Private Mode Set (DECSET).
    //     Ps = 1  -> Application Cursor Keys (DECCKM).
    //     Ps = 2  -> Designate USASCII for character sets G0-G3
    //     (DECANM), and set VT100 mode.
    //     Ps = 3  -> 132 Column Mode (DECCOLM).
    //     Ps = 4  -> Smooth (Slow) Scroll (DECSCLM).
    //     Ps = 5  -> Reverse Video (DECSCNM).
    //     Ps = 6  -> Origin Mode (DECOM).
    //     Ps = 7  -> Wraparound Mode (DECAWM).
    //     Ps = 8  -> Auto-repeat Keys (DECARM).
    //     Ps = 9  -> Send Mouse X & Y on button press.  See the sec-
    //     tion Mouse Tracking.
    //     Ps = 1 0  -> Show toolbar (rxvt).
    //     Ps = 1 2  -> Start Blinking Cursor (att610).
    //     Ps = 1 8  -> Print form feed (DECPFF).
    //     Ps = 1 9  -> Set print extent to full screen (DECPEX).
    //     Ps = 2 5  -> Show Cursor (DECTCEM).
    //     Ps = 3 0  -> Show scrollbar (rxvt).
    //     Ps = 3 5  -> Enable font-shifting functions (rxvt).
    //     Ps = 3 8  -> Enter Tektronix Mode (DECTEK).
    //     Ps = 4 0  -> Allow 80 -> 132 Mode.
    //     Ps = 4 1  -> more(1) fix (see curses resource).
    //     Ps = 4 2  -> Enable Nation Replacement Character sets (DECN-
    //     RCM).
    //     Ps = 4 4  -> Turn On Margin Bell.
    //     Ps = 4 5  -> Reverse-wraparound Mode.
    //     Ps = 4 6  -> Start Logging.  This is normally disabled by a
    //     compile-time option.
    //     Ps = 4 7  -> Use Alternate Screen Buffer.  (This may be dis-
    //     abled by the titeInhibit resource).
    //     Ps = 6 6  -> Application keypad (DECNKM).
    //     Ps = 6 7  -> Backarrow key sends backspace (DECBKM).
    //     Ps = 1 0 0 0  -> Send Mouse X & Y on button press and
    //     release.  See the section Mouse Tracking.
    //     Ps = 1 0 0 1  -> Use Hilite Mouse Tracking.
    //     Ps = 1 0 0 2  -> Use Cell Motion Mouse Tracking.
    //     Ps = 1 0 0 3  -> Use All Motion Mouse Tracking.
    //     Ps = 1 0 0 4  -> Send FocusIn/FocusOut events.
    //     Ps = 1 0 0 5  -> Enable Extended Mouse Mode.
    //     Ps = 1 0 1 0  -> Scroll to bottom on tty output (rxvt).
    //     Ps = 1 0 1 1  -> Scroll to bottom on key press (rxvt).
    //     Ps = 1 0 3 4  -> Interpret "meta" key, sets eighth bit.
    //     (enables the eightBitInput resource).
    //     Ps = 1 0 3 5  -> Enable special modifiers for Alt and Num-
    //     Lock keys.  (This enables the numLock resource).
    //     Ps = 1 0 3 6  -> Send ESC   when Meta modifies a key.  (This
    //     enables the metaSendsEscape resource).
    //     Ps = 1 0 3 7  -> Send DEL from the editing-keypad Delete
    //     key.
    //     Ps = 1 0 3 9  -> Send ESC  when Alt modifies a key.  (This
    //     enables the altSendsEscape resource).
    //     Ps = 1 0 4 0  -> Keep selection even if not highlighted.
    //     (This enables the keepSelection resource).
    //     Ps = 1 0 4 1  -> Use the CLIPBOARD selection.  (This enables
    //     the selectToClipboard resource).
    //     Ps = 1 0 4 2  -> Enable Urgency window manager hint when
    //     Control-G is received.  (This enables the bellIsUrgent
    //     resource).
    //     Ps = 1 0 4 3  -> Enable raising of the window when Control-G
    //     is received.  (enables the popOnBell resource).
    //     Ps = 1 0 4 7  -> Use Alternate Screen Buffer.  (This may be
    //     disabled by the titeInhibit resource).
    //     Ps = 1 0 4 8  -> Save cursor as in DECSC.  (This may be dis-
    //     abled by the titeInhibit resource).
    //     Ps = 1 0 4 9  -> Save cursor as in DECSC and use Alternate
    //     Screen Buffer, clearing it first.  (This may be disabled by
    //     the titeInhibit resource).  This combines the effects of the 1
    //     0 4 7  and 1 0 4 8  modes.  Use this with terminfo-based
    //     applications rather than the 4 7  mode.
    //     Ps = 1 0 5 0  -> Set terminfo/termcap function-key mode.
    //     Ps = 1 0 5 1  -> Set Sun function-key mode.
    //     Ps = 1 0 5 2  -> Set HP function-key mode.
    //     Ps = 1 0 5 3  -> Set SCO function-key mode.
    //     Ps = 1 0 6 0  -> Set legacy keyboard emulation (X11R6).
    //     Ps = 1 0 6 1  -> Set VT220 keyboard emulation.
    //     Ps = 2 0 0 4  -> Set bracketed paste mode.
    // Modes:
    //   http: *vt100.net/docs/vt220-rm/chapter4.html
    //
    func cmdSetMode (_ pars: [Int], _ collect: cstring)
    {
        if pars.count == 0 {
            return
        }

        if pars.count > 1 {
            for i in 0..<pars.count {
                setMode (pars [i], [])
            }
            return
        }
        setMode (pars [0], collect)
    }

    func setMode (_ par: Int, _ collect: cstring)
    {
        if (collect == []) {
            switch par {
            case 4:
                //Console.WriteLine ("This needs to handle the replace mode as well");
                // https://vt100.net/docs/vt510-rm/IRM.html
                insertMode = true
            case 20:
                // Automatic New Line (LNM)
                // this._t.convertEol = true;
                break;
            default:
                print ("Unhandled verbatim setMode with \(par) and \(collect)")
                break
            }
        } else if collect == [0x3f] /* "?" */ {
            switch par {
            case 1:
                applicationCursor = true
                break;
            case 2:
                setgCharset (0, charset: CharSets.defaultCharset)
                setgCharset (1, charset: CharSets.defaultCharset)
                setgCharset (2, charset: CharSets.defaultCharset)
                setgCharset (3, charset: CharSets.defaultCharset)
                // set VT100 mode here
                
            case 3: // 132 col mode
                resize (cols: 132, rows: rows)
                reset()
                tdel.sizeChanged(source: self)
            case 5:
                // Inverted colors
                curAttr = CharData.invertedAttr
            case 6:
                // DECOM Set
                originMode = true
            case 7:
                wraparound = true
            case 12:
                // this.cursorBlink = true;
                break;
            case 66:
                log ("Serial port requested application keypad.");
                applicationKeypad = true
                syncScrollArea ()
                break;
            case 9: // X10 Mouse
                // no release, no motion, no wheel, no modifiers.
                setX10MouseStyle ()
                break;
            case 45: // Xterm Reverse Wrap-around
                reverseWraparound = true
            case 69:
                // Enable left and right margin mode (DECLRMM),
                marginMode = true
            case 1000: // vt200 mouse
                   // no motion.
                   // no modifiers, except control on the wheel.
                setVT200MouseStyle ()
                break;
            case 1002:
                // SET_BTN_EVENT_MOUSE
                mouseSendsMotionWhenPressed = true
                break;

            case 1003:
                // SET_ANY_EVENT_MOUSE
                mouseSendsAllMotion = true
                break;

            case 1004: // send focusin/focusout events
                   // focusin: ^[[I
                   // focusout: ^[[O
                sendFocus = true
                break;
            case 1005: // utf8 ext mode mouse
                   // for wide terminals
                   // simply encodes large values as utf8 characters
                utfMouse = true
                break;
            case 1006: // sgr ext mode mouse
                setVT200MouseStyle ()
                sgrMouse = true
                // for wide terminals
                // does not add 32 to fields
                // press: ^[[<b;x;yM
                // release: ^[[<b;x;ym
                
            case 1015: // urxvt ext mode mouse
                setVT200MouseStyle ()

                urxvtMouse = true
                // for wide terminals
                // numbers for fields
                // press: ^[[b;x;yM
                // motion: ^[[b;x;yT
                break;
            case 25: // show cursor
                cursorHidden = false
                break;
            case 1048: // alt screen cursor
                cmdSaveCursor ([], [])
                break;
            case 1049: // alt screen buffer cursor
                cmdSaveCursor ([], [])
                // FALL-THROUGH
                fallthrough
            case 47: // alt screen buffer
                fallthrough
            case 1047: // alt screen buffer
                buffers!.activateAltBuffer (fillAttr: eraseAttr ())
                refresh (startRow: 0, endRow: rows - 1)
                syncScrollArea ()
                showCursor ()
                tdel.bufferActivated(source: self)
                
            case 2004: // bracketed paste mode (https://cirw.in/blog/bracketed-paste)
                bracketedPasteMode = true
            default:
                print ("Unhandled ? setMode with \(par) and \(collect)")
                break;
            }
        }
    }


    //
    // CSI Ps g  Tab Clear (TBC).
    //     Ps = 0  -> Clear Current Column (default).
    //     Ps = 3  -> Clear All.
    // Potentially:
    //   Ps = 2  -> Clear Stops on Line.
    //   http://vt100.net/annarbor/aaa-ug/section6.html
    //
    func cmdTabClear (_ pars: [Int], _ collect: cstring)
    {
        let p = pars.count == 0 ? 0 : pars [0]
        if p == 0 {
            buffer.tabClear(pos: buffer.x)
        } else if (p == 3) {
            buffer.clearTabStops ()
        }
    }


    //
    // CSI Ps ; Ps f
    //   Horizontal and Vertical Position [row;column] (default =
    //   [1,1]) (HVP).
    //
    func cmdHVPosition (_ pars: [Int], _ collect: cstring)
    {
        var p = 1
        var q = 1
        if pars.count > 0 {
            p = max (pars [0], 1)
            if (pars.count > 1){
                q = max (pars [0], 1)
            }
        }
        
        buffer.y = p - 1
        if buffer.y >= rows {
            buffer.y = rows - 1
        }
        
        buffer.x = q - 1
        if buffer.x >= cols {
            buffer.x = cols - 1
        }
    }

    //
    // CSI Pm e  Vertical Position Relative (VPR)
    //   [rows] (default = [row+1,column])
    // reuse CSI Ps B ?
    //
    func cmdVPositionRelative (_ pars: [Int], _ collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        let newY = buffer.y + p

        if newY >= rows {
            buffer.y = rows - 1
        } else {
            buffer.y = newY
        }

        // If the end of the line is hit, prevent this action from wrapping around to the next line.
        if buffer.x >= cols {
            buffer.x -= 1
        }
    }


    //
    // CSI Pm d  Vertical Position Absolute (VPA)
    //   [row] (default = [1,column])
    //
    func cmdLinePosAbsolute (_ pars: [Int], collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)

        if (p - 1 >= rows) {
            buffer.y = rows - 1
        } else {
            buffer.y = p - 1
        }
    }

    //
    // CSI Ps c  Send Device Attributes (Primary DA).
    //     Ps = 0  or omitted -> request attributes from terminal.  The
    //     response depends on the decTerminalID resource setting.
    //     -> CSI ? 1 ; 2 c  (``VT100 with Advanced Video Option'')
    //     -> CSI ? 1 ; 0 c  (``VT101 with No Options'')
    //     -> CSI ? 6 c  (``VT102'')
    //     -> CSI ? 6 0 ; 1 ; 2 ; 6 ; 8 ; 9 ; 1 5 ; c  (``VT220'')
    //   The VT100-style response parameters do not mean anything by
    //   themselves.  VT220 parameters do, telling the host what fea-
    //   tures the terminal supports:
    //     Ps = 1  -> 132-columns.
    //     Ps = 2  -> Printer.
    //     Ps = 6  -> Selective erase.
    //     Ps = 8  -> User-defined keys.
    //     Ps = 9  -> National replacement character sets.
    //     Ps = 1 5  -> Technical characters.
    //     Ps = 2 2  -> ANSI color, e.g., VT525.
    //     Ps = 2 9  -> ANSI text locator (i.e., DEC Locator mode).
    // CSI > Ps c
    //   Send Device Attributes (Secondary DA).
    //     Ps = 0  or omitted -> request the terminal's identification
    //     code.  The response depends on the decTerminalID resource set-
    //     ting.  It should apply only to VT220 and up, but xterm extends
    //     this to VT100.
    //     -> CSI  > Pp ; Pv ; Pc c
    //   where Pp denotes the terminal type
    //     Pp = 0  -> ``VT100''.
    //     Pp = 1  -> ``VT220''.
    //   and Pv is the firmware version (for xterm, this was originally
    //   the XFree86 patch number, starting with 95).  In a DEC termi-
    //   nal, Pc indicates the ROM cartridge registration number and is
    //   always zero.
    // More information:
    //   xterm/charproc.c - line 2012, for more information.
    //   vim responds with ^[[?0c or ^[[?1c after the terminal's response (?)
    //
    func cmdSendDeviceAttributes (_ pars: [Int], collect: cstring)
    {
        if pars.count > 0 && pars [0] > 0 {
            return
        }

        let name = options.termName
        if collect == [] {
            if name.hasPrefix("xterm") || name.hasPrefix ("rxvt-unicode") || name.hasPrefix("screen") {
                sendResponse ("\(cc.CSI)?1;2c")
            } else if name.hasPrefix ("linux") {
                sendResponse ("\(cc.CSI)?6c")
            }
        } else if collect.count == 1 && collect [0] == 0x3e /* ">" */  {
            // xterm and urxvt
            // seem to spit this
            // out around ~370 times (?).
            if name.hasPrefix ("xterm") {
                sendResponse ("\(cc.CSI)>0;276;0c")
            } else if name.hasPrefix ("rxvt-unicode") {
                sendResponse ("\(cc.CSI)>85;95;0c")
            } else if name.hasPrefix ("linux") {
                // not supported by linux console.
                // linux console echoes parameters.
                sendResponse ("\(pars[0])c")
            } else if name.hasPrefix ("screen") {
                sendResponse ("\(cc.CSI)>83;40003;0c")
            }
        }
    }


    //
    // CSI Ps b  Repeat the preceding graphic character Ps times (REP).
    //
    func cmdRepeatPrecedingCharacter (_ pars: [Int], collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        let line = buffer.lines [buffer.yBase + buffer.y]
        let cd = buffer.x - 1 < 0 ? CharData (attribute: CharData.defaultAttr) : line [buffer.x - 1]
        line.replaceCells (start: buffer.x,
                           end: buffer.x + p,
                           fillData: cd);
        updateRange(buffer.y)
    }

    //
    //CSI Pm a  Character Position Relative
    //  [columns] (default = [row,col+1]) (HPR)
    //reuse CSI Ps C ?
    //
    func cmdHPositionRelative (_ pars: [Int], collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        
        buffer.x += p
        if buffer.x >= cols {
            buffer.x = cols - 1
        }
    }

    //
    // CSI Pm `  Character Position Absolute
    //   [column] (default = [row,1]) (HPA).
    //
    func cmdCharPosAbsolute (_ pars: [Int], collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)

        buffer.x = p - 1
        if buffer.x >= cols {
            buffer.x = cols - 1
        }
    }

    //
    //CSI Ps Z  Cursor Backward Tabulation Ps tab stops (default = 1) (CBT).
    //
    func cmdCursorBackwardTab (_ pars: [Int], collect: cstring)
    {
        if buffer.x > cols {
            return
        }
        let p = max (pars.count == 0 ? 1 : pars [0], 1)

        for _ in 0..<p {
            buffer.x = buffer.previousTabStop ()
        }
    }

    //
    // CSI Ps X
    // Erase Ps Character(s) (default = 1) (ECH).
    //
    func cmdEraseChars (_ pars: [Int], collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)

        buffer.lines [buffer.y + buffer.yBase].replaceCells (
            start: buffer.x,
            end: buffer.x + p,
            fillData: CharData (attribute:  eraseAttr ()))
    }

    //
    // CSI Ps T  Scroll down Ps lines (default = 1) (SD).
    //
    func cmdScrollDown (_ pars: [Int], collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        
        for _ in 0..<p {
            buffer.lines.splice (start: buffer.yBase + buffer.scrollBottom, deleteCount: 1, items: [])
            buffer.lines.splice (start: buffer.yBase + buffer.scrollBottom, deleteCount: 0, items: [buffer.getBlankLine (attribute: CharData.defaultAttr)])
        }
        // this.maxRange();
        updateRange (buffer.scrollTop)
        updateRange (buffer.scrollBottom)
    }

    //
    // CSI Ps S  Scroll up Ps lines (default = 1) (SU).
    //
    func cmdScrollUp (_ pars: [Int], collect: cstring)
    {
            let p = max (pars.count == 0 ? 1 : pars [0], 1)
            
            for _ in 0..<p {
                buffer.lines.splice (start: buffer.yBase + buffer.scrollTop, deleteCount: 1, items: []);
                buffer.lines.splice (start: buffer.yBase + buffer.scrollBottom, deleteCount: 0, items: [buffer.getBlankLine (attribute: CharData.defaultAttr)])
        }
        // this.maxRange();
        updateRange (buffer.scrollTop)
        updateRange (buffer.scrollBottom)
    }

    //
    // CSI Ps P
    // Delete Ps Character(s) (default = 1) (DCH).
    //
    func cmdDeleteChars (pars: [Int], _ collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        
        buffer.lines [buffer.y + buffer.yBase].deleteCells (
            pos: buffer.x, n: p, fillData: CharData (attribute: eraseAttr ()))
        
        updateRange (buffer.y)
    }

    //
    // CSI Ps M
    // Delete Ps Line(s) (default = 1) (DL).
    //
    func cmdDeleteLines (_ pars: [Int], _ collect: cstring)
    {
        restrictCursor()
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        let row = buffer.y + buffer.yBase
        var j = rows - 1 - buffer.scrollBottom
        j = rows - 1 + buffer.yBase - j
        let ea = eraseAttr ()
        for _ in 0..<p {
            // test: echo -e '\e[44m\e[1M\e[0m'
            // blankLine(true) - xterm/linux behavior
            buffer.lines.splice (start: row, deleteCount: 1, items: [])
            buffer.lines.splice (start: j, deleteCount: 0, items: [buffer.getBlankLine (attribute: ea)])
        }
        
        // this.maxRange();
        updateRange (buffer.y)
        updateRange (buffer.scrollBottom)
    }

    //
    // CSI Ps ' ~
    // Delete Ps Column(s) (default = 1) (DECDC), VT420 and up.
    //
    // @vt: #Y CSI DECDC "Delete Columns"  "CSI Ps ' ~"  "Delete `Ps` columns at cursor position."
    // DECDC deletes `Ps` times columns at the cursor position for all lines with the scroll margins,
    // moving content to the left. Blank columns are added at the right margin.
    // DECDC has no effect outside the scrolling margins.

    func cmdDeleteColumns (_ pars: [Int], _ collect: cstring)
    {
        let buffer = self.buffer
        if buffer.y > buffer.scrollBottom || buffer.y < buffer.scrollTop {
            return
        }
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        
        for y in buffer.scrollTop...buffer.scrollBottom {
            let line = buffer.lines [buffer.yBase + y]
            line.deleteCells(pos: buffer.x, n: p, fillData: buffer.getNullCell(attribute: eraseAttr()))
            line.isWrapped = false
        }
        updateRange (buffer.scrollTop)
        updateRange (buffer.scrollBottom)
    }


    //
    // Helper method to reset cells in a terminal row.
    // The cell gets replaced with the eraseChar of the terminal and the isWrapped property is set to false.
    // @param y row index
    //
    func resetBufferLine (y: Int)
    {
        eraseInBufferLine (y: y, start: 0, end: cols, clearWrap: true)
    }

    /**
     * Sends the provided text to the connected backend
     */
    public func sendResponse (_ text: String)
    {
        tdel.send (source: self, data: ([UInt8] (text.utf8))[...])
    }
    
    public func error (_ text: String)
    {
        print("Error: \(text)")
    }
    
    public func log (_ text: String)
    {
        // print("Log: \(text)")
    }
    
    /**
     * Processes the provided byte-array coming from the backend
     */
    public func feed (byteArray: [UInt8])
    {
        parse (buffer: byteArray[...])
    }
    
    public func feed (text: String)
    {
        parse (buffer: ([UInt8] (text.utf8))[...])
    }

    public func feed (buffer: ArraySlice<UInt8>)
    {
        parse (buffer: buffer)
    }

    public func parse (buffer: ArraySlice<UInt8>)
    {
        parser.parse(data: buffer)
    }
 
    /**
     * Registers the given line as requiring to be updated by the front-end engine
     *
     * The front-end engine should call `getUpdateRange` to
     * determine which region in the screen needs to be redrawn.   This method adds the specified
     * line to the range of modified lines
     */
    public func updateRange (_ y: Int)
    {
        if y >= 0 {
            if y < refreshStart {
                refreshStart = y
            }
            if y > refreshEnd {
                refreshEnd = y
            }
        }
    }
    
    public func updateFullScreen ()
    {
        refreshStart = 0
        refreshEnd = rows
    }
    
    /**
     * Returns the starting and ending lines that need to be redrawn, or nil
     * if no part of the screen needs to be updated.
     */
    public func getUpdateRange () -> (startY: Int, endY: Int)?
    {
        if refreshEnd == -1 && refreshStart == Int.max {
            //print ("Emtpy update range")
            return nil
        }
        //print ("Update: \(refreshStart) \(refreshEnd)")
        return (refreshStart, refreshEnd)
    }
    
    /**
     * Clears the state of the pending display redraw region.
     */
    public func clearUpdateRange ()
    {
        refreshStart = Int.max
        refreshEnd = -1
    }
    
    // ESC c Full Reset (RIS)
    func reset ()
    {
        options.rows = rows
        options.cols = cols
        let savedCursorHidden = cursorHidden
        setup ()
        cursorHidden = savedCursorHidden
        refresh (startRow: 0, endRow: rows-1)
        syncScrollArea ();
    }

    // ESC D Index (Index is 0x84)
    func cmdIndex ()
    {
        restrictCursor()
        
        let buffer = self.buffer
        let newY = buffer.y + 1
        if newY > buffer.scrollBottom {
            scroll ()
        } else {
            buffer.y = newY
        }
        // If the end of the line is hit, prevent this action from wrapping around to the next line
        if buffer.x > cols {
            buffer.x -= 1
        }
    }
    
    var blankLine: BufferLine = BufferLine(cols: 0)
    
    public func scroll (isWrapped: Bool = false)
    {
        let buffer = self.buffer
        var newLine = blankLine
        if newLine.count != cols || newLine [0].attribute != eraseAttr () {
            newLine = buffer.getBlankLine (attribute: eraseAttr (), isWrapped: isWrapped)
            blankLine = newLine
        }
        newLine.isWrapped = isWrapped

        let topRow = buffer.yBase + buffer.scrollTop
        let bottomRow = buffer.yBase + buffer.scrollBottom

        if buffer.scrollTop == 0 {
            // Determine whether the buffer is going to be trimmed after insertion.
            let willBufferBeTrimmed = buffer.lines.isFull

            // Insert the line using the fastest method
            if bottomRow == buffer.lines.count - 1 {
                if willBufferBeTrimmed {
                    buffer.lines.recycle ().copyFrom (line: newLine)
                } else {
                    buffer.lines.push (BufferLine (from: newLine))
                }
            } else {
                buffer.lines.splice (start: bottomRow + 1, deleteCount: 0, items: [BufferLine (from: newLine)])
            }

            // Only adjust ybase and ydisp when the buffer is not trimmed
            if !willBufferBeTrimmed {
                buffer.yBase += 1
                // Only scroll the ydisp with ybase if the user has not scrolled up
                if !userScrolling {
                    buffer.yDisp += 1
                }
            } else {
                // When the buffer is full and the user has scrolled up, keep the text
                // stable unless ydisp is right at the top
                if userScrolling {
                    buffer.yDisp = max (buffer.yDisp - 1, 0)
                }
            }
        } else {
            // scrollTop is non-zero which means no line will be going to the
            // scrollback, instead we can just shift them in-place.
            let scrollRegionHeight = bottomRow - topRow + 1 /*as it's zero-based*/
            buffer.lines.shiftElements (start: topRow + 1, count: scrollRegionHeight - 1, offset: -1)
            buffer.lines [bottomRow] = BufferLine (from: newLine)
        }

        // Move the viewport to the bottom of the buffer unless the user is
        // scrolling.
        if !userScrolling {
            buffer.yDisp = buffer.yBase
        }

        //buffer.dump ()
        // Flag rows that need updating
        updateRange (buffer.scrollTop)
        updateRange (buffer.scrollBottom)

        /**
         * This event is emitted whenever the terminal is scrolled.
         * The one parameter passed is the new y display position.
         *
         * @event scroll
         */
        tdel.scrolled(source: self, yDisp: buffer.yDisp)
    }
        
    public func emitLineFeed ()
    {
        tdel.linefeed(source: self)
    }
    
    //
    // ESC n
    // ESC o
    // ESC |
    // ESC }
    // ESC ~
    //   DEC mnemonic: LS (https://vt100.net/docs/vt510-rm/LS.html)
    //   When you use a locking shift, the character set remains in GL or GR until
    //   you use another locking shift. (partly supported)
    //
    func setgLevel (_ v: UInt8)
    {
        gLevel = v
        if let cs = CharSets.all [v] {
            charset = cs
        } else {
            charset = nil
        }
    }
    
    //
    // ESC % @
    // ESC % G
    //   Select default character set. UTF-8 is not supported (string are unicode anyways)
    //   therefore ESC % G does the same.
    //
    func cmdSelectDefaultCharset ()
    {
        setgLevel (0)
        setgCharset (0, charset: CharSets.defaultCharset)
    }

    //
    // ESC c
    //   DEC mnemonic: RIS (https://vt100.net/docs/vt510-rm/RIS.html)
    //   Reset to initial state.
    //
    func cmdReset ()
    {
            parser.reset ()
            reset ()
    }
            
    //
    // ESC >
    //   DEC mnemonic: DECKPNM (https://vt100.net/docs/vt510-rm/DECKPNM.html)
    //   Enables the keypad to send numeric characters to the host.
    //
    func cmdKeypadNumericMode ()
    {
            applicationKeypad = false
            syncScrollArea ()
    }
                    
    //
    // ESC =
    //   DEC mnemonic: DECKPAM (https://vt100.net/docs/vt510-rm/DECKPAM.html)
    //   Enables the numeric keypad to send application sequences to the host.
    //
    func cmdKeypadApplicationMode ()
    {
            applicationKeypad = true
            syncScrollArea ()
    }

    func eraseAttr () -> Int32
    {
        (CharData.defaultAttr & ~0x1ff) | curAttr & 0x1ff
    }
    
    /**
     * Returns an attribute that represents the current foreground/background, but without any of the other
     * attribuets (bold, underline, etc)
     */
    func curAttrCleared () -> Int32
    {
        return curAttr & 0x0003ffff
    }

    func setgCharset (_ v: UInt8, charset: [UInt8: String]?)
    {
        CharSets.all [v] = charset
        if gLevel == v {
            self.charset = charset
        }
    }
    
    public func resize (cols: Int, rows: Int)
    {
        let newCols = max (cols, MINIMUM_COLS)
        let newRows = max (rows, MINIMUM_ROWS)
        if newCols == self.cols && newRows == self.rows {
            return
        }
        let oldCols = self.cols
        buffers.resize(newColumns: newCols, newRows: newRows)
        self.cols = newCols
        self.rows = newRows
        buffer.setupTabStops (index: oldCols)
        refresh (startRow: 0, endRow: self.rows - 1)
    }
    
    func syncScrollArea ()
    {
        // This should call the viewport sync-scroll-area
    }

    /**
     * Registers that the region between startRow and endRow was modified and needs to be updated by the
     */
    public func refresh (startRow: Int, endRow: Int)
    {
        // TO BE HONEST - This probably should not be called directly,
        // instead the view shoudl after feeding data, determine if there is a need
        // to refresh based on the parameters provided for refresh ranges, and then
        // update, to avoid the backend rtiggering this multiple times.

        updateRange (startRow);
        updateRange (endRow);

    }
    
    public func showCursor ()
    {
        if cursorHidden == false {
            return
        }
        cursorHidden = false
        refresh (startRow: buffer.y, endRow: buffer.y)
        tdel.showCursor (source: self)
    }

    func setX10MouseStyle ()
    {
        x10Mouse = true
        mouseEvents = true

        mouseSendsRelease = false
        mouseSendsAllMotion = false
        mouseSendsWheel = false
        mouseSendsModifiers = false
        mouseSendsMotionWhenPressed = false
    }

    func setVT200MouseStyle ()
    {
        vt200Mouse = true
        mouseEvents = true

        mouseSendsRelease = true
        mouseSendsAllMotion = false
        mouseSendsWheel = true
        mouseSendsModifiers = false
        mouseSendsMotionWhenPressed = false
    }

    // Encode button and position to characters
    func encode (data: inout [UInt8], ch: Int)
    {
        if utfMouse {
            if ch == 2047 {
                data.append(0)
                return
            }
            if ch < 127 {
                data.append (UInt8(ch))
            } else {
                let rc = ch > 2047 ? 2047 : ch
                data.append (0xc0 | (UInt8 (rc >> 6)))
                data.append (0x80 | (UInt8 (rc & 0x3f)))
            }
        } else {
            if ch == 255 {
                data.append (0)
                return
            }
            let rc = ch > 127 ? 127 : ch
            data.append (UInt8 (rc))
        }
    }
    
    /**
     * Encodes the button action in the format expected by the client
     * - Parameter button: The button to encode
     * - Parameter release: `true` if this is a mouse release event
     * - Parameter shift: `true` if the shift key is pressed
     * - Parameter meta: `true` if the meta/alt key is pressed
     * - Parameter control: `true` if the control key is pressed
     * - Returns: the encoded value
     */
    public func encodeButton (button: Int, release: Bool, shift: Bool, meta: Bool, control: Bool) -> Int
    {
        var value: Int

        if release {
            value = 3
        } else {
            switch (button) {
            case 0:
                value = 0
            case 1:
                value = 1
            case 2:
                value = 2
            case 4:
                value = 64
            case 5:
                value = 65
            default:
                value = 0
            }
        }
        if mouseSendsModifiers {
            if shift {
                value |= 4
            }
            if meta {
                value |= 8
            }
            if control {
                value |= 16
            }
        }
        return value
    }
    
    /**
     * Sends a mouse event for a specific button at the specific location
     * - Parameter buttonFlags: Button flags encoded in Cb mode.
     * - Parameter x: X coordinate for the event
     * - Parameter y: Y coordinate for the event
     */
    public func sendEvent (buttonFlags: Int, x: Int, y: Int)
    {
        // TODO
        // Handle X10 Mouse,
        // Urxvt Mouse
        // SgrMouse
        if sgrMouse {
            let bflags : Int = ((buttonFlags & 3) == 3) ? (buttonFlags & ~3) : buttonFlags
            let m = ((buttonFlags & 3) == 3) ? "m" : "M"
            let sres = "\(cc.CSI)<\(bflags);\(x+1);\(y+1)\(m)"
            tdel.send (source: self, data: Array (sres.utf8)[...])
            return;
        }
        if vt200Mouse {
            // TODO
        }
        var res : [UInt8] = [0x1b /* ESC */, 0x5b /* [ */ , 0x4d /* M' */ ];
        encode (data: &res, ch: buttonFlags+32);
        encode (data: &res, ch: x+33);
        encode (data: &res, ch: y+33);
        tdel.send (source: self, data: res [...])
    }
    
    /**
     * Sends a mouse motion event for a specific button at the specific location
     * - Parameter buttonFlags: Button flags encoded in Cb mode.
     * - Parameter x: X coordinate for the event
     * - Parameter y: Y coordinate for the event
     */
    public func sendMotion (buttonFlags: Int, x: Int, y: Int)
    {
        sendEvent(buttonFlags: buttonFlags+32, x: x, y: y)
    }
    
    static var matchColorCache : [Int:Int] = [:]
    func matchColor (_ r1: Int, _ g1: Int, _ b1: Int) -> Int32
    {
        // TODO
        abort ()
    }
    
    var terminalTitle: String = ""              // The Xterm terminal title
    var iconTitle: String = ""                  // The Xterm minimized window title
    var terminalTitleStack: [String] = []
    var terminalIconStack: [String] = []
    
    public func setTitle (text: String)
    {
        terminalTitle = text
        tdel.setTerminalTitle(source: self, title: text)
    }

    public func setIconTitle (text: String)
    {
        iconTitle = text
        tdel.setTerminalIconTitle(source: self, title: text)
    }

    func reverseIndex ()
    {
        restrictCursor()
        if buffer.y == buffer.scrollTop {
            // possibly move the code below to term.reverseScroll();
            // test: echo -ne '\e[1;1H\e[44m\eM\e[0m'
            // blankLine(true) is xterm/linux behavior
            let scrollRegionHeight = buffer.scrollBottom - buffer.scrollTop
            buffer.lines.shiftElements (start: buffer.y + buffer.yBase, count: scrollRegionHeight, offset: 1)
            buffer.lines [buffer.y + buffer.yBase] = buffer.getBlankLine (attribute: eraseAttr ())
            updateRange (buffer.scrollTop)
            updateRange (buffer.scrollBottom)
        } else {
            buffer.y -= 1
        }
    }
    
    /**
     * Provides a baseline set of environment variables that would be useful to run the terminal,
     * you can customzie these accordingly.
     * - Returns:
     */
    public static func getEnvironmentVariables (termName: String? = nil) -> [String]
    {
        var l : [String] = []
        let t = termName == nil ? "xterm-256color" : termName!
        l.append ("TERM=\(t)")
        
        // Without this, tools like "vi" produce sequences that are not UTF-8 friendly
        l.append ("LANG=en_US.UTF-8");
        let env = ProcessInfo.processInfo.environment
        for x in ["LOGNAME", "USER", "DISPLAY", "LC_TYPE", "USER", "HOME" /* "PATH" */ ] {
            if env.keys.contains(x) {
                l.append ("\(x)=\(env[x]!)")
            }
        }
        return l
    }
}
