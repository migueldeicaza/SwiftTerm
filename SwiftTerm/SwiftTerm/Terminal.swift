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
        parser.csiHandlers [0x41] = { (pars, collect) in /* cursorUp */ }
        parser.csiHandlers [0x42] = { (pars, collect) in /* cursorDown */ }
        parser.csiHandlers [0x43] = { (pars, collect) in /* cursorForward */ }
        parser.csiHandlers [0x44] = { (pars, collect) in /* cursorBackward */ }
        parser.csiHandlers [0x45] = { (pars, collect) in /* CursorNextLine */ }
        parser.csiHandlers [0x46] = { (pars, collect) in /* CursorPrecedingLine */ }
        parser.csiHandlers [0x47] = { (pars, collect) in /* CursorCharAbsolute */ }
        parser.csiHandlers [0x48] = { (pars, collect) in /* CursorPosition */ }
        parser.csiHandlers [0x49] = { (pars, collect) in /* CursorForwardTab */ }
        parser.csiHandlers [0x4a] = { (pars, collect) in /* EraseInDisplay */ }
        parser.csiHandlers [0x4b] = { (pars, collect) in /* EraseInLine */ }
        parser.csiHandlers [0x4c] = { (pars, collect) in /* InsertLines */ }
        parser.csiHandlers [0x4d] = { (pars, collect) in /* DeleteLines */ }
        parser.csiHandlers [0x50] = { (pars, collect) in /* DeleteChars */ }
        parser.csiHandlers [0x53] = { (pars, collect) in /* ScrollUp */ }
        parser.csiHandlers [0x54] = { (pars, collect) in /* ScrollDown */ }
        // Next is: X
    }

    func handlePrint (_ data: ArraySlice<UInt8>)
    {
        // TODO
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
