//
//  MacTerminalView.swift
//
// This is the AppKit version of the TerminalView and holds the state
// variables in the `TerminalView` class, but as much of the terminal
// implementation details live in the Apple/AppleTerminalView which
// contains the shared AppKit/UIKit code
//
//  Created by Miguel de Icaza on 3/4/20.
//

#if os(macOS)
import Foundation
import AppKit
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
 *
 * Developers might want to surface UIs for `optionAsMetaKey` and `allowMouseReporting` in
 * their application.  They both default to true, but this means that Option-Letter is hijacked for
 * terminal purposes to send the sequence ESC-Letter, instead of the macOS specific character and
 * means that when mouse-aware applications are running, they hijack the normal selection process.
 *
 * Call the `getTerminal` method to get a reference to the underlying `Terminal` that backs this
 * view.
 *
 * Use the `configureNativeColors()` to set the defaults colors for the view to match the OS
 * defaults, otherwise, this uses its own set of defaults colors.
 */
open class TerminalView: NSView, NSTextInputClient, NSUserInterfaceValidations, TerminalDelegate {
    struct FontSet {
        public let normal: NSFont
        let bold: NSFont
        let italic: NSFont
        let boldItalic: NSFont
        
        static var defaultFont: NSFont {
            if #available(macOS 10.15, *)  {
                return NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            } else {
                return NSFont(name: "Menlo Regular", size: NSFont.systemFontSize) ?? NSFont(name: "Courier", size: NSFont.systemFontSize)!
            }
        }
        
        public init(font baseFont: NSFont, fontSize: CGFloat? = nil) {
            self.normal = baseFont
            self.bold = NSFontManager.shared.convert(baseFont, toHaveTrait: [.boldFontMask])
            self.italic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask])
            self.boldItalic = NSFontManager.shared.convert(baseFont, toHaveTrait: [.italicFontMask, .boldFontMask])
        }

        // Expected by the shared rendering code
        func underlinePosition () -> CGFloat
        {
            return normal.underlinePosition
        }

        // Expected by the shared rendering code
        func underlineThickness () -> CGFloat
        {
            return normal.underlineThickness
        }
    }
    
    /**
     * The delegate that the TerminalView uses to interact with its hosting
     */
    public weak var terminalDelegate: TerminalViewDelegate?
    
    /// If true, the caret view will show different shapes depending on the focus
    /// otherwise, it will behave like it is focused
    public var caretViewTracksFocus: Bool {
        get {
            return caretView.tracksFocus
        }
        set {
            caretView.tracksFocus = newValue
        }
    }

    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    var debug: TerminalDebugView?
    var pendingDisplay: Bool = false
    
    var cellDimension: CellDimension!
    var caretView: CaretView!
    public var terminal: Terminal!

    var selection: SelectionService!
    private var scroller: NSScroller!
    
    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary
    // of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    
    
    // Cache for the colors in the 0..255 range
    var colors: [NSColor?] = Array(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:NSColor] = [:]
    var transparent = TTColor.transparent ()
    var isBigSur = true
    
    /// This flag is automatically set to true after the initializer is called, if running on a system older than BigSur.
    /// Starting with BigSur any screen updates will invoke the draw() method with the whole region, regardless
    /// of how much changed.   Setting this to true, will disable this OS behavior, setting it to false, will keep
    /// the original BigSur behavior to redraw the whole region.
    ///
    /// For more details on this see:
    /// https://gist.github.com/lukaskubanek/9a61ac71dc0db8bb04db2028f2635779
    /// https://developer.apple.com/forums/thread/663256?answerId=646653022#646653022
    public var disableFullRedrawOnAnyChanges = false
    var fontSet: FontSet

    /// The font to use to render the terminal
    public var font: NSFont {
        get {
            return fontSet.normal
        }
        set {
            fontSet = FontSet (font: newValue)
            resetFont()
            selectNone()
        }
    }
    
    public init(frame: CGRect, font: NSFont?) {
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
    
    private func setup()
    {
        wantsLayer = true
        isBigSur = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0))
        if isBigSur {
            disableFullRedrawOnAnyChanges = true
        }
        if #available(macOS 14, *) {
            self.clipsToBounds = true
        }
        setupScroller()
        setupOptions()
        setupFocusNotification()
    }
    
    func startDisplayUpdates ()
    {
        // Not used on Mac
    }
    
    func suspendDisplayUpdates()
    {
        // Not used on Mac
    }
    
    var becomeMainObserver, resignMainObserver: NSObjectProtocol?
    
    deinit {
        if let becomeMainObserver {
            NotificationCenter.default.removeObserver (becomeMainObserver)
        }
        if let resignMainObserver {
            NotificationCenter.default.removeObserver (resignMainObserver)
        }
    }
    
    func setupFocusNotification() {
        becomeMainObserver = NotificationCenter.default.addObserver(forName: .init("NSWindowDidBecomeMainNotification"), object: nil, queue: nil) { [unowned self] notification in
            self.caretView.updateCursorStyle()
        }
        resignMainObserver = NotificationCenter.default.addObserver(forName: .init("NSWindowDidResignMainNotification"), object: nil, queue: nil) { [unowned self] notification in
            self.caretView.disableAnimations()
            self.caretView.updateView()
        }
    }
    
    func setupOptions ()
    {
        setupOptions (width: getEffectiveWidth (size: bounds.size), height: bounds.height)
        layer?.backgroundColor = nativeBackgroundColor.cgColor
    }

    /// This controls whether the backspace should send ^? or ^H, the default is ^?
    public var backspaceSendsControlH: Bool = false
    
    var _nativeFg, _nativeBg: TTColor!
    var settingFg = false, settingBg = false
    /**
     * This will set the native foreground color to the specified native color (UIColor or NSColor)
     * and will have this reflected into the underlying's terminal `foregroundColor` and
     * `backgroundColor`
     */
    public var nativeForegroundColor: NSColor {
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
    public var nativeBackgroundColor: NSColor {
        get { _nativeBg }
        set {
            if settingBg { return }
            settingBg = true
            _nativeBg = newValue
            terminal.backgroundColor = nativeBackgroundColor.getTerminalColor ()
            settingBg = false
        }
    }
    
    /// Controls weather to use high ansi colors, if false terminal will use bold text instead of high ansi colors
    public var useBrightColors: Bool = true
    
    /// Controls the color for the caret
    public var caretColor: NSColor {
        get { caretView.caretColor }
        set { caretView.caretColor = newValue }
    }

    /// Controls the color for the text in the caret when using a block cursor, if not set
    /// the cursor will render with the foreground color
    public var caretTextColor: NSColor? {
        get { caretView.caretTextColor }
        set { caretView.caretTextColor = newValue }
    }

    var _selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
    /// The color used to render the selection
    public var selectedTextBackgroundColor: NSColor {
        get {
            return _selectedTextBackgroundColor
        }
        set {
            _selectedTextBackgroundColor = newValue
        }
    }

    func backingScaleFactor () -> CGFloat
    {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
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
        if scroller != nil {
            scroller.removeFromSuperview()
        }

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
    
    /// This method sents the `nativeForegroundColor` and `nativeBackgroundColor`
    /// to match macOS default colors for text and its background.
    public func configureNativeColors ()
    {
        self.nativeForegroundColor = NSColor.textColor
        self.nativeBackgroundColor = NSColor.textBackgroundColor

    }
    
    open func bufferActivated(source: Terminal) {
        updateScroller ()
    }
    
    open func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send (source: self, data: data)
    }
        
    /**
     * Given the current set of columns and rows returns a frame that would host this control.
     */
    open func getOptimalFrameSize () -> NSRect
    {
        return NSRect (x: 0, y: 0, width: cellDimension.width * CGFloat(terminal.cols) + scroller.frame.width, height: cellDimension.height * CGFloat(terminal.rows))
    }
    
    func getEffectiveWidth (size: CGSize) -> CGFloat
    {
        return (size.width-scroller.frame.width)
    }
    
    open func scrolled(source terminal: Terminal, yDisp: Int) {
        //selectionView.notifyScrolled(source: terminal)
        updateScroller()
        terminalDelegate?.scrolled(source: self, position: scrollPosition)
    }
    
    open func linefeed(source: Terminal) {
        selection.selectNone()
    }
    
    /// This vaiable controls whether mouse events are sent to the application running under the
    /// terminal if it has requested the data.   This poses a problem for selection, so users
    /// need a way of toggling this behavior.
    public var allowMouseReporting: Bool = true

    /**
     * If set to true, this will call the TerminalViewDelegate's rangeChanged method
     * when there are changes that are being performed on the UI
     */
    public var notifyUpdateChanges = false

    func updateDebugDisplay()
    {
        debug?.update()
    }
    
    func updateScroller ()
    {
        scroller.isEnabled = canScroll
        scroller.doubleValue = scrollPosition
        scroller.knobProportion = scrollThumbsize
    }
    
    var userScrolling = false

    override open func viewWillDraw() {
        
        // Starting with BigSur, it looks like even sending one pixel to be redrawn will trigger
        // a call to draw() for the whole surface
        if disableFullRedrawOnAnyChanges {
            let layer = self.layer
            layer?.contentsFormat = .RGBA8Uint
        }
    }
    #if false
    override open func setNeedsDisplay(_ invalidRect: NSRect) {
        print ("setNeeds: \(invalidRect)")
        super.setNeedsDisplay(invalidRect)
    }
    #endif
    
    func getCurrentGraphicsContext () -> CGContext?
    {
        NSGraphicsContext.current?.cgContext
    }
    
    override public func draw (_ dirtyRect: NSRect) {
        guard let currentContext = getCurrentGraphicsContext() else {
            return
        }
        drawTerminalContents (dirtyRect: dirtyRect, context: currentContext, bufferOffset: terminal.buffer.yDisp)
    }
    
    public override func cursorUpdate(with event: NSEvent)
    {
        NSCursor.iBeam.set ()
    }
    
    func makeFirstResponder ()
    {
        window?.makeFirstResponder (self)
    }
    
    open override var frame: NSRect {
        get {
            return super.frame
        }
        set(newValue) {
            super.frame = newValue
            guard cellDimension != nil else { return }
            processSizeChange(newSize: newValue.size)
            needsDisplay = true
            updateCursorPosition()
        }
    }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setupScroller()
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateScroller()
        selection.active = false
    }
    
    private var _hasFocus = false
    open var hasFocus : Bool {
        get {
            //print ("hasFocus: \(_hasFocus) window=\(window?.isKeyWindow)")
            return _hasFocus && (window?.isKeyWindow ?? true)
        }
        set {
            _hasFocus = newValue
            caretView.focused = newValue
        }
    }

    //
    // NSTextInputClient protocol implementation
    //
    public override func becomeFirstResponder() -> Bool {
        let response = super.becomeFirstResponder()
        if response {
            hasFocus = true
            caretView.updateCursorStyle()
        }
        return response
    }
    
    public override func resignFirstResponder() -> Bool {
        let response = super.resignFirstResponder()
        if response {
            caretView.disableAnimations()
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
            
            if let payload = getPayload(for: event) as? String {
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
    
    /// If set to true, the terminal treats the "Option" key as the Meta key in old terminals,
    /// which has the effect of sending the ESC character before the character that was
    /// entered.  Applications use this to provide bindings for Alt-keys, or in Emacs terms
    /// the Meta key (M-x stands for Meta-x, or pressing the option key and x).
    ///
    /// If this is set to `false`, then the key is passed to the OS, which produces the
    /// OS specific feature.
    public var optionAsMetaKey: Bool = true
    
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
        if eventFlags.contains ([.option, .command]) {
            if event.charactersIgnoringModifiers == "o" {
                optionAsMetaKey.toggle()
            }
        } else if optionAsMetaKey && eventFlags.contains (.option) {
            if let rawCharacter = event.charactersIgnoringModifiers {
                if let fs = rawCharacter.unicodeScalars.first {
                    switch Int (fs.value) {
                    case NSLeftArrowFunctionKey:
                        send (EscapeSequences.emacsBack)
                        return
                    case NSRightArrowFunctionKey:
                        send (EscapeSequences.emacsForward)
                        return
                    default: break
                    }
                }
                send (EscapeSequences.cmdEsc)
                send (txt: rawCharacter)
            }
            return
        } else if eventFlags.contains (.control) {
            // Sends the control sequence
            if let ch = event.charactersIgnoringModifiers {
                send (applyControlToEventCharacters (ch))
                return
            }
        } else if eventFlags.contains (.function) {
            if let str = event.charactersIgnoringModifiers {
                if let fs = str.unicodeScalars.first {
                    let c = Int (fs.value)
                    switch c {
                    case NSF1FunctionKey:
                        send (EscapeSequences.cmdF [0])
                    case NSF2FunctionKey:
                        send (EscapeSequences.cmdF [1])
                    case NSF3FunctionKey:
                        send (EscapeSequences.cmdF [2])
                    case NSF4FunctionKey:
                        send (EscapeSequences.cmdF [3])
                    case NSF5FunctionKey:
                        send (EscapeSequences.cmdF [4])
                    case NSF6FunctionKey:
                        send (EscapeSequences.cmdF [5])
                    case NSF7FunctionKey:
                        send (EscapeSequences.cmdF [6])
                    case NSF8FunctionKey:
                        send (EscapeSequences.cmdF [7])
                    case NSF9FunctionKey:
                        send (EscapeSequences.cmdF [8])
                    case NSF10FunctionKey:
                        send (EscapeSequences.cmdF [9])
                    case NSF11FunctionKey:
                        send (EscapeSequences.cmdF [10])
                    case NSF12FunctionKey:
                        send (EscapeSequences.cmdF [11])
                    case NSDeleteFunctionKey:
                        send (EscapeSequences.cmdDelKey)
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
            send (EscapeSequences.cmdRet)
        case #selector(cancelOperation(_:)):
            send (EscapeSequences.cmdEsc)
        case #selector(deleteBackward(_:)):
            send ([backspaceSendsControlH ? 8 : 0x7f])
        case #selector(moveUp(_:)):
            sendKeyUp()
        case #selector(moveDown(_:)):
            sendKeyDown()
        case #selector(moveLeft(_:)):
            sendKeyLeft()
        case #selector(moveRight(_:)):
            sendKeyRight()
        case #selector(insertTab(_:)):
            send (EscapeSequences.cmdTab)
        case #selector(insertBacktab(_:)):
            send (EscapeSequences.cmdBackTab)
        case #selector(moveToBeginningOfLine(_:)):
            send (terminal.applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal)
        case #selector(moveToEndOfLine(_:)):
            send (terminal.applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal)
        case #selector(scrollPageUp(_:)):
            fallthrough
        case #selector(pageUp(_:)):
            if terminal.applicationCursor {
                send (EscapeSequences.cmdPageUp)
            } else {
                pageUp()
            }
        case #selector(scrollPageDown(_:)):
            fallthrough
        case #selector(pageDown(_:)):
            if terminal.applicationCursor {
                send (EscapeSequences.cmdPageDown)
            } else {
                pageDown()
            }
        case #selector(pageDownAndModifySelection(_:)):
            if terminal.applicationCursor {
                // TODO: view should scroll one page up.
            } else {
                send (EscapeSequences.cmdPageDown)
            }
        case #selector(moveToLeftEndOfLine(_:)):
            // Apple sends the Emacs back-word commands
            send (EscapeSequences.emacsBack)
        case #selector(moveToRightEndOfLine(_:)):
            send (EscapeSequences.emacsForward)
        default:
            print ("Unhandle selector \(selector)")
        }
    }
    
    // NSTextInputClient protocol implementation
    open func insertText(_ string: Any, replacementRange: NSRange) {
        if let str = string as? NSString {
            send (txt: str as String)
        }
        // TODO: I do not think we actually need this needsDisplay, the data fed should bubble this up
        // needsDisplay = true
    }
    
    // NSTextInputClient protocol implementation
    open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // nothing
    }
    
    // NSTextInputClient protocol implementation
    open func unmarkText() {
        // nothing
    }
    
    // NSTextInputClient protocol implementation
    open func selectedRange() -> NSRange {
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
    open func markedRange() -> NSRange {
        print ("markedRange: This should return the actual range from the selection")
        
        // This means "no marked" - when we fix, we should address
        return NSRange.empty
    }
    
    // NSTextInputClient protocol implementation
    open func hasMarkedText() -> Bool {
        // print ("hasMarkedText: This should return the actual range from the selection")
        // TODO
        return false
    }
    
    // NSTextInputClient protocol implementation
    open func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        print ("Attribuetd string")
        return nil
    }
    
    // NSTextInputClient Protocol implementation
    open func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        // TODO print ("validAttributesForMarkedText: This should return the actual range from the selection")
        return []
    }
    
    // NSTextInputClient protocol implementation
    open func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        
        if let r = window?.convertToScreen(convert(caretView!.frame, to: nil)) {
            return r
        }
        
        return .zero
    }
    
    // NSTextInputClient protocol implementation
    open func characterIndex(for point: NSPoint) -> Int {
        print ("characterIndex:for point: This should return the actual range from the selection")
        return NSNotFound
    }
    
    open func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
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
    
    open func selectionChanged(source: Terminal) {
        needsDisplay = true
    }
    
    func cut (sender: Any?) {}
    
    @objc
    open func paste(_ sender: Any)
    {
        let clipboard = NSPasteboard.general
        let text = clipboard.string(forType: .string)
        insertText(text ?? "", replacementRange: NSRange(location: 0, length: 0))
    }
    
    @objc
    open func copy(_ sender: Any)
    {
        // find the selected range of text in the buffer and put in the clipboard
        let str = selection.getSelectedText()
        
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(str, forType: .string)
    }
    
    public override func selectAll(_ sender: Any?)
    {
        selectAll ()
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
    
    func calculateMouseHit (with event: NSEvent) -> (grid: Position, pixels: Position)
    {
        func toInt (_ p: NSPoint) -> Position {
            
            let x = min (max (p.x, 0), bounds.width)
            let y = min (max (p.y, 0), bounds.height)
            return Position (col: Int (x), row: Int (bounds.height-y))
        }
        let point = convert(event.locationInWindow, from: nil)
        let col = Int (point.x / cellDimension.width)
        let row = Int ((frame.height-point.y) / cellDimension.height)
        if row < 0 {
            return (Position(col: 0, row: 0), toInt (point))
        }
        return (Position(col: min (max (0, col), terminal.cols-1), row: min (row, terminal.rows-1)), toInt (point))
    }
    
    private func sharedMouseEvent (with event: NSEvent)
    {
        let hit = calculateMouseHit(with: event)
        let buttonFlags = encodeMouseEvent(with: event)
        terminal.sendEvent(buttonFlags: buttonFlags, x: hit.grid.col, y: hit.grid.row, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
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
        if allowMouseReporting && terminal.mouseMode.sendButtonPress() {
            sharedMouseEvent(with: event)
            return
        }
        
        let hit = calculateMouseHit(with: event).grid
        
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
        setNeedsDisplay(bounds)
    }
    
    func getPayload (for event: NSEvent) -> Any?
    {
        let hit = calculateMouseHit(with: event).grid
        let cd = terminal.buffer.lines [terminal.buffer.yDisp+hit.row][hit.col]
        return cd.getPayload()
    }
    
    var didSelectionDrag: Bool = false
    
    public override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command){
            if let payload = getPayload(for: event) as? String {
                if let (url, params) = urlAndParamsFrom(payload: payload) {
                    terminalDelegate?.requestOpenLink(source: self, link: url, params: params)
                }
            }
        }
        if allowMouseReporting && terminal.mouseMode.sendButtonRelease() {
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
        let mouseHit = calculateMouseHit(with: event)
        let hit = mouseHit.grid
        if allowMouseReporting {
            if terminal.mouseMode.sendMotionEvent() {
                let flags = encodeMouseEvent(with: event)
            
                terminal.sendMotion(buttonFlags: flags, x: hit.col, y: hit.row, pixelX: mouseHit.pixels.col, pixelY: mouseHit.pixels.row)
            
                return
            }
            if terminal.mouseMode != .off {
                return
            }
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
        setNeedsDisplay(bounds)
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
                let nup: NSTextField
                if #available(macOS 10.12, *) {
                    nup = NSTextField (string: url)
                } else {
                    nup = NSTextField ()
                }
                nup.isBezeled = false
                nup.font = tryUrlFont ()
                nup.backgroundColor = nativeForegroundColor
                nup.textColor = nativeBackgroundColor
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
            if let payload = getPayload(for: event) as? String {
                previewUrl (payload: payload)
            }
        }
        
        if terminal.mouseMode.sendMotionEvent() {
            let flags = encodeMouseEvent(with: event)
            terminal.sendMotion(buttonFlags: flags, x: hit.grid.col, y: hit.grid.row, pixelX: hit.pixels.col, pixelY: hit.pixels.row)
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
    
    public func resetFontSize ()
    {
        fontSet = FontSet (font: FontSet.defaultFont)
    }
    
    func getImageScale () -> CGFloat {
        self.window?.backingScaleFactor ?? 1
    }
    
    func scale (image: NSImage, size: CGSize) -> NSImage {
        
        let scaledImg = TTImage (size: CGSize (width: size.width, height: size.height))
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        scaledImg.lockFocus()
        let srcRect = CGRect(origin: CGPoint.zero, size: image.size)
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        image.draw(in: dstRect, from: srcRect, operation: .copy, fraction: 1)
        
        scaledImg.unlockFocus()
        return scaledImg
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        guard let bitmapImage = NSBitmapImageRep (
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: NSColorSpaceName.calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        let stripe = NSImage (size: size)
        stripe.addRepresentation (bitmapImage)

        stripe.lockFocus()
        let srcRect = CGRect(x: 0, y: CGFloat(srcY), width: image.size.width, height: srcHeight)
        let destRect = CGRect(x: 0, y: 0, width: width, height: dstHeight)
        image.draw(in: destRect, from: srcRect, operation: .copy, fraction: 1.0)
        stripe.unlockFocus()
        return stripe
    }
    
    open func showCursor(source: Terminal) {
        if caretView.superview == nil {
            addSubview(caretView)
        }
    }

    open func hideCursor(source: Terminal) {
        caretView.removeFromSuperview()
    }
    
    open func cursorStyleChanged (source: Terminal, newStyle: CursorStyle) {
        caretView.style = newStyle
        updateCaretView()
    }

    open func bell(source: Terminal) {
        terminalDelegate?.bell (source: self)
    }

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
    
    public func setTerminalTitle(source: Terminal, title: String) {
        terminalDelegate?.setTerminalTitle(source: self, title: title)
    }
    
    public func sizeChanged(source: Terminal) {
        terminalDelegate?.sizeChanged(source: self, newCols: source.cols, newRows: source.rows)
        updateScroller ()
    }
    
    func ensureCaretIsVisible ()
    {
        let realCaret = terminal.buffer.y + terminal.buffer.yBase
        let viewportEnd = terminal.buffer.yDisp + terminal.rows
        
        if realCaret >= viewportEnd || realCaret < terminal.buffer.yDisp {
            scrollTo (row: terminal.buffer.yBase)
        }
    }
    
    public func setTerminalIconTitle(source: Terminal, title: String) {
        //
    }
    
    // Terminal.Delegate method implementation
    public func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        return nil
    }
    
    public func iTermContent (source: Terminal, content: ArraySlice<UInt8>) {
        terminalDelegate?.iTermContent(source: self, content: content)
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
    
    public func bell (source: TerminalView)
    {
        NSSound.beep()
    }
    
    public func iTermContent (source: TerminalView, content: ArraySlice<UInt8>) {
    }
}
#endif
