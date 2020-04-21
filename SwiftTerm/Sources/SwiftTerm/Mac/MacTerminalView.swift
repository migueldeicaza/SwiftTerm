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
import CoreGraphics


public protocol TerminalViewDelegate: class {
    /**
     * The client code sending commands to the terminal has requested a new size for the terminal
     * Applications that support this should call the `TerminalView.getOptimalFrameSize`
     * to get the ideal frame size.
     *
     * This is needed for the rare cases where the remote client request 80 or 132 column displays,
     * it is a rare feature and you most likely can ignore this request.
     */
    func sizeChanged (source: TerminalView, newCols: Int, newRows: Int)
    
    /**
     * Request to change the title of the terminal.
     */
    func setTerminalTitle(source: TerminalView, title: String)
    
    /**
     * Request that date be sent to the application running inside the terminal.
     * - Parameter data: Slice of data that should be sent
     */
    func send (source: TerminalView, data: ArraySlice<UInt8>)
    
    /**
     * Invoked when the terminal has been scrolled and the new position is provided
     * - Parameter position: the relative position that the code was scrolled to, a value between 0 and 1
     */
    func scrolled (source: TerminalView, position: Double)
    
    /**
     * Invoked in response to the user clicking on a link, which is most likely a url, but is not
     * mandatory, so custom implementations receive a string, and they can act on this as a way
     * of communciating with the host if desired.   The default implementation calls NSWorkspace.shared.open()
     * on the URL.
     * - Parameter source: the terminalview that called this method
     * - Parameter link: the string that was encoded as a link by the client application, typically a url,
     * but could be anything, and could be used to communicate by the embedded application and the host
     * - Parameter params: the specification allows for key/value pairs to be provided, this contains the
     * key and value pairs that were provided
     */
    func requestOpenLink (source: TerminalView, link: String, params: [String:String])
}

/**
 * TerminalView provides an AppKit front-end to the `Terminal` termininal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 */
public class TerminalView: NSView, NSTextInputClient, NSUserInterfaceValidations {
    
    // User facing, customizable view options
    public struct Options {
        
        public struct Font {
            public let normal: NSFont
            let bold: NSFont
            let italic: NSFont
            let boldItalic: NSFont
            
            static var defaultFont: NSFont {
                if #available(OSX 10.15, *)  {
                    return NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                } else {
                    return NSFont(name: "Menlo Regular", size: NSFont.systemFontSize) ?? NSFont(name: "Courier", size: NSFont.systemFontSize)!
                }
            }
            
            public init(font normal: NSFont) {
                self.normal = normal
                self.bold = NSFontManager.shared.convert(normal, toHaveTrait: [.boldFontMask])
                self.italic = NSFontManager.shared.convert(normal, toHaveTrait: [.italicFontMask])
                self.boldItalic = NSFontManager.shared.convert(normal, toHaveTrait: [.italicFontMask, .boldFontMask])
            }
        }
        
        public struct Colors {
            public let useSystemColors: Bool
            public let foregroundColor: NSColor
            public let backgroundColor: NSColor
            
            public init(useSystemColors: Bool) {
                self.useSystemColors = useSystemColors
                self.foregroundColor = useSystemColors ? NSColor.textColor : NSColor(calibratedRed: 0.54, green: 0.54, blue: 0.54, alpha: 1)
                self.backgroundColor = useSystemColors ? NSColor.textBackgroundColor : NSColor.black
            }
        }
        
        public let font: Font
        public let colors: Colors
        
        public static let `default` = Options(font: Font(font: Font.defaultFont), colors: Colors(useSystemColors: false))
        
        public init(font: Font, colors: Colors) {
            self.font = font
            self.colors = colors
        }
    }
    
    public private(set) var options: Options {
        didSet {
            self.setupOptions()
        }
    }
    
    /**
     * The delegate that the TerminalView uses to interact with its hosting
     */
    public weak var delegate: TerminalViewDelegate?
    
    typealias CellDimension = CGSize
    
    var terminal: Terminal!
    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    var debug: TerminalDebugView?
    
    private var cellDimension: CellDimension!
    private var caretView: CaretView!
    private var selection: SelectionService!
    private var scroller: NSScroller!
    
    private var attrStrBuffer: CircularList<NSAttributedString>!
    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary of attributes for an NSAttributedString
    private var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    private var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    // Cache for the colors in the 0..255 range
    private var colors: [NSColor?] = Array(repeating: nil, count: 256)
    private var trueColors: [Attribute.Color:NSColor] = [:]
    
    public init(frame: CGRect, options: Options) {
        self.options = options
        super.init (frame: frame)
        setup()
    }
    
    public override init (frame: CGRect)
    {
        self.options = Options.default
        super.init (frame: frame)
        setup()
    }
    
    public required init? (coder: NSCoder)
    {
        self.options = Options.default
        super.init (coder: coder)
        setup()
    }
    
    /// Returns the underlying terminal emulator that the `TerminalView` is a view for
    public func getTerminal () -> Terminal
    {
        return terminal
    }
    
    private func setup()
    {
        wantsLayer = true
        
        setupScroller()
        setupOptions()
    }
    
    private func setupOptions() {
        layer?.backgroundColor = options.colors.backgroundColor.cgColor
        
        self.attributes = [:]
        self.urlAttributes = [:]
        self.colors = Array(repeating: nil, count: 256)
        self.trueColors = [:]
        // Calculation assume that all glyphs in the font have the same advancement.
        // Get the ascent + descent + leading from the font, already scaled for the font's size
        self.cellDimension = computeFontDimensions ()
        
        let terminalOptions = TerminalOptions(cols: Int((bounds.width - scroller.frame.width) / cellDimension.width),
                                              rows: Int(bounds.height / cellDimension.height))
        
        if terminal == nil {
            terminal = Terminal(delegate: self, options: terminalOptions)
        } else {
            terminal.options = terminalOptions
            terminal.setup(isReset: false)
        }
        
        attrStrBuffer = CircularList<NSAttributedString> (maxLength: terminal.buffer.lines.maxLength)
        attrStrBuffer.makeEmpty = makeEmptyLine
        
        fullBufferUpdate(terminal: terminal)
        
        selection = SelectionService(terminal: terminal)
        
        // Install carret view
        if caretView == nil {
            caretView = CaretView(frame: CGRect(origin: .zero, size: CGSize(width: cellDimension.width, height: cellDimension.height)))
            addSubview(caretView)
        } else {
            caretView.frame.size = CGSize(width: cellDimension.width, height: cellDimension.height)
        }
        
        search = SearchService (terminal: terminal)
        
        needsDisplay = true
    }
    
    // Computes the font dimensions once font.normal has been set
    private func computeFontDimensions () -> CellDimension
    {
        let lineAscent = CTFontGetAscent (options.font.normal)
        let lineDescent = CTFontGetDescent (options.font.normal)
        let lineLeading = CTFontGetLeading (options.font.normal)
        let cellHeight = ceil(lineAscent + lineDescent + lineLeading)
        let cellWidth = options.font.normal.maximumAdvancement.width
        return CellDimension(width: cellWidth, height: cellHeight)
    }
    
    @objc
    func scrollerActivated ()
    {
        switch scroller.hitPart {
        case .decrementPage:
            pageUp()
            scroller.doubleValue =  scrollPosition
        case .incrementPage:
            pageDown()
            scroller.doubleValue =  scrollPosition
        case .knob:
            scroll(toPosition: scroller.doubleValue)
        case .knobSlot:
            print ("Scroller .knobSlot clicked")
        case .noPart:
            print ("Scroller .noPart clicked")
        case .decrementLine:
            print ("Scroller .decrementLine clicked")
        case .incrementLine:
            print ("Scroller .incrementLine clicked")
        default:
            print ("Scroller: New value introduced")
        }
    }
    
    
    func setupScroller()
    {
        let style: NSScroller.Style = .legacy
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
        scroller = NSScroller(frame: NSRect(x: bounds.maxX - scrollerWidth, y: 0, width: scrollerWidth, height: bounds.height))
        scroller.autoresizingMask = [.minXMargin, .height]
        scroller.scrollerStyle = style
        scroller.knobProportion = 0.1
        scroller.isEnabled = false
        addSubview (scroller)
        scroller.action = #selector(scrollerActivated)
        scroller.target = self
    }
    
    public func bell(source: Terminal) {
        NSSound.beep()
    }
    
    public func bufferActivated(source: Terminal) {
        updateScroller ()
    }
    
    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        delegate?.send (source: self, data: data)
    }
    
    
    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     */
    public func getOptimalFrameSize () -> NSRect
    {
        return NSRect (x: 0, y: 0, width: cellDimension.width * CGFloat(terminal.cols) + scroller.frame.width, height: cellDimension.height * CGFloat(terminal.rows))
    }
    
    public func scrolled(source terminal: Terminal, yDisp: Int) {
        //selectionView.notifyScrolled(source: terminal)
        updateScroller()
        delegate?.scrolled(source: self, position: scrollPosition)
    }
    
    public func linefeed(source: Terminal) {
        selection.selectNone()
    }
    
    /**
     * Returns the thumb size in proportion to the visible content of the entire content, alternate buffers are not scrollable, so this returns 0
     */
    public var scrollThumbsize: CGFloat {
        get {
            if terminal.buffers!.isAlternateBuffer {
                return 0
            }
            
            // the thumb size is the proportion of the visible content of the
            // entire content but don't make it too small
            return max (CGFloat (terminal.rows) / CGFloat (terminal.buffer.lines.count), 0.01)
        }
    }
    
    /**
     * Gets a value indicating the relative position of the terminal viewport
     */
    public var scrollPosition: Double {
        get {
            if terminal.buffers.isAlternateBuffer || terminal.buffer.yDisp <= 0 {
                return 0
            }
            
            let maxScrollback = terminal.buffer.lines.count - terminal.rows
            if terminal.buffer.yDisp >= maxScrollback {
                return 1
            }
            
            return Double (terminal.buffer.yDisp) / Double (maxScrollback)
        }
    }
    
    func updateScroller ()
    {
        scroller.isEnabled = canScroll
        scroller.doubleValue = scrollPosition
        scroller.knobProportion = scrollThumbsize
    }
    
    /// <summary>
    /// Gets a value indicating whether or not the user can scroll the terminal contents
    /// </summary>
    public var canScroll: Bool {
        get {
            return !terminal.buffers.isAlternateBuffer &&
                terminal.buffer.hasScrollback &&
                terminal.buffer.lines.count > terminal.rows
        }
    }
    
    var userScrolling = false
    public func scroll (toPosition: Double)
    {
        userScrolling = true
        let oldPosition = terminal.buffer.yDisp
        
        let maxScrollback = terminal.buffer.lines.count - terminal.rows
        print ("maxScrollBack: \(maxScrollback)")
        var newScrollPosition = Int (Double (maxScrollback) * toPosition)
        
        if newScrollPosition < 0 {
            newScrollPosition = 0
        }
        if newScrollPosition > maxScrollback {
            newScrollPosition = maxScrollback
        }
        print ("newScrollpsitin: \(newScrollPosition)")
        
        if newScrollPosition != oldPosition {
            scrollTo(row: newScrollPosition)
        }
        userScrolling = false
    }
    
    /// Scrolls the content of the terminal one page up
    public func pageUp()
    {
        scrollUp (lines: terminal.rows)
    }
    
    /// Scrolls the content of the terminal one page down
    public func pageDown ()
    {
        scrollDown (lines: terminal.rows)
    }
    
    /// Scrolls up the content of the terminal the specified number of lines
    public func scrollUp (lines: Int)
    {
        let newPosition = max (terminal.buffer.yDisp - lines, 0)
        scrollTo (row: newPosition)
    }
    
    /// Scrolls down the content of the terminal the specified number of lines
    public func scrollDown (lines: Int)
    {
        let newPosition = max (0, min (terminal.buffer.yDisp + lines, terminal.buffer.lines.count - terminal.rows))
        scrollTo (row: newPosition)
    }
    
    func mapColor (color: Attribute.Color, isFg: Bool) -> NSColor
    {
        switch color {
        case .defaultColor:
            if isFg {
                return options.colors.foregroundColor
            } else {
                return options.colors.backgroundColor
            }
        case .defaultInvertedColor:
            if isFg {
                return options.colors.foregroundColor.inverseColor()
            } else {
                return options.colors.backgroundColor.inverseColor()
            }
        case .ansi256(let ansi):
            if let c = colors [Int (ansi)] {
                return c
            }
            
            let tcolor = Color.defaultAnsiColors [Int (ansi)]
            
            let newColor = NSColor(calibratedRed: CGFloat (tcolor.red) / 255.0,
                                   green: CGFloat (tcolor.green) / 255.0,
                                   blue: CGFloat (tcolor.blue) / 255.0,
                                   alpha: 1.0)
            colors [Int(ansi)] = newColor
            return newColor
            
        case .trueColor(let r, let g, let b):
            if let tc = trueColors [color] {
                return tc
            }
            let newColor = NSColor(calibratedRed: CGFloat (r) / 255.0,
                                   green: CGFloat (g) / 255.0,
                                   blue: CGFloat (b) / 255.0,
                                   alpha: 1.0)
            
            trueColors [color] = newColor
            return newColor
        }
    }
    
    //
    // Given a vt100 attribute, return the NSAttributedString attributes used to render it
    //
    func getAttributes (_ attribute: Attribute, withUrl: Bool) -> [NSAttributedString.Key:Any]?
    {
        let flags = attribute.style
        var bg = attribute.bg
        var fg = attribute.fg
        
        if flags.contains (.inverse) {
            swap (&bg, &fg)
            
            if fg == .defaultColor {
                fg = .defaultInvertedColor
            }
            if bg == .defaultColor {
                bg = .defaultInvertedColor
            }
        }
        
        if let result = withUrl ? urlAttributes [attribute] : attributes [attribute] {
            return result
        }
        
        var font: NSFont
        if flags.contains (.bold){
            if flags.contains (.italic) {
                font = options.font.boldItalic
            } else {
                font = options.font.bold
            }
        } else if flags.contains (.italic) {
            font = options.font.italic
        } else {
            font = options.font.normal
        }
        
        let fgColor = mapColor (color: fg, isFg: true)
        var nsattr: [NSAttributedString.Key:Any] = [
            .font: font,
            .foregroundColor: fgColor,
            .backgroundColor: mapColor(color: bg, isFg: false)
        ]
        if flags.contains (.underline) {
            nsattr [.underlineColor] = fgColor
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if flags.contains (.crossedOut) {
            nsattr [.strikethroughColor] = fgColor
            nsattr [.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if withUrl {
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue
            nsattr [.underlineColor] = fgColor
            
            // Add to cache
            urlAttributes [attribute] = nsattr
        } else {
            // Just add to cache
            attributes [attribute] = nsattr
        }
        return nsattr
    }
    
    //
    // Given a line of text with attributes, returns the NSAttributedString, suitable to be drawn
    //
    func buildAttributedString (row: Int, line: BufferLine, cols: Int, prefix: String = "") -> NSAttributedString
    {
        let res = NSMutableAttributedString ()
        var attr = Attribute.empty
        var hasUrl = false
        
        var str = prefix
        for col in 0..<cols {
            let ch: CharData = line[col]
            if col == 0 {
                attr = ch.attribute
                hasUrl = ch.hasUrl
            } else {
                let chhas = ch.hasUrl
                if attr != ch.attribute || chhas != hasUrl {
                    res.append(NSAttributedString (string: str, attributes: getAttributes (attr, withUrl: hasUrl)))
                    str = ""
                    attr = ch.attribute
                    hasUrl = chhas
                }
            }
            str.append(ch.code == 0 ? " " : ch.getCharacter ())
        }
        res.append (NSAttributedString(string: str, attributes: getAttributes(attr, withUrl: hasUrl)))
        updateSelectionAttributesIfNeeded(attributedLine: res, row: row, cols: cols)
        // This gives us a large chunk of our performance back, from 7.5 to 5.5 seconds on
        // time for x in 1 2 3 4 5 6; do cat UTF-8-demo.txt; done
        //res.fixAttributes(in: NSRange(location: 0, length: res.length))
        return res
    }
    
    /// Apply selection attributes
    /// TODO: Optimize the logic below
    private func updateSelectionAttributesIfNeeded(attributedLine attributedString: NSMutableAttributedString, row: Int, cols: Int) {
        guard let selection = self.selection, selection.active else {
            attributedString.removeAttribute(.selectionBackgroundColor)
            return
        }
        
        let startRow = selection.start.row
        let endRow = selection.end.row
        
        let startCol = selection.start.col
        let endCol = selection.end.col
        
        var selectionRange: NSRange = .empty
        
        // single row
        if endRow == startRow && startRow == row {
            if startCol < endCol {
                selectionRange = NSRange(location: startCol, length: endCol - startCol)
            } else if startCol > endCol {
                selectionRange = NSRange(location: endCol, length: startCol - endCol)
            }
        } else if endRow > startRow {
            // first row
            if startRow == row && endRow > row {
                selectionRange = NSRange(location: startCol, length: cols - startCol)
            }
            
            // in between
            if startRow < row && endRow > row {
                selectionRange = NSRange(location: 0, length: cols)
            }
            
            // last row
            if startRow < row && endRow == row {
                selectionRange = NSRange(location: 0, length: endCol)
            }
        } else if endRow < startRow {
            
            // first row
            if endRow == row && startRow > row {
                selectionRange = NSRange(location: endCol, length: cols - endCol)
            }
            
            // in between
            if startRow > row && endRow < row {
                selectionRange = NSRange(location: 0, length: cols)
            }
            
            // last row
            if endRow < row && startRow == row {
                selectionRange = NSRange(location: 0, length: startCol)
            }
        }
        
        if selectionRange != .empty {
            attributedString.addAttribute(.selectionBackgroundColor, value: NSColor.selectedTextBackgroundColor, range: selectionRange)
        }
    }
    
    //
    // Updates the contents of the NSAttributedString buffer from the contents of the terminal.buffer character array
    //
    func fullBufferUpdate (terminal: Terminal)
    {
        if terminal.buffer.lines.maxLength > attrStrBuffer.maxLength {
            attrStrBuffer.maxLength = terminal.buffer.lines.maxLength
        }
        
        let cols = terminal.cols
        for row in (terminal.buffer.yDisp)...(terminal.rows + terminal.buffer.yDisp) {
            attrStrBuffer [row] = buildAttributedString (row: row, line: terminal.buffer.lines [row], cols: cols, prefix: "")
        }
        attrStrBuffer.count = terminal.rows
    }
    
    /// Update selection attributes without rebuilding lines
    private func updateSelectionInBuffer (terminal: Terminal)
    {
        if terminal.buffer.lines.maxLength > attrStrBuffer.maxLength {
            attrStrBuffer.maxLength = terminal.buffer.lines.maxLength
        }
        
        let cols = terminal.cols
        for row in (terminal.buffer.yDisp)...(terminal.rows + terminal.buffer.yDisp) {
            let attributedString = attrStrBuffer [row]
            
            if selection.hasSelectionRange == false {
                if attributedString.attributeKeys.contains(NSAttributedString.Key.selectionBackgroundColor.rawValue) {
                    let updatedString = NSMutableAttributedString(attributedString: attributedString)
                    updatedString.removeAttribute(.selectionBackgroundColor)
                    attrStrBuffer [row] = updatedString
                }
            }
            
            if selection.hasSelectionRange == true {
                if !attributedString.attributeKeys.contains(NSAttributedString.Key.selectionBackgroundColor.rawValue) {
                    let updatedString = NSMutableAttributedString(attributedString: attributedString)
                    updatedString.removeAttribute(.selectionBackgroundColor)
                    updateSelectionAttributesIfNeeded(attributedLine: updatedString, row: row, cols: cols)
                    attrStrBuffer [row] = updatedString
                }
            }
        }
    }
    
    func makeEmptyLine (_ index: Int) -> NSAttributedString
    {
        let line = terminal.buffer.lines [index]
        return buildAttributedString (row: index, line: line, cols: terminal.cols, prefix: "")
    }
    
    /// Update visible area
    func updateDisplay (notifyAccessibility: Bool)
    {
        updateCursorPosition()
        guard let (rowStart, rowEnd) = terminal.getUpdateRange () else {
            return
        }
        
        terminal.clearUpdateRange ()
        
        let cols = terminal.cols
        let tb = terminal.buffer
        
        for row in (rowStart + tb.yDisp)...(rowEnd + tb.yDisp) {
            let line = terminal.buffer.lines [row]
            
            attrStrBuffer [row] = buildAttributedString (row: row, line: line, cols: cols, prefix: "")
        }
        
        #if true
        // FIXME: Calculations are broken because based on estimatedLineHeight.
        // See https://github.com/migueldeicaza/SwiftTerm/issues/71 for example
        let baseLine = frame.height
        var region = CGRect (x: 0,
                             y: baseLine - (cellDimension.height + CGFloat(rowEnd) * cellDimension.height),
                             width: frame.width,
                             height: CGFloat(rowEnd-rowStart + 1) * cellDimension.height)
        
        // If we are the last line, we should also queue a refresh for the "remaining" bits at the
        // end which can be redrawn by large unicode
        if rowEnd == terminal.rows - 1 {
            let oh = region.height
            let oy = region.origin.y
            region = CGRect (x: 0, y: 0, width: frame.width, height: oh + oy)
        }
        //print ("Region: \(region)")
        setNeedsDisplay(region)
        #else
        needsDisplay = true
        #endif
        
        pendingDisplay = false
        debug?.update()
        
        if (notifyAccessibility) {
            accessibility.invalidate ()
            NSAccessibility.post (element: self, notification: .valueChanged)
            NSAccessibility.post (element: self, notification: .selectedTextChanged)
        }
    }
    
    #if false
    override public func setNeedsDisplay(_ invalidRect: NSRect) {
        print ("setNeeds: \(invalidRect)")
        super.setNeedsDisplay(invalidRect)
    }
    #endif
    
    // TODO: Clip here
    override public func draw (_ dirtyRect: NSRect) {
        guard let currentContext = NSGraphicsContext.current?.cgContext else {
            return
        }
        
        let lineDescent = CTFontGetDescent(options.font.normal)
        let lineLeading = CTFontGetLeading(options.font.normal)
        
        // draw lines
        for row in terminal.buffer.yDisp..<terminal.rows + terminal.buffer.yDisp {
            let lineOrigin = CGPoint(x: 0, y: frame.height - (cellDimension.height * (CGFloat(row - terminal.buffer.yDisp + 1))))
            let ctline = CTLineCreateWithAttributedString(attrStrBuffer [row])
            
            var col = 0
            for run in CTLineGetGlyphRuns(ctline) as? [CTRun] ?? [] {
                let runGlyphsCount = CTRunGetGlyphCount(run)
                let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                let runFont = runAttributes[.font] as! NSFont
                
                
                let runGlyphs = [CGGlyph](unsafeUninitializedCapacity: runGlyphsCount) { (bufferPointer, count) in
                    CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                    count = runGlyphsCount
                }
                
                var positions = runGlyphs.enumerated().map { (i: Int, glyph: CGGlyph) -> CGPoint in
                    CGPoint(x: lineOrigin.x + (cellDimension.width * CGFloat(col + i)), y: lineOrigin.y + ceil(lineLeading + lineDescent))
                }
                
                var backgroundColor: NSColor? = nil
                if runAttributes.keys.contains(.selectionBackgroundColor) {
                    backgroundColor = runAttributes[.selectionBackgroundColor] as? NSColor
                } else if runAttributes.keys.contains(.backgroundColor) {
                    backgroundColor = runAttributes[.backgroundColor] as? NSColor
                }
                
                if let backgroundColor = backgroundColor {
                    currentContext.saveGState ()
                    
                    currentContext.setShouldAntialias (false)
                    currentContext.setLineCap (.square)
                    currentContext.setLineWidth(0)
                    currentContext.setFillColor(backgroundColor.cgColor)
                    
                    let transform = CGAffineTransform (translationX: positions[0].x, y: 0)
                    let rect = CGRect (origin: lineOrigin, size: CGSize (width: CGFloat (cellDimension.width * CGFloat(runGlyphsCount)), height: cellDimension.height))
                    rect.applying(transform).fill(using: .destinationOver)
                    
                    currentContext.restoreGState()
                }
                
                options.colors.foregroundColor.set()
                
                if runAttributes.keys.contains(.foregroundColor) {
                    let color = runAttributes[.foregroundColor] as! NSColor
                    let cgColor = color.cgColor
                    if let colorSpace = cgColor.colorSpace {
                        currentContext.setFillColorSpace(colorSpace)
                    }
                    currentContext.setFillColor(cgColor)
                }
                
                CTFontDrawGlyphs(runFont, runGlyphs, &positions, positions.count, currentContext)
                
                // Draw other attributes
                drawRunAttributes(runAttributes, glyphPositions: positions, in: currentContext)
                
                col += runGlyphsCount
            }
            
            // set caret position
            if terminal.buffer.y == row - terminal.buffer.yDisp {
                updateCursorPosition()
            }
        }
    }
    
    func updateCursorPosition()
    {
        //let lineOrigin = CGPoint(x: 0, y: frame.height - (cellDimension.height * (CGFloat(terminal.buffer.y - terminal.buffer.yDisp + 1))))
        //caretView.frame.origin = CGPoint(x: lineOrigin.x + (cellDimension.width * CGFloat(terminal.buffer.x)), y: lineOrigin.y)
        let buffer = terminal.buffer
        let vy = buffer.yBase + buffer.y
        
        if vy >= buffer.yDisp + buffer.rows {
            caretView.removeFromSuperview()
            return
        } else {
            addSubview(caretView)
        }
        let lineOrigin = CGPoint(x: 0, y: frame.height - (cellDimension.height * (CGFloat(buffer.y-(buffer.yDisp-buffer.yBase)+1))))
        caretView.frame.origin = CGPoint(x: lineOrigin.x + (cellDimension.width * CGFloat(buffer.x)), y: lineOrigin.y)
    }
    
    private func drawRunAttributes(_ attributes: [NSAttributedString.Key : Any], glyphPositions positions: [CGPoint], in currentContext: CGContext) {
        currentContext.saveGState()
        
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        
        if attributes.keys.contains(.underlineStyle) {
            // draw underline at font.normal.underlinePosition baseline
            let underlineStyle = NSUnderlineStyle(rawValue: attributes[.underlineStyle] as? NSUnderlineStyle.RawValue ?? 0)
            let underlineColor = attributes[.underlineColor] as? NSColor ?? options.colors.foregroundColor
            let underlinePosition = options.font.normal.underlinePosition
            
            // draw line at the baseline
            currentContext.setShouldAntialias(false)
            currentContext.setStrokeColor(underlineColor.cgColor)
            
            let underlineThickness = max(round(scale * options.font.normal.underlineThickness) / scale, 0.5)
            for p in positions {
                switch underlineStyle {
                case let style where style.contains(.single):
                    let path = NSBezierPath()
                    path.move(to: p.applying(.init(translationX: 0, y: underlinePosition)))
                    path.line(to: p.applying(.init(translationX: ceil(cellDimension.width), y: underlinePosition)))
                    path.lineWidth = underlineThickness
                    switch underlineStyle {
                    case let pattern where pattern.contains(.patternDash):
                        let pattern: [CGFloat] = [2.0]
                        path.setLineDash(pattern, count: pattern.count, phase: 0)
                    default:
                        break
                    }
                    path.stroke()
                case let style where style.contains(.double):
                    let path1 = NSBezierPath()
                    path1.move(to: p.applying(.init(translationX: 0, y: underlinePosition)))
                    path1.line(to: p.applying(.init(translationX: ceil(cellDimension.width), y: underlinePosition)))
                    path1.lineWidth = underlineThickness
                    
                    let path2 = NSBezierPath()
                    path2.move(to: p.applying(.init(translationX: 0, y: underlinePosition - underlineThickness - 1)))
                    path2.line(to: p.applying(.init(translationX: ceil(cellDimension.width), y: underlinePosition - underlineThickness - 1)))
                    path2.lineWidth = underlineThickness
                    
                    switch underlineStyle {
                    case let pattern where pattern.contains(.patternDash):
                        let pattern: [CGFloat] = [2.0]
                        path1.setLineDash(pattern, count: pattern.count, phase: 0)
                        path2.setLineDash(pattern, count: pattern.count, phase: 0)
                    default:
                        break
                    }
                    path1.stroke()
                    path2.stroke()
                default:
                    preconditionFailure("Unsupported underline style.")
                    break
                }
            }
        }
        
        currentContext.restoreGState()
    }
    
    // Does not use a default argument and merge, because it is called back
    func updateDisplay ()
    {
        updateDisplay (notifyAccessibility: true)
        debug?.update()
        pendingDisplay = false
    }
    
    var pendingDisplay: Bool = false
    
    //
    // The code below is intended to not repaint too often, which can produce flicker, for example
    // when the user refreshes the display, and this repains the screen, as dispatch delivers data
    // in blocks of 1024 bytes, which is not enough to cover the whole screen, so this delays
    // the update for a 1/600th of a second.
    //
    // It is also cheap, so should be called when new data has been posted or received.
    func queuePendingDisplay ()
    {
        // throttle
        if !pendingDisplay {
            pendingDisplay = true
            DispatchQueue.main.asyncAfter(deadline: DispatchTime (uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 16670000*2),
                                          execute: updateDisplay)
        }
    }
    
    // Sends data to the terminal emulator for interpretation
    func feed (byteArray: ArraySlice<UInt8>)
    {
        search.invalidate ()
        terminal.feed (buffer: byteArray)
        queuePendingDisplay ()
    }
    
    // Sends data to the terminal emulator for interpretation
    public func feed (text: String)
    {
        search.invalidate ()
        terminal.feed (text: text)
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
            super.frame = newValue
            
            let newRows = Int (newValue.height / cellDimension.height)
            let newCols = Int ((newValue.width-scroller.frame.width) / options.font.normal.maximumAdvancement.width)
            
            if newCols != terminal.cols || newRows != terminal.rows {
                terminal.resize (cols: newCols, rows: newRows)
                fullBufferUpdate (terminal: terminal)
            }
            
            accessibility.invalidate ()
            search.invalidate ()
            
            delegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
        }
    }
    
    /**
     * Triggers a resize of the underlying terminal to the desired columsn and rows
     */
    public func resize (cols: Int, rows: Int)
    {
        terminal.resize (cols: cols, rows: rows)
        sizeChanged (source: terminal)
        terminal.reset()
    }
    
    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateScroller()
        selection.active = false
    }
    
    /**
     * Sends the specified slice of byte arrays to the program running under the terminal emulator
     * - Parameter data: the slice of an array to send to the client
     */
    public func send(data: ArraySlice<UInt8>) 
    {
        ensureCaretIsVisible ()
        delegate?.send (source: self, data: data)
    }
    
    /**
     * Sends the specified string encoded at utf8 to the program running under the terminal emulator
     * - Parameter txt: the string to send to the client
     */
    public func send (txt: String) {
        let array = [UInt8] (txt.utf8)
        send (data: array[...])
    }
    
    /**
     * Sends the specified array of bytes to the program running under the terminal emulator
     * - Parameter bytes: the bytes to send to the client
     */
    public func send (_ bytes: [UInt8]) {
        send (data: (bytes)[...])
    }
    
    private var _hasFocus = false
    public var hasFocus : Bool {
        get { _hasFocus }
        set {
            _hasFocus = newValue
            caretView.focused = newValue
        }
    }
    
    func scrollTo (row: Int, notifyAccessibility: Bool = true)
    {
        if row != terminal.buffer.yDisp {
            
            terminal.buffer.yDisp = row
            
            // tell the terminal we want to refresh all the rows
            terminal.refresh (startRow: 0, endRow: terminal.rows)
            
            // do the display update
            updateDisplay (notifyAccessibility: notifyAccessibility)
            //selectionView.notifyScrolled(source: terminal)
            delegate?.scrolled (source: self, position: scrollPosition)
            updateScroller()
            needsDisplay = true
        }
    }
    
    private func ensureCaretIsVisible ()
    {
        let realCaret = terminal.buffer.y + terminal.buffer.yBase
        let viewportEnd = terminal.buffer.yDisp + terminal.rows
        
        if realCaret >= viewportEnd || realCaret < terminal.buffer.yDisp {
            scrollTo (row: terminal.buffer.yBase)
        }
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
    
    // Tracking object, maintained by `startTracking` and `deregisterTrackingInterest`
    var tracking: NSTrackingArea? = nil
    
    // Turns on AppKit mouse event tracking - used both by the url highlighter and the mouse move,
    // when the client application has set MouseMove.anyEvent
    //
    // Can be invoked multiple times, use the "deregisterTrackingInterest" method to turn it off
    // which will take into account both the url highlighter state (which is bound to the command
    // key being pressed) and the client requirements
    func startTracking ()
    {
        if tracking == nil {
            tracking = NSTrackingArea (rect: frame, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: [:])
            addTrackingArea(tracking!)
        }
    }
    
    // Can be invoked by both the keyboard handler monitoring the command key, and the
    // mouse tracking system, only when both are off, this is turned off.
    func deregisterTrackingInterest ()
    {
        if commandActive == false && terminal.mouseMode != .anyEvent {
            if tracking != nil {
                removeTrackingArea(tracking!)
                tracking = nil
            }
        }
    }
    
    func turnOffUrlPreview ()
    {
        if commandActive {
            deregisterTrackingInterest()
            removePreviewUrl()
            commandActive = false
        }
    }
    
    // If true, the Command key has been pressed
    var commandActive = false
    
    // We monitor the flags changed to enable URL previews on mouse-hover like iTerm
    // when the Command key is pressed.
    
    public override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.command){
            commandActive = true
            startTracking()
            
            if let payload = getPayload(for: event) {
                previewUrl (payload: payload)
            }
        } else {
            turnOffUrlPreview ()
        }
        super.flagsChanged(with: event)
    }
    
    public override func mouseExited(with event: NSEvent) {
        turnOffUrlPreview()
        super.mouseExited(with: event)
    }
    
    //
    // We capture a handful of keydown events and pre-process those, and then let
    // interpretKeyEvents do the rest of the work, that includes text-insertion, and
    // keybinding mapping.
    //
    // That is why we do not handle things like the return key here, instead those are
    // handled by doCommand below.
    //
    // This currently handles the function keys here, but probably should be done in
    // doCommand/noop: - but more research needs to take place to figure out the priority
    // of those keys.
    //
    public override func keyDown(with event: NSEvent) {
        selection.active = false
        let eventFlags = event.modifierFlags
        
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
                    var value: UInt8
                    switch ch {
                    case "A"..."Z":
                        value = (ch.asciiValue! - 0x40 /* - 'A' + 1 */)
                    case "a"..."z":
                        value = (ch.asciiValue! - 0x60 /* - 'a' + 1 */)
                    case "\\":
                        value = 0x1c
                    case "_":
                        value = 0x1f
                    case "]":
                        value = 0x1d
                    case "[":
                        value = 0x1b
                    case "^":
                        value = 0x1e
                    case " ":
                        value = 0
                    default:
                        return
                    }
                    send ([value])
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
                        //                    case NSUpArrowFunctionKey:
                        //                        send (EscapeSequences.MoveUpNormal)
                        //                    case NSDownArrowFunctionKey:
                        //                        send (EscapeSequences.MoveDownNormal)
                        //                    case NSLeftArrowFunctionKey:
                        //                        send (EscapeSequences.MoveLeftNormal)
                        //                    case NSRightArrowFunctionKey:
                    //                        send (EscapeSequences.MoveRightNormal)
                    case NSPageUpFunctionKey:
                        pageUp ()
                    case NSPageDownFunctionKey:
                        pageDown()
                    default:
                        interpretKeyEvents([event])
                    }
                }
            }
            return
        }
        
        interpretKeyEvents([event])
    }
    
    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            send (EscapeSequences.CmdRet)
        case #selector(cancelOperation(_:)):
            send (EscapeSequences.CmdEsc)
        case #selector(deleteBackward(_:)):
            send ([0x7f])
        case #selector(moveUp(_:)):
            send (terminal.applicationCursor ? EscapeSequences.MoveUpApp : EscapeSequences.MoveUpNormal)
        case #selector(moveDown(_:)):
            send (terminal.applicationCursor ? EscapeSequences.MoveDownApp : EscapeSequences.MoveDownNormal)
        case #selector(moveLeft(_:)):
            send (terminal.applicationCursor ? EscapeSequences.MoveLeftApp : EscapeSequences.MoveLeftNormal)
        case #selector(moveRight(_:)):
            send (terminal.applicationCursor ? EscapeSequences.MoveRightApp : EscapeSequences.MoveRightNormal)
        case #selector(insertTab(_:)):
            send (EscapeSequences.CmdTab)
        case #selector(insertBacktab(_:)):
            send (EscapeSequences.CmdBackTab)
        case #selector(moveToBeginningOfLine(_:)):
            send (terminal.applicationCursor ? EscapeSequences.MoveHomeApp : EscapeSequences.MoveHomeNormal)
        case #selector(moveToEndOfLine(_:)):
            send (terminal.applicationCursor ? EscapeSequences.MoveEndApp : EscapeSequences.MoveEndNormal)
        case #selector(scrollPageUp(_:)):
            fallthrough
        case #selector(pageUp(_:)):
            if terminal.applicationCursor {
                send (EscapeSequences.CmdPageUp)
            } else {
                pageUp()
            }
        case #selector(scrollPageDown(_:)):
            fallthrough
        case #selector(pageDown(_:)):
            if terminal.applicationCursor {
                send (EscapeSequences.CmdPageDown)
            } else {
                pageDown()
            }
        case #selector(pageDownAndModifySelection(_:)):
            if terminal.applicationCursor {
                // TODO: view should scroll one page up.
            } else {
                send (EscapeSequences.CmdPageDown)
            }
            break;
        default:
            print ("Unhandle selector \(selector)")
        }
    }
    
    // NSTextInputClient protocol implementation
    public func insertText(_ string: Any, replacementRange: NSRange) {
        if let str = string as? NSString {
            send (txt: str as String)
        }
        // TODO: I do not think we actually need this needsDisplay, the data fed should bubble this up
        // needsDisplay = true
    }
    
    // NSTextInputClient protocol implementation
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // nothing
    }
    
    // NSTextInputClient protocol implementation
    public func unmarkText() {
        // nothing
    }
    
    // NSTextInputClient protocol implementation
    public func selectedRange() -> NSRange {
        guard let selection = self.selection, selection.active else {
            // This means "no selection":
            return NSRange.empty
        }
        
        var startLocation = (selection.start.row * terminal.buffer.rows) + selection.start.col
        var endLocation = (selection.end.row * terminal.buffer.rows) + selection.end.col
        if startLocation > endLocation {
            swap(&startLocation, &endLocation)
        }
        let length = endLocation - startLocation
        if length == 0 {
            return NSRange.empty
        }
        return NSRange(location: startLocation, length: endLocation - startLocation)
    }
    
    // NSTextInputClient protocol implementation
    public func markedRange() -> NSRange {
        print ("markedRange: This should return the actual range from the selection")
        
        // This means "no marked" - when we fix, we should address
        return NSRange.empty
    }
    
    // NSTextInputClient protocol implementation
    public func hasMarkedText() -> Bool {
        // print ("hasMarkedText: This should return the actual range from the selection")
        // TODO
        return false
    }
    
    // NSTextInputClient protocol implementation
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        print ("Attribuetd string")
        return nil
    }
    
    // NSTextInputClient Protocol implementation
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        // TODO print ("validAttributesForMarkedText: This should return the actual range from the selection")
        return []
    }
    
    // NSTextInputClient protocol implementation
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        
        if let r = window?.convertToScreen(convert(caretView!.frame, to: nil)) {
            return r
        }
        
        return .zero
    }
    
    // NSTextInputClient protocol implementation
    public func characterIndex(for point: NSPoint) -> Int {
        print ("characterIndex:for point: This should return the actual range from the selection")
        return NSNotFound
    }
    
    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        //print ("Validating selector: \(item.action)")
        switch item.action {
        case #selector(performTextFinderAction(_:)):
            if let fa = NSTextFinder.Action (rawValue: item.tag) {
                switch fa {
                case .showFindInterface:
                    return true
                case .showReplaceInterface:
                    return true
                case .hideReplaceInterface:
                    return true
                default:
                    return false
                }
            }
            return false
        case #selector(paste(_:)):
            return true
        case #selector(selectAll(_:)):
            return true
        case #selector(copy(_:)):
            return selection.active
        default:
            print ("Validating User Interface Item: \(item)")
            return false
        }
    }
    
    public func selectionChanged(source: Terminal) {
        updateSelectionInBuffer(terminal: source)
        needsDisplay = true
    }
    
    func cut (sender: Any?) {}
    
    @objc
    public func paste(_ sender: Any)
    {
        let clipboard = NSPasteboard.general
        let text = clipboard.string(forType: .string)
        insertText(text ?? "", replacementRange: NSRange(location: 0, length: 0))
    }
    
    @objc
    public func copy(_ sender: Any)
    {
        // find the selected range of text in the buffer and put in the clipboard
        let str = selection.getSelectedText()
        
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(str, forType: .string)
    }
    
    public override func selectAll(_ sender: Any?)
    {
        selection.selectAll()
    }
    
    //func undo (sender: Any) {}
    //func redo (sender: Any) {}
    func zoomIn (sender: Any) {}
    func zoomOut (sender: Any) {}
    func zoomReset (sender: Any) {}
    
    // Returns the vt100 mouseflags
    func encodeMouseEvent (with event: NSEvent) -> Int
    {
        let flags = event.modifierFlags
        let isReleaseEvent = [NSEvent.EventType.leftMouseUp, .otherMouseUp, .rightMouseUp].contains(event.type)
        
        return terminal.encodeButton(button: event.buttonNumber, release: isReleaseEvent, shift: flags.contains(.shift), meta: flags.contains(.option), control: flags.contains(.control))
    }
    
    func calculateMouseHit (with event: NSEvent) -> Position
    {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int (point.x / cellDimension.width)
        let row = Int ((frame.height-point.y) / cellDimension.height)
        if row < 0 {
            return Position(col: 0, row: 0)
        }
        return Position(col: min (max (0, col), terminal.cols-1), row: min (row, terminal.rows-1))
    }
    
    private func sharedMouseEvent (with event: NSEvent)
    {
        let hit = calculateMouseHit(with: event)
        let buttonFlags = encodeMouseEvent(with: event)
        terminal.sendEvent(buttonFlags: buttonFlags, x: hit.col, y: hit.row)
    }
    
    private var autoScrollDelta = 0
    // Callback from when the mouseDown autoscrolling timer goes off
    private func scrollingTimerElapsed (source: Timer)
    {
        if autoScrollDelta == 0 {
            return
        }
        if autoScrollDelta < 0 {
            scrollUp(lines: autoScrollDelta * -1)
        } else {
            scrollUp(lines: autoScrollDelta)
        }
    }
    
    public override func mouseDown(with event: NSEvent) {
        if terminal.mouseMode.sendButtonPress() {
            sharedMouseEvent(with: event)
            return
        }
        
        let hit = calculateMouseHit(with: event)
        
        switch event.clickCount {
        case 1:
            if selection.active == true {
                if event.modifierFlags.contains(.shift) {
                    selection.shiftExtend(row: hit.row, col: hit.col)
                } else {
                    selection.active = false
                }
            }
        case 2:
            selection.selectWordOrExpression(at: Position(col: hit.col, row: hit.row + terminal.buffer.yDisp), in: terminal.buffer)
        default:
            // 3 and higher
            selection.select(row: hit.row + terminal.buffer.yDisp)
        }
    }
    
    func getPayload (for event: NSEvent) -> String?
    {
        let hit = calculateMouseHit(with: event)
        let cd = terminal.buffer.lines [terminal.buffer.yDisp+hit.row][hit.col]
        return cd.getPayload()
    }
    
    var didSelectionDrag: Bool = false
    
    public override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command){
            if let payload = getPayload(for: event) {
                if let (url, params) = urlAndParamsFrom(payload: payload) {
                    delegate?.requestOpenLink(source: self, link: url, params: params)
                }
            }
        }
        if terminal.mouseMode.sendButtonRelease() {
            sharedMouseEvent(with: event)
            return
        }
        
        #if DEBUG
        // let hit = calculateMouseHit(with: event)
        //print ("Up at col=\(hit.col) row=\(hit.row) count=\(event.clickCount) selection.active=\(selection.active) didSelectionDrag=\(didSelectionDrag) ")
        #endif
        
        didSelectionDrag = false
    }
    
    public override func mouseDragged(with event: NSEvent) {
        let hit = calculateMouseHit(with: event)
        if terminal.mouseMode.sendMotionEvent() {
            let flags = encodeMouseEvent(with: event)
            
            terminal.sendMotion(buttonFlags: flags, x: hit.col, y: hit.row)
            
            return
        }
        
        if terminal.mouseMode != .off {
            return
        }
        
        if selection.active {
            selection.dragExtend(row: hit.row, col: hit.col)
        } else {
            selection.startSelection(row: hit.row, col: hit.col)
        }
        didSelectionDrag = true
        autoScrollDelta = 0
        if selection.active {
            if hit.row <= 0 {
                autoScrollDelta = calcScrollingVelocity(delta: hit.row * -1) * -1
            } else if hit.row >= terminal.rows {
                autoScrollDelta = calcScrollingVelocity(delta: hit.row - terminal.rows)
            }
        }
    }
    
    func tryUrlFont () -> NSFont
    {
        for x in ["Optima", "Helvetica", "Helvetica Neue"] {
            if let font = NSFont (name: x, size: 12) {
                return font
            }
        }
        return NSFont.systemFont(ofSize: 12)
    }
    
    // The payload contains the terminal data which is expected to be of the form
    // params;URL, so we need to extract the second component, but we also assume that
    // the input might be ill-formed, so we might return nil in that case
    func urlAndParamsFrom (payload: String) -> (String, [String:String])?
    {
        let split = payload.split(separator: ";", maxSplits: Int.max, omittingEmptySubsequences: false)
        if split.count > 1 {
            let pairs = split [0].split (separator: ":")
            var params: [String:String] = [:]
            for p in pairs {
                let kv = p.split (separator: "=")
                if kv.count == 2 {
                    params [String (kv [0])] = String (kv[1])
                }
            }
            return (String (split [1]), params)
        }
        return nil
    }
    
    var urlPreview: NSTextField?
    func previewUrl (payload: String)
    {
        if let (url, _) = urlAndParamsFrom(payload: payload) {
            if let up = urlPreview {
                up.stringValue = url
                up.sizeToFit()
            } else {
                let nup = NSTextField (string: url)
                nup.isBezeled = false
                nup.font = tryUrlFont ()
                nup.backgroundColor = options.colors.foregroundColor
                nup.textColor = options.colors.backgroundColor
                nup.sizeToFit()
                nup.frame = CGRect (x: 0, y: 0, width: nup.frame.width, height: nup.frame.height)
                addSubview(nup)
                urlPreview = nup
            }
        }
    }
    
    func removePreviewUrl ()
    {
        if let urlPreview = self.urlPreview {
            urlPreview.removeFromSuperview()
            self.urlPreview = nil
        }
    }
    
    public override func mouseMoved(with event: NSEvent) {
        let hit = calculateMouseHit(with: event)
        if commandActive {
            if let payload = getPayload(for: event) {
                previewUrl (payload: payload)
            }
        }
        
        if terminal.mouseMode.sendMotionEvent() {
            let flags = encodeMouseEvent(with: event)
            terminal.sendMotion(buttonFlags: flags, x: hit.col, y: hit.row)
        }
    }
    
    public override func scrollWheel(with event: NSEvent) {
        if event.deltaY == 0 {
            return
        }
        let velocity = calcScrollingVelocity(delta: Int (abs (event.deltaY)))
        if event.deltaY > 0 {
            scrollUp (lines: velocity)
        } else {
            scrollDown(lines: velocity)
        }
    }
    
    private func calcScrollingVelocity (delta: Int) -> Int
    {
        if delta > 9 {
            return max (terminal.rows, 20)
        }
        if delta > 5 {
            return 10
        }
        if delta > 1 {
            return 3
        }
        return 1
    }
    
    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

extension TerminalView: TerminalDelegate {
    public func isProcessTrusted(source: Terminal) -> Bool {
        true
    }
    
    public func mouseModeChanged(source: Terminal) {
        if source.mouseMode == .anyEvent {
            startTracking()
        } else {
            if terminal != nil {
                deregisterTrackingInterest()
            }
        }
    }
    
    public func showCursor(source: Terminal) {
        //
    }
    
    public func setTerminalTitle(source: Terminal, title: String) {
        delegate?.setTerminalTitle(source: self, title: title)
    }
    
    public func sizeChanged(source: Terminal) {
        delegate?.sizeChanged(source: self, newCols: source.cols, newRows: source.rows)
        updateScroller ()
    }
    
    public func setTerminalIconTitle(source: Terminal, title: String) {
        //
    }
    
    // Terminal.Delegate method implementation
    public func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        return nil
    }
    
}

private extension NSColor {
    func inverseColor() -> NSColor {
        guard let color = self.usingColorSpace(.deviceRGB) else {
            return self
        }
        
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return NSColor(calibratedRed: 1.0 - red, green: 1.0 - green, blue: 1.0 - blue, alpha: alpha)
    }
}

private extension NSAttributedString.Key {
    static let selectionBackgroundColor: NSAttributedString.Key = .init("SwiftTerm_selectionBackgroundColor") // NSColor, default nil: no background
}

private extension NSMutableAttributedString {
    func removeAttribute(_ attributeKey: NSAttributedString.Key) {
        self.removeAttribute(attributeKey, range: NSRange(location: 0, length: length))
    }
}

private extension NSRange {
    var isEmpty: Bool {
        location == NSNotFound && length == 0
    }
    
    static var empty: NSRange {
        NSRange(location: NSNotFound, length: 0)
    }
}

// Default implementations for TerminalViewDelegate

extension TerminalViewDelegate {
    public func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = NSURLComponents(string: fixedup) {
                if let nested = url.url {
                    NSWorkspace.shared.open(nested)
                }
            }
        }
    }
}

#endif
