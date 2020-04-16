//
//  iOSTerminalView.swift
//
//  The indicator "//X" means that this code was commented out from the Mac version for the sake of
//  porting and need to be audited.
//  Created by Miguel de Icaza on 3/4/20.
//

#if os(iOS)
import Foundation
import UIKit
import CoreText
import CoreGraphics

/**
 * TerminalView provides an AppKit front-end to the `Terminal` termininal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 */
public class TerminalView: UIView {

    struct Font {
        let normal: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
    }

    var terminal: Terminal!
    var font: Font!
    //X var caretView: CaretView!
    var attrStrBuffer: CircularList<NSAttributedString>!
    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    /// Precalculated line height
    var lineHeight: CGFloat!
    //var selectionView: SelectionView!
    var selection: SelectionService!
    //Xvar scroller: UIScrollView
    //Xvar debug: TerminalDebugView?
    
    /// By default this uses grey on top of black, but if you want to use
    /// system colors change this global.   This likely needs to be configured
    /// via another system that does not currently exist
    public static var useSystemColors = false
    
    // Default colors
    var defFgColor: UIColor = UIColor.gray
    var defBgColor: UIColor = UIColor.black
    var defSize: CGFloat = 16.5
    var fontWidth: CGFloat = 0
    
    public override init (frame: CGRect)
    {
        super.init (frame: frame)
        setup(frame: frame, bounds: bounds)
    }
    
    public required init? (coder: NSCoder)
    {
        super.init (coder: coder)
        setup(frame: frame, bounds: bounds)
    }
    
    /// Returns the underlying terminal emulator that the `TerminalView` is a view for
    public func getTerminal () -> Terminal
    {
        return terminal
    }
        
    func setup(frame: CGRect, bounds: CGRect)
    {
        var baseFont: UIFont
        
        baseFont = UIFont.monospacedSystemFont (ofSize: 12, weight: .regular)

        setupFont (baseFont)
      
        // Calculation assume that all glyphs in the font have the same advancement.
        // Get the ascent + descent + leading from the font, already scaled for the font's size
        computeFontDimensions ()
        
        //XsetupScroller()
        let options = TerminalOptions(cols: 80,
                                      rows: 25)

        terminal = Terminal(delegate: self, options: options)
        fullBufferUpdate()
        
        //X selection = SelectionService(terminal: terminal)

        // Install selection view
        // Make the selection view the entire visible portion of the view
        // we will mask the selected text that is visible to the user
        //XselectionView = SelectionView(terminalView: self, frame: bounds)
        //XselectionView.autoresizingMask = [.height, .width]
        //XaddSubview(selectionView)

        // Install carret view
        //XcaretView = CaretView(frame: CGRect(origin: .zero, size: CGSize(width: font.normal.maximumAdvancement.width, height: lineHeight)))
        //XaddSubview(caretView)

        //Xsearch = SearchService (terminal: terminal)
    }
    
    func setupFont (_ baseFont: UIFont)
    {
        font = Font(normal: baseFont,
                    bold: UIFont.monospacedSystemFont (ofSize: 12, weight: .bold),
                    italic: UIFont (descriptor: baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic])!, size: 0),
                    boldItalic: UIFont (descriptor: baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic, .traitBold])!, size: 0))

        let fontAttributes = [NSAttributedString.Key.font: baseFont]
        fontWidth = "W".size(withAttributes: fontAttributes).width
    }
    
    var lineAscent: CGFloat = 0
    var lineDescent: CGFloat = 0
    var lineLeading: CGFloat = 0
    
    // Computes the font dimensions once font.normal has been set
    func computeFontDimensions ()
    {
        lineAscent = CTFontGetAscent (font.normal)
        lineDescent = CTFontGetDescent (font.normal)
        lineLeading = CTFontGetLeading(font.normal)
        lineHeight = lineAscent + lineDescent + lineLeading
    }

    /**
     * The delegate that the TerminalView uses to interact with its hosting
     */
    public weak var delegate: TerminalViewDelegate?
    
    public var optionAsMetaKey: Bool = true

    public func bell(source: Terminal) {
        // TODO: do something with the bell
    }
    
    public func bufferActivated(source: Terminal) {
        //X updateScroller ()
    }
    
    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        delegate?.send (source: self, data: data)
    }

    
    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     */
    public func getOptimalFrameSize () -> CGRect
    {
        return CGRect (x: 0, y: 0, width: fontWidth * CGFloat(terminal.cols), height: lineHeight * CGFloat(terminal.rows))
    }
    
    public func scrolled(source terminal: Terminal, yDisp: Int) {
        //XselectionView.notifyScrolled(source: terminal)
        //XupdateScroller()
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
        //Xscroller.isEnabled = canScroll
        //Xscroller.doubleValue = scrollPosition
        //Xscroller.knobProportion = scrollThumbsize
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

    // Cache for the colors in the 0..255 range
    var colors: [UIColor?] = Array.init(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:UIColor] = [:]
    
    func mapColor (color: Attribute.Color, isFg: Bool) -> UIColor
    {
        switch color {
        case .defaultColor:
            if isFg {
                return defFgColor
            } else {
                return defBgColor
            }
        case .defaultInvertedColor:
            if isFg {
                return defBgColor // iOS: Should use something better
            } else {
                return defFgColor // iOS: Should use something better
            }
        case .ansi256(let ansi):
            if let c = colors [Int (ansi)] {
                return c
            }
            
            let tcolor = Color.defaultAnsiColors [Int (ansi)]

            let newColor = UIColor(red: CGFloat (tcolor.red) / 255.0,
                                   green: CGFloat (tcolor.green) / 255.0,
                                   blue: CGFloat (tcolor.blue) / 255.0,
                                   alpha: 1.0)
            colors [Int(ansi)] = newColor
            return newColor

        case .trueColor(let r, let g, let b):
            if let tc = trueColors [color] {
                return tc
            }
            let newColor = UIColor(red: CGFloat (r) / 255.0,
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
        
        var font: UIFont
        if flags.contains (.bold){
            if flags.contains (.italic) {
                font = self.font.boldItalic
            } else {
                font = self.font.bold
            }
        } else if flags.contains (.italic) {
            font = self.font.italic
        } else {
            font = self.font.normal
        }
        
        let fgColor = mapColor (color: fg, isFg: true)
        var nsattr: [NSAttributedString.Key:Any] = [
            .font: font,
            .foregroundColor: fgColor,
            .fullBackgroundColor: mapColor(color: bg, isFg: false)
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
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue + Int (CTUnderlineStyleModifiers.patternDot.rawValue)
            nsattr [.underlineColor] = fgColor
            
            // Add to cache
            urlAttributes [attribute] = nsattr
        } else {
            // Just add to cache
            attributes [attribute] = nsattr
        }
        return nsattr
    }
    
    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    
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
        addSelectionAttributesIfNeeded(to: res, row: row, cols: cols)
        res.fixAttributes(in: NSRange(location: 0, length: res.length))
        return res
    }

    /// Apply selection attributes
    /// TODO: Optimize the logic below
    private func addSelectionAttributesIfNeeded(to attributedString: NSMutableAttributedString, row: Int, cols: Int) {
        guard let selection = self.selection, selection.active else {
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
            attributedString.addAttribute(.selectionBackgroundColor, value: UIColor.red, range: selectionRange)
        }
    }
    
    //
    // Updates the contents of the NSAttributedString buffer from the contents of the terminal.buffer character array
    //
    func fullBufferUpdate ()
    {
        if attrStrBuffer == nil {
            attrStrBuffer = CircularList<NSAttributedString> (maxLength: terminal.buffer.lines.maxLength)
            attrStrBuffer.makeEmpty = makeEmptyLine
        } else {
            if terminal.buffer.lines.maxLength > attrStrBuffer.maxLength {
                attrStrBuffer.maxLength = terminal.buffer.lines.maxLength
            }
        }
        
        let cols = terminal.cols
        for row in (terminal.buffer.yDisp)...(terminal.rows + terminal.buffer.yDisp) {
          attrStrBuffer [row] = buildAttributedString (row: row, line: terminal.buffer.lines [row], cols: cols, prefix: "")
        }
        attrStrBuffer.count = terminal.rows
    }
    
    func makeEmptyLine (_ index: Int) -> NSAttributedString
    {
        let line = terminal.buffer.lines [index]
        return buildAttributedString (row: index, line: line, cols: terminal.cols, prefix: "")
    }
    
    func updateDisplay (notifyAccessibility: Bool)
    {
        updateCursorPosition ()

         guard let (rowStart, rowEnd) = terminal.getUpdateRange () else {
            return
        }
        
        terminal.clearUpdateRange ()
        
        let cols = terminal.cols
        let tb = terminal.buffer
        
        for row in rowStart...rowEnd {
            let line = terminal.buffer.lines [row + tb.yDisp]
            
            attrStrBuffer [row + tb.yDisp] = buildAttributedString (row: row + tb.yDisp, line: line, cols: cols, prefix: "")
        }
        
        #if false
            // FIXME: Calculations are broken because based on estimatedLineHeight.
            // See https://github.com/migueldeicaza/SwiftTerm/issues/71 for example
            let baseLine = frame.height
            let region = CGRect (x: 0,
                                 y: baseLine - (lineHeight + CGFloat(rowEnd) * lineHeight),
                                 width: frame.width,
                                 height: CGFloat(rowEnd-rowStart + 1) * lineHeight)

            //print ("Region: \(region)")
            setNeedsDisplay(region)
        #else
            setNeedsDisplay ()
        #endif

        pendingDisplay = false
        //debug?.update()
        
//X        if (notifyAccessibility) {
//            accessibility.invalidate ()
//            NSAccessibility.post (element: self, notification: .valueChanged)
//            NSAccessibility.post (element: self, notification: .selectedTextChanged)
//        }
    }

    private func ctline(forRow row: Int) -> CTLine {
        let attributedStringLine = attrStrBuffer [row]
        let ctline = CTLineCreateWithAttributedString (attributedStringLine)
        return ctline
    }

    func characterOffset (atRow row: Int, col: Int) -> CGFloat {
        let ctline = self.ctline (forRow: row)
        return CTLineGetOffsetForStringIndex (ctline, col, nil)
    }
    
    var useFixedSizes = false
    // TODO: Clip here
    override public func draw (_ dirtyRect: CGRect) {
        // it doesn't matter. Our attributed string has color set anyway
        defFgColor.set()

        var context = UIGraphicsGetCurrentContext()!

        // draw background
        context.saveGState()
        context.setFillColor(defBgColor.cgColor)
        context.fill(dirtyRect)
        context.restoreGState()

        context.saveGState()

        // lines to draw
        // TODO: for the performance reasons, it's better to create CTLine when attrStrBuffer is updated
        // swift52:
        // let lines: [CTLine] = (terminal.buffer.yDisp..<(terminal.rows + terminal.buffer.yDisp)).map({ attrStrBuffer [$0] }).map(CTLineCreateWithAttributedString)
        var lines: [CTLine] = []
        lines.reserveCapacity(terminal.rows)
        for row in terminal.buffer.yDisp..<terminal.rows + terminal.buffer.yDisp {
            let attrLine = attrStrBuffer [row]
            let ctline = CTLineCreateWithAttributedString(attrLine)
            lines.append(ctline)
        }

        // draw lines
        var prevY: CGFloat = 0
        for line in lines {
            let currentLineHeight: CGFloat
            var currentLineAscent: CGFloat = 0
            var currentLineDescent: CGFloat = 0
            var currentLineLeading: CGFloat = 0

            if useFixedSizes {
                currentLineAscent = lineAscent
                currentLineDescent = lineDescent
                currentLineLeading = lineLeading
                currentLineHeight = lineHeight
            } else {
                _ = CTLineGetTypographicBounds (line, &currentLineAscent, &currentLineDescent, &currentLineLeading)
                currentLineHeight = currentLineAscent + currentLineDescent + currentLineLeading
            }

            let currentLineOrigin = CGPoint (x: 0, y: frame.height - (currentLineHeight + prevY))

            // Draw line manually, so we can run custom routine for background color
            for glyphRun in CTLineGetGlyphRuns (line) as? [CTRun] ?? [] {
                let runAttributes = CTRunGetAttributes(glyphRun) as? [NSAttributedString.Key: Any] ?? [:]

                var runAscent: CGFloat = 0
                var runDescent: CGFloat = 0
                var runLeading: CGFloat = 0
                let runWidth = CTRunGetTypographicBounds (glyphRun, CFRange (), &runAscent, &runDescent, &runLeading)

                // Default to font.normal
                var runFont = font.normal
                if runAttributes.keys.contains(.font) {
                    runFont = runAttributes[.font] as! UIFont
                }

                // Get glyphs positions
                var glyphsPositions = [CGPoint](repeating: .zero, count: CTRunGetGlyphCount (glyphRun))
                CTRunGetPositions(glyphRun, CFRange(), &glyphsPositions)

                // Draw background.
                // Background color fill the entire height of the line.
                if runAttributes.keys.contains(.fullBackgroundColor) {
                    let backgroundColor = runAttributes[.fullBackgroundColor] as! UIColor

                    var transform = CGAffineTransform (translationX: glyphsPositions[0].x, y: 0)
                    let path = CGPath (rect: CGRect (origin: currentLineOrigin, size: CGSize (width: CGFloat (runWidth), height: currentLineHeight)), transform: &transform)

                    context.saveGState ()

                    context.setShouldAntialias (false)
                    context.setLineCap (.square)
                    context.setLineWidth(0)
                    context.setFillColor(backgroundColor.cgColor)
                    context.setStrokeColor(backgroundColor.cgColor)
                    context.addPath(path)
                    context.drawPath(using: .fill)

                    context.restoreGState()
                }

                if runAttributes.keys.contains(.selectionBackgroundColor) {
                  let backgroundColor = runAttributes[.selectionBackgroundColor] as! UIColor

                  var transform = CGAffineTransform (translationX: glyphsPositions[0].x, y: 0)
                  let path = CGPath (rect: CGRect (origin: currentLineOrigin, size: CGSize (width: CGFloat (runWidth), height: currentLineHeight)), transform: &transform)

                  context.saveGState ()

                  context.setShouldAntialias (false)
                  context.setLineCap (.square)
                  context.setLineWidth(0)
                  context.setFillColor(backgroundColor.cgColor)
                  context.setStrokeColor(backgroundColor.cgColor)
                  context.addPath(path)
                  context.drawPath(using: .fill)

                  context.restoreGState()

                }

                // Draw glyphs
                // Not really needed, use CTLineDraw instead
                #if false
                // Adjust positions for text
                let baseLineAdj = runFont.descender + runFont.leading
                glyphsPositions = glyphsPositions.map({ CGPoint(x: $0.x, y: lineOrigin.y + baseLineAdj) })

                // Set foreground color
                if runAttributes.keys.contains(.foregroundColor) {
                    let color = runAttributes[.foregroundColor] as! NSColor
                    context.setFillColor(color.cgColor)
                }

                if runAttributes.keys.contains(.underlineColor) {
                    let color = runAttributes[.underlineColor] as! NSColor
                    context.setFillColor(color.cgColor)
                }

                if runAttributes.keys.contains(.strikethroughColor) {
                    let color = runAttributes[.strikethroughColor] as! NSColor
                    context.setFillColor(color.cgColor)
                }

                var glyphs = [CGGlyph](repeating: .zero, count: CTRunGetGlyphCount(glyphRun))
                CTRunGetGlyphs(glyphRun, CFRange(), &glyphs)

                // TODO: disable antialiasing for non-letters
                //
                for (i, glyph) in glyphs.enumerated() {
                    var transform = CGAffineTransform(translationX: glyphsPositions[i].x, y: lineOrigin.y - baseLineAdj)
                    if let path = CTFontCreatePathForGlyph(runFont, glyph, &transform) {
                        context.addPath(path)
                        context.drawPath(using: .fill)
                    }
                }
                #endif
            }

            // The code above is CTLineDraw() in disguise
            let baseLineAdj = -(currentLineDescent + currentLineLeading)
            context.textPosition = CGPoint (x: 0, y: currentLineOrigin.y - baseLineAdj)
            CTLineDraw (line, context)

            prevY += currentLineHeight
        }

        context.restoreGState ()
    }
    
    func updateCursorPosition ()
    {
        //XcaretView.frame.origin = getCaretPos (terminal.buffer.x, terminal.buffer.y)
    }

    func getCaretPos(_ col: Int, _ row: Int) -> CGPoint
    {
        let x = self.characterOffset (atRow: row, col: col)
        let y = frame.height - (lineHeight + (CGFloat (row) * lineHeight))
        return CGPoint (x: x, y: y)
    }

    // Does not use a default argument and merge, because it is called back
    func updateDisplay ()
    {
        updateDisplay (notifyAccessibility: true)
        //Xdebug?.update()
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

    public override var frame: CGRect {
        get {
            return super.frame
        }
        set(newValue) {
            super.frame = newValue

            let newRows = Int (newValue.height / lineHeight)
            let newCols = Int ((newValue.width/*//X-scroller.frame.width*/) / fontWidth)

            if newCols != terminal.cols || newRows != terminal.rows {
                terminal.resize (cols: newCols, rows: newRows)
                fullBufferUpdate ()
            }

            updateCursorPosition ()
            
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

//X    public override func resizeSubviews(withOldSize oldSize: NSSize) {
//      super.resizeSubviews(withOldSize: oldSize)
//      updateScroller()
//      selection.active = false
//    }
    
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
            //XcaretView.focused = newValue
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
            //X:selectionView.notifyScrolled(source: terminal)
            delegate?.scrolled (source: self, position: scrollPosition)
            updateScroller()

            // Update selection
            //fullBufferUpdate(terminal: terminal)
            setNeedsDisplay ()
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
}

extension TerminalView: TerminalDelegate {
    public func isProcessTrusted(source: Terminal) -> Bool {
        true
    }
    
    public func mouseModeChanged(source: Terminal) {
        // iOS TODO
        //X
    }
    
    public func showCursor(source: Terminal) {
        //
    }
  
    public func setTerminalTitle(source: Terminal, title: String) {
        delegate?.setTerminalTitle(source: self, title: title)
    }
  
    public func sizeChanged(source: Terminal) {
        delegate?.sizeChanged(source: self, newCols: source.cols, newRows: source.rows)
        //X iOS TODO: updateScroller ()
    }
  
    public func setTerminalIconTitle(source: Terminal, title: String) {
        //
    }
  
    // Terminal.Delegate method implementation
    public func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        return nil
    }

}


// Default implementations for TerminalViewDelegate

extension TerminalViewDelegate {
    public func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        //X iOS TODO
        //if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        //    if let url = NSURLComponents(string: fixedup) {
        //        if let nested = url.url {
        //            NSWorkspace.shared.open(nested)
        //        }
        //    }
        //}
    }
}

#endif
