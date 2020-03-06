//
//  MacTerminalView.swift
//  
//
//  Created by Miguel de Icaza on 3/4/20.
//

#if os(OSX)
import Foundation
import AppKit
import CoreText

// The CaretView is used to show the cursor
class CaretView: NSView {
    public override init (frame: CGRect)
    {
        super.init(frame: frame)
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public var caretColor: NSColor! {
        didSet (newValue) {
            layer?.borderColor = newValue.cgColor
            if focused {
                layer?.backgroundColor = newValue.cgColor
                layer?.borderWidth = 0
            } else {
                layer?.borderWidth = 1
            }
        }
    }
    
    public var focused: Bool! {
        didSet (newValue) {
            if newValue {
                layer?.backgroundColor = caretColor.cgColor
                layer?.borderWidth = 0
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                layer?.borderWidth = 2
            }
        }
    }
}

protocol TerminalViewDelegate {
    func sizeChanged (newCols: Int, newRows: Int)
}

public class TerminalView: NSView, TerminalDelegate, NSTextInputClient {

    public func bufferActivated(source: Terminal) {
        
    }
    
    public func emitData(source: Terminal, text: String) {
        
    }
    
    public func showCursor(source: Terminal) {
        //
    }
    
    public func setTerminalTitle(source: Terminal, title: String) {
        //
    }
    
    public func sizeChanged(source: Terminal) {
        //
    }
    
    public func scrolled(source: Terminal, yDisp: Int) {
        //
    }
    
    public func linefeed(source: Terminal) {
        //
    }
    
    var terminal: Terminal!
    var fontNormal: NSFont!
    var fontBold: NSFont!
    var fontItalic: NSFont!
    var fontBoldItalic: NSFont!
    var cellWidth, cellHeight, cellDelta: CGFloat!
    var caretView: CaretView!
    var buffer: CircularList<NSAttributedString>!
    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    var tdel: TerminalViewDelegate?
    var selectionView: NSView!
    var selection: SelectionService = SelectionService ()
    
    public override init (frame: CGRect)
    {
        super.init (frame: frame)
        setup (rect: frame)
    }
    
    public required init? (coder: NSCoder)
    {
        super.init (coder: coder)
        setup (rect: self.bounds)
    }
    
    func setup (rect: CGRect)
    {
        fontNormal = NSFont(name: "Lucida Sans Typewriter", size: 14) ?? NSFont(name: "Courier", size: 14)!
        fontBold = NSFont(name: "Lucida Sans Typewriter Bold", size: 14) ?? NSFont(name: "Courier Bold", size: 14)!
        fontItalic = NSFont(name: "Lucida Sans Typewriter Oblique", size: 14) ?? NSFont(name: "Courier Oblique", size: 14)!
        fontBoldItalic = NSFont(name: "Lucida Sans Typewriter Bold Oblique", size: 14) ?? NSFont(name: "Courier Bold Oblique", size: 14)!
        let textBounds = computeCellDimensions()
        
        let options = TerminalOptions ()
        options.cols = Int (rect.width / cellWidth)
        options.rows = Int (rect.height / cellHeight)
        terminal = Terminal(delegate: self, options: options)
        fullBufferUpdate ()
        
        caretView = CaretView (frame: CGRect (x: 0, y: cellDelta, width: cellWidth, height: cellHeight))
        caretView.focused = false
        
        addSubview(caretView)
        
        caretView.caretColor = NSColor (colorSpace: NSColor.blue.colorSpace, hue: 0.4, saturation: 0.2, brightness: 0.9, alpha: 0.5)
        selectionView = NSView (frame: CGRect (x: 0, y: 0, width: 0, height: 0))
        search = SearchService (terminal: terminal)
    }
    
    public var optionAsMetaKey: Bool = true
    
    func computeCellDimensions () -> CGRect
    {
        let line = CTLineCreateWithAttributedString (NSAttributedString (string: "W", attributes: [NSAttributedString.Key.font: fontNormal!]))
        
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        cellWidth = bounds.width
        cellHeight = bounds.height
        cellDelta = bounds.minY
        return bounds
    }
    
    var attributes: [Int32: [NSAttributedString.Key:Any]] = [:]
    
    var colors: [NSColor?] = Array.init(repeating: nil, count: 257)

    func mapColor (color: Int, isFg: Bool) -> NSColor
    {
        // The default color
        if color == Terminal.defaultColor {
            if isFg {
                return NSColor.black
            } else {
                return NSColor.clear
            }
        } else if color == Terminal.defaultInvertedColor {
            if isFg {
                return NSColor.white
            } else {
                return NSColor.black
            }
        }

        if let c = colors [color] {
            return c
        }
        
        let tcolor = Color.defaultAnsiColors [color]

        let newColor = NSColor.init(calibratedRed: CGFloat (tcolor.red) / 255.0,
                                            green: CGFloat (tcolor.green) / 255.0,
                                             blue: CGFloat (tcolor.blue) / 255.0,
                                            alpha: 1.0)
        colors [color] = newColor
        return newColor
    }

    //
    // Given a vt100 attribute, return the NSAttributedString attributes used to render it
    //
    func getAttributes (_ attribute: Int32) -> [NSAttributedString.Key:Any]?
    {
        var bg = attribute & 0x1ff
        var fg = (attribute >> 9) & 0x1ff
        let flags = CharacterAttribute (attribute: attribute)
        
        if flags.contains(.inverse) {
            swap(&bg, &fg)
            
            if fg == Terminal.defaultColor {
                fg = Terminal.defaultInvertedColor
            }
            if bg == Terminal.defaultColor {
                bg = Terminal.defaultInvertedColor
            }
        }
        
        if let result = attributes [attribute] {
            return result
        }
        
        var font: NSFont
        if flags.contains (.bold){
            if flags.contains (.italic) {
                font = fontBoldItalic
            } else {
                font = fontBold
            }
        } else if flags.contains (.italic) {
            font = fontItalic
        } else {
            font = fontNormal
        }
        
        var nsattr: [NSAttributedString.Key:Any] = [
            .font: font,
            .foregroundColor: mapColor (color: Int (fg), isFg: true),
            .backgroundColor: mapColor (color: Int (bg), isFg: false)
        ]
        if flags.contains (.underline) {
            nsattr [.underlineColor] = mapColor (color: Int (fg), isFg: true)
            nsattr [.underlineStyle] = NSUnderlineStyle.single
        }
        attributes [attribute] = nsattr
        return nsattr
    }
    
    func buildAttributedString (line: BufferLine, cols: Int) -> NSAttributedString
    {
        let res = NSMutableAttributedString ()
        var attr: Int32 = 0
        
        var str = ""
        for col in 0..<cols {
            let ch: CharData = line[col]
            if col == 0 {
                attr = ch.attribute
            } else {
                if attr != ch.attribute {
                    res.append(NSAttributedString (string: str, attributes: getAttributes (attr)))
                    str = ""
                    attr = ch.attribute
                }
            }
            str.append(ch.getCharacter())
        }
        return res
    }
    
    //
    // Updates the contents of the NSAttributedString buffer from the contents of the terminal.buffer character array
    //
    func fullBufferUpdate ()
    {
        let rows = terminal.rows
        if buffer == nil {
            buffer = CircularList<NSAttributedString> (maxLength: terminal.buffer.lines.maxLength)
        } else {
            if terminal.buffer.lines.maxLength > buffer.maxLength {
                buffer.maxLength = terminal.buffer.lines.maxLength
            }
        }
        
        let cols = terminal.cols
        for row in 0..<rows {
            buffer [row] = buildAttributedString (line: terminal.buffer.lines [row], cols: cols)
        }
    }
    
    func updateCursorPosition ()
    {
        var pos = getCaretPos (terminal.buffer.x, terminal.buffer.y + terminal.buffer.yBase)
        
        caretView.frame = CGRect (
            // -1 to pad outside the character a little bit
            x: pos.x - 1,
            // -2 to get the top of the selection to fit over the top of the text properly
            // and to align with the cursor
            y: pos.y - 1,// - cellDelta + 2,
            //Frame.Height - cellHeight - ((terminal.Buffer.Y + terminal.Buffer.YBase - terminal.Buffer.YDisp) * cellHeight - cellDelta - 2),
            // +2 to pad outside the character a little bit on the other side
            width: cellWidth + 2,
            height: cellHeight + 0);
    }

    func getCaretPos(_ x: Int, _ y: Int) -> (x: CGFloat, y: CGFloat)
    {
        let x_ = CGFloat (x) * cellWidth
        let yoff: Int = y - terminal.buffer.yDisp
        
        let y_ = frame.height - cellHeight - (CGFloat (yoff) * cellHeight)
        return (x_, y_)
    }

    // Does not use a default argument and merge, because it is called back
    func updateDisplay ()
    {
        updateDisplay (notifyAccessibility: true)
    }
    
    func updateDisplay (notifyAccessibility: Bool)
    {
        let (rowStart, rowEnd) = terminal.getUpdateRange()
        
        terminal.clearUpdateRange ()
        
        var cols = terminal.cols
        var tb = terminal.buffer
        
        for row in rowStart..<rowEnd {
            buffer [row + tb.yDisp] = buildAttributedString (line: terminal.buffer.lines [row + tb.yDisp], cols: cols)
        }
        
        updateCursorPosition ();
        
        // Should compute the rectangle instead
        // print ("Dirty range: \(rowStart),\(rowEnd)");
        let ye: CGFloat = (CGFloat (rowEnd) * cellHeight - cellDelta - 1)
        let ypos: CGFloat = frame.height - cellHeight - ye
        
        var region = CGRect (x: 0,
                              y: ypos,
                              width: frame.width,
                              height: (cellHeight - cellDelta) * CGFloat (rowEnd-rowStart+1))
        
        setNeedsDisplay (region)
        pendingDisplay = false
        
        if (notifyAccessibility) {
            accessibility.invalidate ()
            NSAccessibility.post(element: self, notification: .valueChanged)
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
        }
    }
    
    // Simple tester API.
    public func Feed (text: String)
    {
        search.invalidate ()
        terminal.feed (text: text)
        queuePendingDisplay ()
    }

    //
    // The code below is intended to not repaint too often, which can produce flicker, for example
    // when the user refreshes the display, and this repains the screen, as dispatch delivers data
    // in blocks of 1024 bytes, which is not enough to cover the whole screen, so this delays
    // the update for a 1/600th of a second.
    var pendingDisplay: Bool = false
    func queuePendingDisplay ()
    {
        // throttle
        if !pendingDisplay {
            pendingDisplay = true
            DispatchQueue.main.asyncAfter(deadline: DispatchTime (uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 16670000*2),
                                          execute: updateDisplay)
        }
    }

    func feed (byteArray: ArraySlice<UInt8>)
    {
        search.invalidate ()
        terminal.feed (buffer: byteArray)

        // The problem is calling UpdateDisplay here, because there is still data pending.
        queuePendingDisplay ()

    }

    public override func cursorUpdate(with event: NSEvent)
    {
        NSCursor.iBeam.set ()
    }

    func makeFirstResponder ()
    {
        window?.makeFirstResponder (self)
    }
    
    public override var frame: NSRect {
        get {
            return super.frame
        }
        set(newValue) {
            let oldSize = super.frame.size
            super.frame = newValue

            let newRows = Int (newValue.height / cellHeight)
            let newCols = Int (newValue.width / cellWidth)

            if newCols != terminal.cols || newRows != terminal.rows {
                terminal.resize (cols: newCols, rows: newRows)
                fullBufferUpdate ()
            }

            // make the selection view the entire visible portion of the view
            // we will mask the selected text that is visible to the user
            selectionView.frame = bounds

            updateCursorPosition ()
            
            accessibility.invalidate ()
            search.invalidate ()

            tdel?.sizeChanged (newCols: newCols, newRows: newRows)
            
        }
    }

    public var userInput: (_ data: ArraySlice<UInt8>) -> () =  { data in }
    
    public func send(data: ArraySlice<UInt8>) {
        ensureCaretIsVisible ()
        self.userInput (data)
    }
    
    public func send (txt: String) {
        let array = [UInt8] (txt.utf8)
        send (data: array[...])
    }
    
    public func send (_ bytes: [UInt8]) {
        send (data: (bytes)[...])
    }

    public var hasFocus: Bool = false {
        didSet (newValue) {
            caretView.focused = newValue
        }
    }
    
    func ensureCaretIsVisible ()
    {
        abort ()
    }
    //
    // NSTextInputClient protocol implementation
    //
    public override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            hasFocus = true
        }
        return response
    }

    public override func resignFirstResponder() -> Bool {
        let response = super.resignFirstResponder()
        if response {
            hasFocus = false
        }
        return response
    }
    
    public override var acceptsFirstResponder: Bool {
        get {
            return true
        }
    }

    public override func keyDown(with event: NSEvent) {
        selection.active = false
        var eventFlags = event.modifierFlags
        
        // Handle Option-letter to send the ESC sequence plus the letter as expected by terminals
        if eventFlags.contains (.option) {
            if let rawCharacter = event.charactersIgnoringModifiers {
                send (EscapeSequences.CmdEsc)
                send (txt: rawCharacter)
            }
            return
        } else if eventFlags.contains (.control) {
            // Sends the control sequence
            if let ch = event.charactersIgnoringModifiers {
                let arr = [UInt8](ch.utf8)
                if arr.count == 1 {
                    let ch = Character (UnicodeScalar (arr [0]))
                    
                    let d = ch.uppercased ()
                    if d >= "A" && d <= "Z" {
                        let ch2 = d.first!
                        
                        send ([ (ch2.asciiValue! - 0x40 /* - 'A' + 1 */) ])
                    }
                    return
                }
            }
        } else if eventFlags.contains (.function) {
            if let str = event.charactersIgnoringModifiers {
                if let fs = str.unicodeScalars.first {
                    let c = Int (fs.value)
                    switch c {
                    case NSF1FunctionKey:
                        send (EscapeSequences.CmdF [0])
                    case NSF2FunctionKey:
                        send (EscapeSequences.CmdF [1])
                    case NSF3FunctionKey:
                        send (EscapeSequences.CmdF [2])
                    case NSF4FunctionKey:
                        send (EscapeSequences.CmdF [3])
                    case NSF5FunctionKey:
                        send (EscapeSequences.CmdF [4])
                    case NSF6FunctionKey:
                        send (EscapeSequences.CmdF [5])
                    case NSF7FunctionKey:
                        send (EscapeSequences.CmdF [6])
                    case NSF8FunctionKey:
                        send (EscapeSequences.CmdF [7])
                    case NSF9FunctionKey:
                        send (EscapeSequences.CmdF [8])
                    case NSF10FunctionKey:
                        send (EscapeSequences.CmdF [9])
                    case NSF11FunctionKey:
                        send (EscapeSequences.CmdF [10])
                    case NSF12FunctionKey:
                        send (EscapeSequences.CmdF [11])
                    case NSDeleteFunctionKey:
                        send (EscapeSequences.CmdDelKey)
                    case NSUpArrowFunctionKey:
                        send (EscapeSequences.MoveUpNormal)
                    case NSDownArrowFunctionKey:
                        send (EscapeSequences.MoveDownNormal)
                    case NSLeftArrowFunctionKey:
                        send (EscapeSequences.MoveLeftNormal)
                    case NSRightArrowFunctionKey:
                        send (EscapeSequences.MoveRightNormal)
                    case NSPageUpFunctionKey:
                        abort()
                    case NSPageDownFunctionKey:
                        abort()
                    default:
                        break
                    }
                }
            }
            return
        }

        interpretKeyEvents([event])
    }
    
    public func insertText(_ string: Any, replacementRange: NSRange) {
        abort()
    }
    
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        abort()
    }
    
    public func unmarkText() {
        abort()
    }
    
    public func selectedRange() -> NSRange {
        abort()
    }
    
    public func markedRange() -> NSRange {
        abort()
    }
    
    public func hasMarkedText() -> Bool {
        abort()
    }
    
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        abort()
    }
    
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        abort()
    }
    
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        abort()
    }
    
    public func characterIndex(for point: NSPoint) -> Int {
        abort()
    }
    
    

}
#endif
