//
//  Terminal.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/27/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

/**
 * The terminal delegate is a protocol that must be implemented by a class
 * that would provide a user interface for the terminal, and it is used by the
 * `Terminal` to notify of important changes on the underlying terminal
 */
protocol TerminalDelegate {
    
    func showCursor (source: Terminal)
    
    /**
     * This method is invoked when the terminal needs to set the title for the window,
     * a UI toolkit would react by setting the terminal title in the window or any other
     * user visible element
     */
    func setTerminalTitle (source: Terminal, title: String)
    
    /**
     * This method is invoked when the terminal dimensions have changed in response
     * to an escape sequence that triggers a terminal resize, the user interface toolkit
     * should attempt to accomodate the new window size
     */
    func sizeChanged (source: Terminal)
    
    
    func send (data: ArraySlice<UInt8>)
    
    // callbacks
    
    // Callback - the window was scrolled, new yDisplay passed
    func scrolled (source: Terminal, yDisp: Int)
    // callback a newline was generated
    func linefeed (source: Terminal)
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
class Terminal {
    let MINIMUM_COLS = 2
    let MINIMUM_ROWS = 1
    
    // Options
    var scrollback : Int = 200
    var cols : Int = 80
    var rows : Int = 25
    var tabStopWidth : Int = 8
    var options = TerminalOptions()
    
    // The current buffers
    var buffers : BufferSet? = nil
    
    // Whether the terminal is operating in application keypad mode
    var applicationKeypad : Bool = false
    
    // Whether the terminal is operating in application cursor mode
    var applicationCursor : Bool = false
    
    // You can ignore most of the defaults set here, the function
    // reset() will do that again
    var sendFocus: Bool = false
    var cursorHidden : Bool = false
    var originMode : Bool = false
    public var insertMode : Bool = false
    var bracketedPasteMode : Bool = false
    public var charset : [UInt8:String]? = nil
    var gcharset : Int = 0
    public var wraparound : Bool = false
    var tdel : TerminalDelegate
    var curAttr : Int32 = CharData.defaultAttr
    var gLevel: UInt8 = 0
    
    var parser : EscapeSequenceParser
    var x10Mouse: Bool = false
    var utfMouse: Bool = false
    var vt200Mouse: Bool = false
    
    var mouseEvents = false
    var mouseSendsRelease = false
    var mouseSendsAllMotion = false
    var mouseSendsWheel = false
    var mouseSendsModifiers = false
    var sgrMouse = false
    var urxvtMouse = false

    var refreshStart = Int.max
    var refreshEnd = -1
    var userScrolling = false
    
    init (delegate : TerminalDelegate)
    {
        tdel = delegate
        
        // This duplicates the setup above, but
        parser = EscapeSequenceParser ()
        configureParser (parser)
        setup ()
    }
    
    /**
     * Returns the active buffer (either the normal buffer or the alternative buffer)
     */
    public var buffer: Buffer {
        get {
            buffers!.Active
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
        
        sgrMouse = false
        urxvtMouse = false
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
            case "\"q": // DECCSA
                terminal.sendResponse(text: "\u{1b}P1$r0\"q$\u{1b}\\")
            case "\"p": // DECSCL
                terminal.sendResponse (text: "\u{1b}P1$r61\"p$\u{1b}\\")
            case "r": // DECSTBM
                terminal.sendResponse (text: "\u{1b}P1$r$\(terminal.buffer.scrollTop + 1);\(terminal.buffer.scrollBottom + 1)r\u{1b}\\")
            case "m": // SGR
                  // TODO: report real settings instead of 0m
                abort ()
            default:
                // invalid: DCS 0 $ r Pt ST (xterm)
                terminal.error ("Unknown DCS + \(newData!)")
                terminal.sendResponse (text: "\u{1b}P0$r$\u{1b}")

            }
        }
    }

    // Configures the EscapeSequenceParser
    func configureParser (_ parser: EscapeSequenceParser)
    {
        parser.csiHandlerFallback = { (pars: [Int], collect: cstring, code: UInt8) -> () in
            self.error ("Unknown CSI Code (collect=\(collect) code=\(code) pars=\(pars)")
        }
        parser.escHandlerFallback = { (txt: cstring, flag: UInt8) in
            self.error ("Unknown ESC Code (txt=\(txt) flag=\(flag)")
        }
        parser.executeHandlerFallback = {
            self.error ("Unknown EXECUTE code")
        }
        parser.oscHandlerFallback = { (code: Int) in
            self.error ("Unknown OSC code: \(code)")
        }
        parser.printHandler = handlePrint
        
        // CSI handler
        parser.csiHandlers [0x40] = { (pars, collect) in self.insertChars (pars) }
        parser.csiHandlers [0x41] = { (pars, collect) in abort () /* cursorUp */ }
        parser.csiHandlers [0x42] = { (pars, collect) in abort () /* cursorDown */ }
        parser.csiHandlers [0x43] = { (pars, collect) in abort () /* cursorForward */ }
        parser.csiHandlers [0x44] = { (pars, collect) in abort () /* cursorBackward */ }
        parser.csiHandlers [0x45] = { (pars, collect) in abort () /* CursorNextLine */ }
        parser.csiHandlers [0x46] = { (pars, collect) in abort () /* CursorPrecedingLine */ }
        parser.csiHandlers [0x47] = { (pars, collect) in abort () /* CursorCharAbsolute */ }
        parser.csiHandlers [0x48] = { (pars, collect) in abort () /* CursorPosition */ }
        parser.csiHandlers [0x49] = { (pars, collect) in abort () /* CursorForwardTab */ }
        parser.csiHandlers [0x4a] = { (pars, collect) in abort () /* EraseInDisplay */ }
        parser.csiHandlers [0x4b] = { (pars, collect) in abort () /* EraseInLine */ }
        parser.csiHandlers [0x4c] = { (pars, collect) in abort () /* InsertLines */ }
        parser.csiHandlers [0x4d] = { (pars, collect) in abort () /* DeleteLines */ }
        parser.csiHandlers [0x50] = { (pars, collect) in abort () /* DeleteChars */ }
        parser.csiHandlers [0x53] = { (pars, collect) in abort () /* ScrollUp */ }
        parser.csiHandlers [0x54] = { (pars, collect) in abort () /* ScrollDown */ }
        parser.csiHandlers [0x58] = { (pars, collect) in abort () /* EraseChars (pars) */ }
        parser.csiHandlers [0x5a] = { (pars, collect) in abort () /* CursorBackwardTab (pars) */ }
        parser.csiHandlers [0x60] = { (pars, collect) in abort () /* CharPosAbsolute (pars) */ }
        parser.csiHandlers [0x61] = { (pars, collect) in abort () /* HPositionRelative (pars) */ }
        parser.csiHandlers [0x62] = { (pars, collect) in abort () /* RepeatPrecedingCharacter (pars) */ }
        parser.csiHandlers [0x63] = { (pars, collect) in abort () /* SendDeviceAttributes (pars, collect) */ }
        parser.csiHandlers [0x64] = { (pars, collect) in abort () /* LinePosAbsolute (pars) */ }
        parser.csiHandlers [0x65] = { (pars, collect) in abort () /* VPositionRelative (pars) */ }
        parser.csiHandlers [0x66] = { (pars, collect) in abort () /* HVPosition (pars) */ }
        parser.csiHandlers [0x67] = { (pars, collect) in abort () /* TabClear (pars) */ }
        parser.csiHandlers [0x68] = { (pars, collect) in abort () /* SetMode (pars, collect) */ }
        parser.csiHandlers [0x69] = { (pars, collect) in abort () /* ResetMode (pars, collect) */ }
        parser.csiHandlers [0x6d] = { (pars, collect) in abort () /* CharAttributes (pars) */ }
        parser.csiHandlers [0x6e] = { (pars, collect) in abort () /* DeviceStatus (pars, collect) */ }
        parser.csiHandlers [0x70] = { (pars, collect) in abort () /* SoftReset (pars, collect) */ }
        parser.csiHandlers [0x71] = { (pars, collect) in abort () /* SetCursorStyle (pars, collect) */ }
        parser.csiHandlers [0x72] = { (pars, collect) in abort () /* SetScrollRegion (pars, collect) */ }
        parser.csiHandlers [0x73] = { (pars, collect) in abort () /* SaveCursor (pars) */ }
        parser.csiHandlers [0x75] = { (pars, collect) in abort () /* RestoreCursor (pars) */ }

        parser.executeHandlers [7]  = { abort () /* Bell */ }
        parser.executeHandlers [10] = { abort () /* LineFeed */ }
        parser.executeHandlers [11] = { abort () /* LineFeedBasic */ }   // VT Vertical Tab - ignores auto-new-line behavior in ConvertEOL
        parser.executeHandlers [12] = { abort () /* LineFeedBasic */ }
        parser.executeHandlers [13] = { abort () /* CarriageReturn */ }
        parser.executeHandlers [8]  = { abort () /* Backspace */ }
        parser.executeHandlers [9]  = { abort () /* Tab */ }
        parser.executeHandlers [14] = { abort () /* ShiftOut */ }
        parser.executeHandlers [15] = { abort () /* ShiftIn */ }
        // Comment in original FIXME:   What do to with missing? Old code just added those to print.
        parser.executeHandlers [0x84] = { abort () /* Index */ }
        parser.executeHandlers [0x85] = { abort () /* Next Line */ }
        parser.executeHandlers [0x88] = { abort () /* Horizontal Tabulation Set */ }

        //
        // OSC handler
        //
        //   0 - icon name + title
        parser.oscHandlers [0] = { data in abort () /* SetTitle */ }
        //   1 - icon name
        //   2 - title
        parser.oscHandlers [2] = { data in abort () /* SetTitle */ }
        //   3 - set property X in the form "prop=value"
        //   4 - Change Color Number()
        //   5 - Change Special Color Number
        //   6 - Enable/disable Special Color Number c
        //   7 - current directory? (not in xterm spec, see https://gitlab.com/gnachman/iterm2/issues/3939)
        //  10 - Change VT100 text foreground color to Pt.
        //  11 - Change VT100 text background color to Pt.
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
        parser.setEscHandler ("7",  { collect, flag in abort () /* SaveCursor); */ })
        parser.setEscHandler ("8",  { collect, flag in abort () /* RestoreCursor); */ })
        parser.setEscHandler ("D",  { collect, flag in abort () /* (c, f) => terminal.Index ()); */ })
        parser.setEscHandler ("E",  { collect, flag in abort () /* (c, b) => NextLine ()); */ })
        parser.setEscHandler ("H",  { collect, flag in abort () /* (c, f) => TabSet ()); */ })
        parser.setEscHandler ("M",  { collect, flag in abort () /* (c, f) => ReverseIndex ()); */ })
        parser.setEscHandler ("=",  { collect, flag in abort () /* (c, f) => KeypadApplicationMode ()); */ })
        parser.setEscHandler (">",  { collect, flag in abort () /* (c, f) => KeypadNumericMode ()); */ })
        parser.setEscHandler ("c",  { collect, flag in abort () /* (c, f) => Reset ()); */ })
        parser.setEscHandler ("n",  { collect, flag in abort () /* (c, f) => SetgLevel (2)); */ })
        parser.setEscHandler ("o",  { collect, flag in abort () /* (c, f) => SetgLevel (3)); */ })
        parser.setEscHandler ("|",  { collect, flag in abort () /* (c, f) => SetgLevel (3)); */ })
        parser.setEscHandler ("}",  { collect, flag in abort () /* ) => SetgLevel (2)); */ })
        parser.setEscHandler ("~",  { collect, flag in abort () /* (c, f) => SetgLevel (1)); */ })
        parser.setEscHandler ("%@", { collect, flag in abort () /* ) => SelectDefaultCharset ()); */ })
        parser.setEscHandler ("%G", { collect, flag in abort () /* (c, f) => SelectDefaultCharset ()); */ })
        parser.setEscHandler ("#3", { collect, flag in abort () /* (c, f) => SetDoubleHeightTop ());            // dhtop */ })
        parser.setEscHandler ("#4", { collect, flag in abort () /* (c, f) => SetDoubleHeightBottom ());            // dhbot */ })
        parser.setEscHandler ("#5", { collect, flag in abort () /* (c, f) => SingleWidthSingleHeight ());          // swsh */ })
        parser.setEscHandler ("#6", { collect, flag in abort () /* (c, f) => DoubleWidthSingleHeight ());          // dwsh */ })
        for bflag in CharSets.all.keys {
            let flag = String (UnicodeScalar (bflag))
            parser.setEscHandler ("(" + flag, { code, f in abort () /* SelectCharset ("(" + flag)); */ })
            parser.setEscHandler (")" + flag, { code, f in abort () /* SelectCharset (")" + flag)); */ })
            parser.setEscHandler ("*" + flag, { code, f in abort () /* SelectCharset ("*" + flag)); */ })
            parser.setEscHandler ("+" + flag, { code, f in abort () /* SelectCharset ("+" + flag)); */ })
            parser.setEscHandler ("-" + flag, { code, f in abort () /* SelectCharset ("-" + flag)); */ })
            parser.setEscHandler ("." + flag, { code, f in abort () /* SelectCharset ("." + flag)); */ })
            parser.setEscHandler ("/" + flag, { code, f in abort () /* SelectCharset ("/" + flag)); // TODO: supported? */ })
        }

        // Error handler
        parser.errorHandler = { state in
            self.error ("Parsing error, state: \(state)")
            return state
        }

        // DCS Handler
        parser.setDcsHandler ("$q", DECRQSS (terminal: self))
    }

    func handlePrint (_ data: ArraySlice<UInt8>)
    {
        #if false
        let screenReaderMode = options.screenReaderMode
        var bufferRow = buffer.lines [buffer.y + buffer.yBase]

        updateRange (buffer.y)

        var pos = 0
        let end = data.count
        while pos < end {
            var code: Int
            // TODO var n = RuneExt.ExpectedSizeFromFirstByte (data [pos]);
            var n = 1
            if n == -1 {
                // Invalid UTF-8 sequence, client sent us some junk, happens if we run with the wrong locale set
                // for example if LANG=en
                code = Int (data [pos])
            } else if (n == 1) {
                code = Int (data [pos])
            } else if (pos + n < end) {
                var x : [UInt8] = []
                for j in 0..<n {
                    x.append (data [pos])
                    pos += 1
                }
                // (var r, var size) = Rune.DecodeRune (x);
                code = UInt (r)
                pos -= 1
            } else {
                // Alternative: keep a buffer here that can be cleared on Reset(), and use that to process the data on partial inputs
                print ("Partial data, need to tell the caller that a partial UTF-8 string was received and process later")
                return
            }

            // MIGUEL-TODO: I suspect this needs to be a stirng in C# to cope with Grapheme clusters
            var ch = code

            // calculate print space
            // expensive call, therefore we save width in line buffer

            // TODO: This is wrong, we only have one byte at this point, we do not have a full rune.
            // The correct fix includes the upper parser tracking the "pending" data across invocations
            // until a valid UTF-8 string comes in, and *then* we can call this method
            // var chWidth = Rune.ColumnWidth ((Rune)code);

            // 1 until we get a fixed NStack
            var chWidth = 1;

            // get charset replacement character
            // charset are only defined for ASCII, therefore we only
            // search for an replacement char if code < 127
            if code < 127 && charset != nil {

                // MIGUEL-FIXME - this is broken for dutch cahrset that returns two letters "ij", need to figure out what to do
                if let str = charset! [UInt8 (code)] {
                    code = Int (str.first!.asciiValue!)
                    code = ch;
                }
            }
            if screenReaderMode {
                emitChar (ch)
            }

            // insert combining char at last cursor position
            // FIXME: needs handling after cursor jumps
            // buffer.x should never be 0 for a combining char
            // since they always follow a cell consuming char
            // therefore we can test for buffer.x to avoid overflow left
            if (chWidth == 0 && buffer.X > 0) {
                // MIGUEL TODO: in the original code the getter might return a null value
                // does this mean that JS returns null for out of bounsd?
                if (buffer.X >= 1 && buffer.X < bufferRow.Length) {
                    var chMinusOne = bufferRow [buffer.X - 1];
                    if (chMinusOne.Width == 0) {
                        // found empty cell after fullwidth, need to go 2 cells back
                        // it is save to step 2 cells back here
                        // since an empty cell is only set by fullwidth chars
                        if (buffer.X >= 2) {
                            var chMinusTwo = bufferRow [buffer.X - 2];

                            chMinusTwo.Code += ch;
                            chMinusTwo.Rune = UInt (code)
                            bufferRow [buffer.X - 2] = chMinusTwo; // must be set explicitly now
                        }
                    } else {
                        chMinusOne.Code += ch;
                        chMinusOne.Rune = UInt (code)
                        bufferRow [buffer.X - 1] = chMinusOne; // must be set explicitly now
                    }
                }
                pos += 1
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
                        terminal.scroll (isWrapped: true)
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
                        pos += 1
                        continue;
                    }
                    // FIXME: Do we have to set buffer.x to cols - 1, if not wrapping?
                    buffer.X = cols - 1;
                }
            }

            var empty = CharData.Null
            empty.attribute = curAttr
            // insert mode: move characters to right
            if insertMode {
                // right shift cells according to the width
                bufferRow.insertCells (buffer.x, chWidth, empty)
                // test last cell - since the last cell has only room for
                // a halfwidth char any fullwidth shifted there is lost
                // and will be set to eraseChar
                var lastCell = bufferRow [cols - 1]
                if lastCell.width == 2 {
                    bufferRow [cols - 1] = empty
                }
            }

            // write current char to buffer and advance cursor
            var charData = CharData (curAttr, UInt (code), chWidth, ch)
            bufferRow [buffer.X++] = charData;

            // fullwidth char - also set next cell to placeholder stub and advance cursor
            // for graphemes bigger than fullwidth we can simply loop to zero
            // we already made sure above, that buffer.x + chWidth will not overflow right
            if chWidth > 0 {
                chWidth -= 1
                while chWidth != 0 {
                    bufferRow [buffer.x++] = empty
                    chWidth -= 1
                }
            }
        }
        terminal.updateRange (buffer.y)
        #endif
    }

    func insertChars (_ pars: [Int])
    {
        // TODO
    }
    
    
    /**
     * Sends the provided text to the connected backend
     */
    public func sendResponse (text: String)
    {
        tdel.send (data: ([UInt8] (text.utf8))[...])
    }
    
    public func error (_ text: String)
    {
        print("Error: \(text)")
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
        if y > 0 {
            if y < refreshStart {
                refreshStart = y
            }
            if y > refreshEnd {
                refreshEnd = y
            }
        }
    }
    
    /**
     * Returns the starting and ending lines that need to be redrawn, or the values will
     * contain (Int.max, -1) respectively if no part of the screen needs to be updated.
     */
    public func getUpdateRange () -> (startY: Int, endY: Int)
    {
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
    func index ()
    {
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
    
    func setgLevel (_ v: UInt8)
    {
        gLevel = v
        if let cs = CharSets.all [v] {
            charset = cs
        } else {
            charset = nil
        }
    }
    
    func eraseAttr () -> Int32
    {
        (CharData.defaultAttr & ~0x1ff) | curAttr & 0x1ff
    }

    func setgCharset (_ v: UInt8, charset: [UInt8: String])
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
        self.cols = newCols
        self.rows = newRows
        buffer.resize(newCols: newCols, newRows: newRows)
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
    }

    func setVT200MouseStyle ()
    {
        vt200Mouse = true
        mouseEvents = true

        mouseSendsRelease = true
        mouseSendsAllMotion = false
        mouseSendsWheel = true
        mouseSendsModifiers = false
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
            let sres = "\u{1b}[<\(bflags);\(x+1);\(y+1)\(m)"
            tdel.send (data: Array (sres.utf8)[...])
            return;
        }
        if vt200Mouse {
            // TODO
        }
        var res : [UInt8] = [0x1b /* ESC */, 0x5b /* [ */ , 0x4d /* M' */ ];
        encode (data: &res, ch: buttonFlags+32);
        encode (data: &res, ch: x+33);
        encode (data: &res, ch: y+33);
        tdel.send (data: res [...])
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
    
    var terminalTitle: String = ""
    
    public func setTitle (text: String)
    {
        terminalTitle = text
        tdel.setTerminalTitle(source: self, title: text)
    }
    
    func reverseIndex ()
    {
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
    public func getEnvironmentVariables (termName: String? = nil) -> [String]
    {
        var l : [String] = []
        let t = termName == nil ? "xterm-256color" : termName!
        l.append ("TERM=\(t)")
        
        // Without this, tools like "vi" produce sequences that are not UTF-8 friendly
        l.append ("LANG=en_US.UTF-8");
        let env = ProcessInfo.processInfo.environment
        for x in ["LOGNAME", "USER", "DISPLAY", "LC_TYPE", "USER", "HOME", "PATH"] {
            if env.keys.contains(x) {
                l.append ("\(x)=\(env[x]!)")
            }
        }
        return l
    }
}
