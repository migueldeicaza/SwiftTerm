//
//  iOSTerminalView.swift
//
// This is the AppKit version of the TerminalView and holds the state
// variables in the `TerminalView` class, but as much of the terminal
// implementation details live in the Apple/AppleTerminalView which
// contains the shared AppKit/UIKit code
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
import os

@available(iOS 14.0, *)
internal var log: Logger = Logger(subsystem: "org.tirania.SwiftTerm", category: "msg")

/**
 * TerminalView provides an UIKit front-end to the `Terminal` termininal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 *
 * Call the `getTerminal` method to get a reference to the underlying `Terminal` that backs this
 * view.
 *
 * Use the `configureNativeColors()` to set the defaults colors for the view to match the OS
 * defaults, otherwise, this uses its own set of defaults colors.
 */
open class TerminalView: UIScrollView, UITextInputTraits, UIKeyInput, UIScrollViewDelegate {
    struct FontSet {
        public let normal: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
        
        static var defaultFont: UIFont {
            UIFont.monospacedSystemFont (ofSize: 12, weight: .regular)
        }
        
        public init(font baseFont: UIFont) {
            self.normal = baseFont
            self.bold = UIFont (descriptor: baseFont.fontDescriptor.withSymbolicTraits ([.traitBold])!, size: 0)
            self.italic = UIFont (descriptor: baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic])!, size: 0)
            self.boldItalic = UIFont (descriptor: baseFont.fontDescriptor.withSymbolicTraits ([.traitItalic, .traitBold])!, size: 0)
        }
        
        // Expected by the shared rendering code
        func underlinePosition () -> CGFloat
        {
            return -1.2
        }
        
        // Expected by the shared rendering code
        func underlineThickness () -> CGFloat
        {
            return 0.63
        }
    }
    
    /**
     * The delegate that the TerminalView uses to interact with its hosting
     */
    public weak var terminalDelegate: TerminalViewDelegate?
    
    /**
     * If set, and the the client application has requested mouse events to be sent, this will
     * send the events.   If this value if false, then a secondary codepath is enabled that will
     * always allow the selection or the scrolling/panning to take place, regardless of the
     * request from the client application.
     *
     * Additionally, during a pan operation if allowMouseReporting is false, then this turns
     * panning operations into sending cursor key commands.
     *
     * If a client application has not indicated any use for mouse events, then this setting
     * does not do anything, and selection and panning are still processed.
     */
    public var allowMouseReporting: Bool = true
    
    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    var debug: UIView?
    var pendingDisplay: Bool = false
    var cellDimension: CellDimension!
    var caretView: CaretView!
    var terminal: Terminal!
    
    var selection: SelectionService!
    var attrStrBuffer: CircularList<ViewLineInfo>!
    var images:[(image: TerminalImage, col: Int, row: Int)] = []

    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary
    // of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]

    // Timer to display the terminal buffer
    var link: CADisplayLink!
    // Cache for the colors in the 0..255 range
    var colors: [UIColor?] = Array(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:UIColor] = [:]
    var transparent = TTColor.transparent ()
    
    // UITextInput support starts
    public lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer (textInput: self) // TerminalInputTokenizer()
    
    // We use this as temporary storage for UITextInput, which we send to the terminal on demand
    var textInputStorage: [Character] = []
    
    // This tracks the marked text, part of the UITextInput protocol, which is used to flag temporary data entry, that might
    // be removed afterwards by the input system (input methods will insert approximiations, mark and change on demand)
    var _markedTextRange: xTextRange?

    // The input delegate is part of UITextInput, and we notify it of changes.
    public weak var inputDelegate: UITextInputDelegate?
    // This tracks the selection in the textInputStorage, it is not the same as our global selection, it is temporary
    var _selectedTextRange: xTextRange = xTextRange(0, 0)

    // Used for the keyboard long-press gesture that works as a cursor
    var lastFloatingCursorLocation: CGPoint?
    
    var fontSet: FontSet
    /// The font to use to render the terminal
    public var font: UIFont {
        get {
            return fontSet.normal
        }
        set {
            fontSet = FontSet (font: newValue)
            resetFont();
            fullBufferUpdate(terminal: terminal)
        }
    }
    
    public init(frame: CGRect, font: UIFont?) {
        self.fontSet = FontSet (font: font ?? FontSet.defaultFont)
        super.init (frame: frame)
        setup()
    }
    
    public override init (frame: CGRect)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (frame: frame)
        setup()
    }
    
    public required init? (coder: NSCoder)
    {
        self.fontSet = FontSet (font: FontSet.defaultFont)
        super.init (coder: coder)
        setup()
    }
          
    func setup()
    {
        setupKeyboardButtonColors()
        setupDisplayUpdates ();
        setupOptions ()
        setupGestures ()
        setupAccessoryView ()
    }

    func setupDisplayUpdates ()
    {
        link = CADisplayLink(target: self, selector: #selector(step))
            
        link.add(to: .current, forMode: .default)
        suspendDisplayUpdates()
    }
    
    @objc
    func step(displaylink: CADisplayLink) {
        updateDisplay()
    }

    func startDisplayUpdates()
    {
        link.isPaused = false
    }
    
    func suspendDisplayUpdates()
    {
        link.isPaused = true
    }
    
    @objc func pasteCmd(_ sender: Any?) {
        if let start = UIPasteboard.general.string {
            send(txt: start)
            queuePendingDisplay()
        }
        
    }

    @objc func copyCmd(_ sender: Any?) {
        UIPasteboard.general.string = selection.getSelectedText()
    }

    @objc open override func copy(_ sender: Any?) {
        copyCmd (sender)
    }
    
    @objc open override func paste (_ sender: Any?) {
        pasteCmd (sender)
    }
    
    @objc open override func selectAll(_ sender: Any?) {
        selection.selectAll()
    }
    
    /// Invoked when the user has long-pressed and then clicked "Select"
    @objc func selectCmd (_ sender: Any?)  {
        if let loc = lastLongSelect {
            selection.selectWordOrExpression(at: Position (col: loc.col, row: loc.row), in: terminal.buffer)
            DispatchQueue.main.async {
                self.showContextMenu(at: self.lastLongSelectPos, pos: loc)
            }
            
        }
        lastLongSelect = nil
    }
    
    @objc func resetCmd(_ sender: Any?) {
        terminal.cmdReset()
        queuePendingDisplay()
    }

    func showContextMenu (at: CGPoint, pos: Position) {
        var items: [UIMenuItem] = []
        
        if selection.active {
            items.append(UIMenuItem(title: "Copy", action: #selector(copyCmd)))
        } else {
            lastLongSelect = pos
            lastLongSelectPos = at
            items.append(UIMenuItem(title: "Select", action: #selector(selectCmd)))
        }
        if UIPasteboard.general.hasStrings {
            items.append(UIMenuItem(title: "Paste", action: #selector(pasteCmd)))
        }
        items.append (UIMenuItem(title: "Reset", action: #selector(resetCmd)))
        
        // Configure the shared menu controller
        let menuController = UIMenuController.shared
        menuController.menuItems = items
        
        // TODO:
        //  - If nothing is selected, offer Select, Select All
        //  - If something is selected, offer copy, look up, share, "Search on StackOverflow"

        // Set the location of the menu in the view.
        let menuLocation = CGRect (origin: at, size: CGSize.zero)
        //menuController.setTargetRect(menuLocation, in: gestureRecognizer.view!)
        menuController.showMenu(from: self, rect: menuLocation)
    }
    
    var lastLongSelect: Position?
    var lastLongSelectPos = CGPoint.zero
    
    @objc func longPress (_ gestureRecognizer: UILongPressGestureRecognizer)
    {
         if gestureRecognizer.state == .began {
             self.becomeFirstResponder()
             //self.viewForReset = gestureRecognizer.view
             let location = gestureRecognizer.location(in: gestureRecognizer.view)
             showContextMenu (at: location, pos: calculateTapHit(gesture: gestureRecognizer))
          }
    }
    
    /// This controls whether the backspace should send ^? or ^H, the default is ^?
    public var backspaceSendsControlH: Bool = false
    
    func calculateTapHit (gesture: UIGestureRecognizer) -> Position
    {
        let point = gesture.location(in: self)
        let col = Int (point.x / cellDimension.width)
        let row = Int (point.y / cellDimension.height)
        if row < 0 {
            return Position(col: 0, row: 0)
        }
        return Position(col: min (max (0, col), terminal.cols-1), row: min (row, terminal.rows-1))
    }

    func encodeFlags (release: Bool) -> Int
    {
        let encodedFlags = terminal.encodeButton(
            button: 1,
            release: release,
            shift: false,
            meta: false,
            control: terminalAccessory?.controlModifier ?? false)
        terminalAccessory?.controlModifier = false
        return encodedFlags
    }
    
    func sharedMouseEvent (gestureRecognizer: UIGestureRecognizer, release: Bool)
    {
        let hit = calculateTapHit(gesture: gestureRecognizer)
        terminal.sendEvent(buttonFlags: encodeFlags (release: release), x: hit.col, y: hit.row)
    }
    
    #if true
    #endif

    @objc func singleTap (_ gestureRecognizer: UITapGestureRecognizer)
    {
        if isFirstResponder {
            guard gestureRecognizer.view != nil else { return }
                 
            if gestureRecognizer.state != .ended {
                return
            }
            
            if UIMenuController.shared.isMenuVisible {
                UIMenuController.shared.hideMenu()
            }
         
            if allowMouseReporting && terminal.mouseMode.sendButtonPress() {
                sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: false)

                if terminal.mouseMode.sendButtonRelease() {
                    sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: true)
                }
            } else {
                selection.selectNone()
            }
            queuePendingDisplay()
        } else {
            becomeFirstResponder ()
        }
    }
    
    @objc func doubleTap (_ gestureRecognizer: UITapGestureRecognizer)
    {
        guard gestureRecognizer.view != nil else { return }
               
        if gestureRecognizer.state != .ended {
            return
        }
        
        if allowMouseReporting && terminal.mouseMode.sendButtonPress() {
            sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: false)
            
            if terminal.mouseMode.sendButtonRelease() {
                sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: true)
            }
            return
        } else {
            let hit = calculateTapHit(gesture: gestureRecognizer)
            selection.selectWordOrExpression(at: Position(col: hit.col, row: hit.row + terminal.buffer.yDisp), in: terminal.buffer)
            queuePendingDisplay()
        }
    }
    
    var directionView: UIView?
    var directionCount: Int = 0
    var lastCursorImage: String? = nil
    func createDirectionView () -> UIView {
        let timeout = 0.5
        if directionView == nil {
            let w = 80
            let h = 80
            let f = frame
            directionView = UIView (
                frame: CGRect (x: (Int (f.width)-w)/2,
                               y: (Int(f.height)-w)/2,
                               width: w,
                               height: h))
            addSubview(directionView!)
        }
        let dv = directionView!
        dv.backgroundColor = UIColor.gray
        dv.alpha = 0.5
        
        directionCount += 1
        DispatchQueue.main.asyncAfter (deadline: .now() + timeout) {
            self.directionCount -= 1
            if self.directionCount == 0 {
                if let dv = self.directionView {
                    self.directionView = nil
                    UIView.animate(withDuration: 0.3, animations: {
                        dv.alpha = 0
                    }, completion: { x in
                        dv.removeFromSuperview()
                    })
                }
            }
        }
        return dv
    }
    
    func sendKey (deltaCol: Int, deltaRow: Int) {
        if deltaCol == 0 && deltaRow == 0 { return }
        let host = createDirectionView()
        var imgName: String? = nil
        if deltaRow > 0 {
            imgName = "arrow.up.square.fill"
            sendKeyUp()
        } else if deltaRow < 0 {
            imgName = "arrow.down.square.fill"
            sendKeyDown()
        }
        if deltaCol > 0 {
            imgName = "arrow.left.square.fill"
            sendKeyLeft()
        } else if deltaCol < 0 {
            imgName = "arrow.right.square.fill"
            sendKeyRight()
        }
        if imgName == nil {
            print ("What?")
        }
        guard let name = imgName else { return }

        if lastCursorImage == name { return }
        guard let img = UIImage(systemName: name) else { return }
        lastCursorImage = name
        if let child = host.subviews.first {
            child.removeFromSuperview()
        }

        let imgView = UIImageView (image: img)
        host.addSubview (imgView)
        imgView.translatesAutoresizingMaskIntoConstraints = false
        imgView.center = host.center
        imgView.topAnchor.constraint(equalTo: host.topAnchor, constant: 0).isActive = true
        imgView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 0).isActive = true
        imgView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: 0).isActive = true
        imgView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: 0).isActive = true
        imgView.tintColor = .white
    }
    
    // The start of the pan operation, for the case where we are not sending the input to the client
    var panStart: Position?
    @objc func pan (_ gestureRecognizer: UIPanGestureRecognizer)
    {
        guard gestureRecognizer.view != nil else { return }
        if allowMouseReporting && terminal.mouseMode != .off {
            switch gestureRecognizer.state {
            case .began:
                // send the initial tap
                if terminal.mouseMode.sendButtonPress() {
                    sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: false)
                }
            case .ended, .cancelled:
                if terminal.mouseMode.sendButtonRelease() {
                    sharedMouseEvent(gestureRecognizer: gestureRecognizer, release: true)
                }
            case .changed:
                if terminal.mouseMode.sendButtonTracking() {
                    let hit = calculateTapHit(gesture: gestureRecognizer)
                    terminal.sendMotion(buttonFlags: encodeFlags(release: false), x: hit.col, y: hit.row)
                }
            default:
                break
            }
        } else {
            func near (_ pos1: Position, _ pos2: Position) -> Bool {
                return abs (pos1.col-pos2.col) < 3 && abs (pos1.row-pos2.row) < 2
            }
            
            switch gestureRecognizer.state {
            case .began:
                let _hit = calculateTapHit(gesture: gestureRecognizer)
                
                let hit = Position (col: _hit.col, row: _hit.row+terminal.buffer.yDisp)
                if selection.active {
                    var extend = false
                    if near (selection.start, hit) {
                        selection.pivot = selection.end
                        extend = true
                    } else if near (selection.end, hit) {
                        selection.pivot = selection.start
                        extend = true
                    }
                    if extend {
                        selection.pivotExtend(row: hit.row, col: hit.col)
                        queuePendingDisplay()
                        break
                    }
                }
                panStart = hit
                //selection.startSelection(row: hit.row, col: hit.col)
            case .changed:
                let _hit = calculateTapHit(gesture: gestureRecognizer)
                let hit = Position (col: _hit.col, row: _hit.row+terminal.buffer.yDisp)

                if selection.active {
                    selection.pivotExtend(row: hit.row, col: hit.col)
                    if hit.row == 0 {
                        scrollDown(lines: -1)
                    } else if hit.row == terminal.rows-1 {
                        scrollDown(lines: 1)
                    }
                    queuePendingDisplay()
                } else {
                    if let ps = panStart {
                        let deltaRow = ps.row - hit.row
                        if allowMouseReporting {
                            scrollDown (lines: deltaRow)
                        } else {
                            let deltaCol = ps.col - hit.col

                            sendKey (deltaCol: deltaCol, deltaRow: deltaRow)
                        }
                    }
                }
            case .ended:
                if selection.active {
                    let location = gestureRecognizer.location(in: gestureRecognizer.view)
                    
                    showContextMenu (at: location, pos: calculateTapHit(gesture: gestureRecognizer))
                }
                break
            case .cancelled:
                selection.active = false
            default:
                break
            }
        }
    }
    
    func setupGestures ()
    {
        let longPress = UILongPressGestureRecognizer (target: self, action: #selector(longPress(_:)))
        longPress.minimumPressDuration = 0.7
        addGestureRecognizer(longPress)
        
        let singleTap = UITapGestureRecognizer (target: self, action: #selector(singleTap(_:)))
        addGestureRecognizer(singleTap)
        
        let doubleTap = UITapGestureRecognizer (target: self, action: #selector(doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let pan = UIPanGestureRecognizer (target: self, action: #selector(pan(_:)))
        addGestureRecognizer(pan)
    }

    var _inputAccessory: UIView?
    var _inputView: UIView?
    
    ///
    /// You can set this property to a UIView to be your input accessory, by default
    /// this is an instance of `TerminalAccessory`
    ///
    public override var inputAccessoryView: UIView? {
        get { _inputAccessory }
        set {
            _inputAccessory = newValue
        }
    }

    ///
    /// You can set this property to a UIView to be your input accessory, by default
    /// this is an instance of `TerminalAccessory`
    ///
    public override var inputView: UIView? {
        get { _inputView }
        set {
            _inputView = newValue
        }
    }

    /// Returns the inputaccessory in case it is a TerminalAccessory and we can use it
    var terminalAccessory: TerminalAccessory? {
        get {
            _inputAccessory as? TerminalAccessory
        }
    }

    func setupAccessoryView ()
    {
        let short = UIDevice.current.userInterfaceIdiom == .phone
        let ta = TerminalAccessory(frame: CGRect(x: 0, y: 0, width: frame.width, height: short ? 36 : 48),
                                   inputViewStyle: .keyboard, container: self)
        ta.sizeToFit()
        inputAccessoryView = ta

        //inputAccessoryView?.autoresizingMask = .flexibleHeight
    }
    
    func setupOptions ()
    {
        setupOptions(width: bounds.width, height: bounds.height)
        layer.backgroundColor = nativeBackgroundColor.cgColor
        nativeBackgroundColor = UIColor.clear
    }
    
    var _nativeFg, _nativeBg: TTColor!
    var settingFg = false, settingBg = false
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeForegroundColor: UIColor {
        get { _nativeFg }
        set {
            if settingFg { return }
            settingFg = true
            _nativeFg = newValue
            terminal.foregroundColor = nativeForegroundColor.getTerminalColor ()
            settingFg = false
        }
    }
    
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeBackgroundColor: UIColor {
        get { _nativeBg }
        set {
            if settingBg { return }
            settingBg = true
            _nativeBg = newValue
            terminal.backgroundColor = nativeBackgroundColor.getTerminalColor ()
            colorsChanged()
            settingBg = false
        }
    }

    /// Controls the color for the caret
    public var caretColor: UIColor {
        get { caretView.caretColor }
        set { caretView.caretColor = newValue }
    }
    
    var _selectedTextBackgroundColor = UIColor (red: 204.0/255.0, green: 221.0/255.0, blue: 237.0/255.0, alpha: 1.0)
    /// The color used to render the selection
    public var selectedTextBackgroundColor: UIColor {
        get {
            return _selectedTextBackgroundColor
        }
        set {
            _selectedTextBackgroundColor = newValue
        }
    }
    
    var _selectionHandleColor: UIColor = UIColor.systemBlue
    /// The color used to render the selection handles
    public var selectionHandleColor: UIColor {
        get {
            return _selectionHandleColor
        }
        set {
            _selectionHandleColor = newValue
        }
    }

    var lineAscent: CGFloat = 0
    var lineDescent: CGFloat = 0
    var lineLeading: CGFloat = 0
    
    open func bufferActivated(source: Terminal) {
        updateScroller ()
    }
    
    open func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send (source: self, data: data)
    }
    
    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     */
    open func getOptimalFrameSize () -> CGRect
    {
        return CGRect (x: 0, y: 0, width: cellDimension.width * CGFloat(terminal.cols), height: cellDimension.height * CGFloat(terminal.rows))
    }
    
    func getImageScale () -> CGFloat {
        self.window?.contentScaleFactor ?? 1
    }
    
    func getEffectiveWidth (size: CGSize) -> CGFloat
    {
        return size.width
    }
    
    func updateDebugDisplay ()
    {
    }
    
    func scale (image: UIImage, size: CGSize) -> UIImage {
        UIGraphicsBeginImageContext(size)
        
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        image.draw (in: dstRect)
        
        let ret = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return ret
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        let srcRect = CGRect(x: 0, y: CGFloat(srcY), width: image.size.width, height: srcHeight)
        guard let cropCG = image.cgImage?.cropping(to: srcRect) else {
            return nil
        }
        let uicrop = UIImage (cgImage: cropCG)
        
        let destRect = CGRect(x: 0, y: 0, width: width, height: dstHeight)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return nil
        }
        ctx.translateBy(x: 0, y: dstHeight)
        ctx.scaleBy(x: 1, y: -1)

        uicrop.draw(in: destRect)
        
        let stripe = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return stripe
    }

    open func scrolled(source terminal: Terminal, yDisp: Int) {
        //XselectionView.notifyScrolled(source: terminal)
        updateScroller()
        terminalDelegate?.scrolled(source: self, position: scrollPosition)
    }
    
    open func linefeed(source: Terminal) {
        selection.selectNone()
    }
    
    func updateScroller ()
    {
        contentSize = CGSize (width: CGFloat (terminal.buffer.cols) * cellDimension.width,
                              height: CGFloat (terminal.buffer.lines.count) * cellDimension.height)
        //contentOffset = CGPoint (x: 0, y: CGFloat (terminal.buffer.lines.count-terminal.rows)*cellDimension.height)
        //Xscroller.doubleValue = scrollPosition
        //Xscroller.knobProportion = scrollThumbsize
    }
    
    var userScrolling = false

    func getCurrentGraphicsContext () -> CGContext?
    {
        UIGraphicsGetCurrentContext ()
    }

    func backingScaleFactor () -> CGFloat
    {
        UIScreen.main.scale
    }
    
    override public func draw (_ dirtyRect: CGRect) {
        guard let context = getCurrentGraphicsContext() else {
            return
        }

        // Without these two lines, on font changes, some junk is being displayed
        nativeBackgroundColor.set ()
        context.clear(dirtyRect)

        // drawTerminalContents and CoreText expect the AppKit coordinate system
        context.scaleBy (x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.height)
        drawTerminalContents (dirtyRect: dirtyRect, context: context, offset: 0)
    }
    
    open override var bounds: CGRect {
        get {
            return super.bounds
        }
        set {
            super.bounds = newValue
            if cellDimension == nil {
                return
            }
            processSizeChange(newSize: newValue.size)
            setNeedsDisplay (bounds)
        }
    }

    open override var frame: CGRect {
        get {
            return super.frame
        }
        set {
            super.frame = newValue
            if cellDimension == nil {
                return
            }
            processSizeChange(newSize: newValue.size)
            setNeedsDisplay (bounds)
        }
    }

    // iOS Keyboard input
    
    // UITextInputTraits
    public var keyboardType: UIKeyboardType {
        get {
            .`default`
        }
    }
    
    public var keyboardAppearance: UIKeyboardAppearance = .`default`
    public var returnKeyType: UIReturnKeyType = .`default`
    
    // This is wrong, but I can not find another good one
    public var textContentType: UITextContentType! = .none
    
    public var isSecureTextEntry: Bool = false
    public var enablesReturnKeyAutomatically: Bool = false
    public var autocapitalizationType: UITextAutocapitalizationType  = .none
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    
    public override var canBecomeFirstResponder: Bool {
        true
    }
    
    public override var canBecomeFocused: Bool {
        true
    }
    
    public var hasText: Bool {
        return true
    }

    open func insertText(_ text: String) {
        let sendData = applyTextToInput (text)
        
        if sendData == "" {
            return
        }
        if terminalAccessory?.controlModifier ?? false {
            self.send (applyControlToEventCharacters (sendData))
            terminalAccessory?.controlModifier = false
        } else {
            uitiLog ("Inseting originalText=\"\(text)\" sending=\"\(sendData)\"")
            if sendData == "\n" {
                self.send (data: returnByteSequence [0...])
            } else {
                self.send (txt: sendData)
            }
        }
        
        queuePendingDisplay()
    }

    open func deleteBackward() {
        self.send ([0x7f])
        
        inputDelegate?.selectionWillChange(self)
        // after backward deletion, marked range is always cleared, and length of selected range is always zero
        let rangeToDelete = _markedTextRange ?? _selectedTextRange
        var rangeStartPosition = rangeToDelete._start
        var rangeStartIndex = rangeStartPosition
        if rangeToDelete.isEmpty {
            if rangeStartIndex == 0 {
                return
            }
            rangeStartIndex -= 1
            
            textInputStorage.remove(at: rangeStartIndex)
            
            rangeStartPosition = rangeStartIndex
        } else {
            let maxIdx = textInputStorage.count
            let start = min (rangeToDelete._start, maxIdx)
            let end = min (rangeToDelete._end, maxIdx)
            textInputStorage.removeSubrange(start..<end)
        }
        
        _markedTextRange = nil
        _selectedTextRange = xTextRange(rangeStartPosition, rangeStartPosition)
        inputDelegate?.selectionDidChange(self)
    }

    enum SendData {
        case text(String)
        case bytes([UInt8])
    }
    
    func sendData (data: SendData?)
    {
        switch data {
        case .bytes(let b):
            self.send (b)
        case .text(let txt):
            self.send (txt: txt)
        default:
            break
        }
    }
    
    open override func resignFirstResponder() -> Bool {
        let code = super.resignFirstResponder()
        
        if code {
            keyRepeat?.invalidate()
            keyRepeat = nil
            
            terminalAccessory?.cancelTimer()
        }
        return code
    }
    var keyRepeat: Timer?
    
    /// It looks like sending carriage return works on Unix and Windows remote hosts, so add that, but keeping a public
    /// property in case someone needs the return key to send different sequences.
    public var returnByteSequence: [UInt8] = [13]
    
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var didHandleEvent = false
        
        for press in presses {
            guard let key = press.key else { continue }
                
            var data: SendData? = nil

            switch key.keyCode {
            case .keyboardCapsLock:
                break // ignored
            case .keyboardLeftAlt:
                break // ignored
            case .keyboardLeftControl:
                break // ignored
            case .keyboardLeftShift:
                break // ignored
            case .keyboardLockingCapsLock:
                break // ignored
            case .keyboardLockingNumLock:
                break // ignored
            case .keyboardLockingScrollLock:
                break // ignored
            case .keyboardRightAlt:
                break // ignored
            case .keyboardRightControl:
                break // ignored
            case .keyboardRightShift:
                break // ignored
            case .keyboardScrollLock:
                break // ignored
            case .keyboardUpArrow:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
            case .keyboardDownArrow:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            case .keyboardLeftArrow:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
            case .keyboardRightArrow:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
            case .keyboardPageUp:
                if terminal.applicationCursor {
                    data = .bytes (EscapeSequences.cmdPageUp)
                } else {
                    pageUp()
                }

            case .keyboardPageDown:
                if terminal.applicationCursor {
                    data = .bytes (EscapeSequences.cmdPageDown)
                } else {
                    pageDown()
                }
            case .keyboardHome:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
                
            case .keyboardEnd:
                data = .bytes (terminal.applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
            case .keyboardDeleteForward:
                data = .bytes (EscapeSequences.cmdDelKey)
                
            case .keyboardDeleteOrBackspace:
                data = .bytes ([backspaceSendsControlH ? 8 : 0x7f])
                
            case .keyboardEscape:
                data = .bytes ([0x1b])
                
            case .keyboardInsert:
                print (".keyboardInsert ignored")
                break
                
            case .keyboardReturn:
                data = .bytes (returnByteSequence)
                
            case .keyboardTab:
                data = .bytes ([9])

            case .keyboardF1:
                data = .bytes (EscapeSequences.cmdF [1])
            case .keyboardF2:
                data = .bytes (EscapeSequences.cmdF [2])
            case .keyboardF3:
                data = .bytes (EscapeSequences.cmdF [3])
            case .keyboardF4:
                data = .bytes (EscapeSequences.cmdF [4])
            case .keyboardF5:
                data = .bytes (EscapeSequences.cmdF [5])
            case .keyboardF6:
                data = .bytes (EscapeSequences.cmdF [6])
            case .keyboardF7:
                data = .bytes (EscapeSequences.cmdF [7])
            case .keyboardF8:
                data = .bytes (EscapeSequences.cmdF [8])
            case .keyboardF9:
                data = .bytes (EscapeSequences.cmdF [9])
            case .keyboardF10:
                data = .bytes (EscapeSequences.cmdF [10])
            case .keyboardF11:
                data = .bytes (EscapeSequences.cmdF [11])
            case .keyboardF12, .keyboardF13, .keyboardF14, .keyboardF15, .keyboardF16,
                 .keyboardF17, .keyboardF18, .keyboardF19, .keyboardF20, .keyboardF21,
                 .keyboardF22, .keyboardF23, .keyboardF24:
                break
            case .keyboardPause, .keyboardStop, .keyboardMute, .keyboardVolumeUp, .keyboardVolumeDown:
                break
                
            default:
                if key.modifierFlags.contains (.alternate) {
                    data = .text("\u{1b}\(key.charactersIgnoringModifiers)")
                } else if !key.modifierFlags.contains (.command){
                    if key.characters.count > 0 {
                        data = .text (key.characters)
                    }
                }
            }
            if let sendableData = data {
                didHandleEvent = true
                keyRepeat?.invalidate()
                keyRepeat = Timer (fire: Date(timeInterval: 0.4, since: Date()),
                                   interval: 0.1,
                                   repeats: true) { timer in
                    self.sendData(data: sendableData)
                }
                RunLoop.current.add(keyRepeat!, forMode: .default)
                sendData (data: sendableData)
            }
        }
        if didHandleEvent == false {
            super.pressesBegan(presses, with: event)
        }
    }
    
    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        keyRepeat?.invalidate()
        keyRepeat = nil
        super.pressesEnded(presses, with: event)
    }
    
    var pendingSelectionChanged = false
    
    var buttonBackgroundColor: UIColor = .white
    var buttonShadowColor: UIColor = .black
    var buttonColor: UIColor = .black
    var buttonDarkBackgroundColor: UIColor = .systemGray
    func setupKeyboardButtonColors ()
    {
        func getColor (_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            return UIColor (red: r/255.0, green: g/255.0, blue: b/255.0, alpha: 1.0)
        }
        if traitCollection.userInterfaceStyle == .dark {
            buttonBackgroundColor = UIColor (red: 150/255.0, green: 150/255.0, blue: 150/255.0, alpha: 1)
            buttonShadowColor = UIColor (red: 26/255.0, green: 26/255.0, blue: 26/255.0, alpha: 1)
            buttonColor = .white
            buttonDarkBackgroundColor = getColor (117, 117, 117)
        } else {
            buttonBackgroundColor = UIColor (red: 1, green: 1, blue: 1, alpha: 1)
            buttonShadowColor = UIColor (red: 139/255.0, green: 141/255.0, blue: 144/255.0, alpha: 1)
            buttonColor = .black
            buttonDarkBackgroundColor = getColor (180, 184, 193)
        }
    }
}

extension TerminalView: TerminalDelegate {
    open func selectionChanged(source: Terminal) {
        if pendingSelectionChanged {
            return
        }
        pendingSelectionChanged = true
        DispatchQueue.main.async {
            self.pendingSelectionChanged = false
            
            self.inputDelegate?.selectionWillChange (self)
            self.updateSelectionInBuffer(terminal: source)
            self.inputDelegate?.selectionDidChange(self)
 
            self.setNeedsDisplay (self.bounds)
            
            if !self.selection.active {
                UIMenuController.shared.hideMenu()
            }
        }
    }

    open func isProcessTrusted(source: Terminal) -> Bool {
        true
    }
    
    open func mouseModeChanged(source: Terminal) {
        // iOS TODO
        //X
    }
    
    open func setTerminalTitle(source: Terminal, title: String) {
        DispatchQueue.main.async {
            self.terminalDelegate?.setTerminalTitle(source: self, title: title)
        }
    }
  
    open func sizeChanged(source: Terminal) {
        DispatchQueue.main.async {
            self.terminalDelegate?.sizeChanged(source: self, newCols: source.cols, newRows: source.rows)
            self.updateScroller()
        }
    }
  
    open func setTerminalIconTitle(source: Terminal, title: String) {
        //
    }
  
    // Terminal.Delegate method implementation
    open func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        return nil
    }
}

// Default implementations for TerminalViewDelegate

extension TerminalViewDelegate {    
    public func bell (source: TerminalView)
    {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }    
}

#endif
