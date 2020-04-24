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


/**
 * TerminalView provides an UIKit front-end to the `Terminal` termininal emulator.
 * It is up to a subclass to either wire the terminal emulator to a remote terminal
 * via some socket, to an application that wants to run with terminal emulation, or
 * wiring this up to a pseudo-terminal.
 *
 * Users are notified of interesting events in their implementation of the `TerminalViewDelegate`
 * methods - an instance must be provided to the constructor of `TerminalView`.
 */
open class TerminalView: UIView, UITextInputTraits, UIKeyInput {
    // User facing, customizable view options
    public struct Options {
        
        public struct Font {
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
        
        public struct Colors {
            public let useSystemColors: Bool
            public let foregroundColor: UIColor
            public let backgroundColor: UIColor
            
            public init(useSystemColors: Bool) {
                self.useSystemColors = useSystemColors
                self.foregroundColor = UIColor.gray
                self.backgroundColor = UIColor.black
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
    
    var accessibility: AccessibilityService = AccessibilityService()
    var search: SearchService!
    var debug: UIView?
    var pendingDisplay: Bool = false
    var cellDimension: CellDimension!
    var caretView: CaretView!
    var terminal: Terminal!

    var selection: SelectionService!
    var attrStrBuffer: CircularList<NSAttributedString>!
    
    // Attribute dictionary, maps a console attribute (color, flags) to the corresponding dictionary
    // of attributes for an NSAttributedString
    var attributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    var urlAttributes: [Attribute: [NSAttributedString.Key:Any]] = [:]
    
    // Cache for the colors in the 0..255 range
    var colors: [UIColor?] = Array(repeating: nil, count: 256)
    var trueColors: [Attribute.Color:UIColor] = [:]
    
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
    
    func setup()
    {
        setupOptions ()
    }
    
    func setupOptions ()
    {
        layer.backgroundColor = options.colors.backgroundColor.cgColor
        setupOptions(width: bounds.width, height: bounds.height)
    }

    var lineAscent: CGFloat = 0
    var lineDescent: CGFloat = 0
    var lineLeading: CGFloat = 0
    
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
        return CGRect (x: 0, y: 0, width: cellDimension.width * CGFloat(terminal.cols), height: cellDimension.height * CGFloat(terminal.rows))
    }
    
    func getEffectiveWidth (rect: CGRect) -> CGFloat
    {
        return rect.width
    }
    
    func updateDebugDisplay ()
    {
    }
    
    public func scrolled(source terminal: Terminal, yDisp: Int) {
        //XselectionView.notifyScrolled(source: terminal)
        //XupdateScroller()
        delegate?.scrolled(source: self, position: scrollPosition)
    }
    
    public func linefeed(source: Terminal) {
        selection.selectNone()
    }
    
    func updateScroller ()
    {
        //Xscroller.isEnabled = canScroll
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

        // drawTerminalContents and CoreText expect the AppKit coordinate system
        context.scaleBy (x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.height)
        drawTerminalContents (dirtyRect: dirtyRect, context: context)
    }
    
    public override var frame: CGRect {
        get {
            return super.frame
        }
        set(newValue) {
            super.frame = newValue
            if cellDimension == nil {
                return
            }
            let newRows = Int (newValue.height / cellDimension.height)
            let newCols = Int (getEffectiveWidth (rect: newValue) / cellDimension.width)
            
            if newCols != terminal.cols || newRows != terminal.rows {
                terminal.resize (cols: newCols, rows: newRows)
                fullBufferUpdate (terminal: terminal)
            }
            
            accessibility.invalidate ()
            search.invalidate ()
            
            delegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
            setNeedsDisplay (frame)
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
    public var textContentType: UITextContentType! = .familyName
    
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

    public var hasText: Bool {
        return true
    }

    public func insertText(_ text: String) {
        self.send (txt: text)
        setNeedsDisplay()
    }

    public func deleteBackward() {
        self.send ([0x7f])
    }

    enum SendData {
        case text(String)
        case bytes([UInt8])
    }
    
    var sentData: SendData?
    
    func sendData (data: SendData?)
    {
        switch sentData {
        case .bytes(let b):
            self.send (b)
        case .text(let txt):
            self.send (txt: txt)
        default:
            break
        }
    }
    
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else { return }

        sentData = nil

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
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveUpApp : EscapeSequences.MoveUpNormal)
        case .keyboardDownArrow:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveDownApp : EscapeSequences.MoveDownNormal)
        case .keyboardLeftArrow:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveLeftApp : EscapeSequences.MoveLeftNormal)
        case .keyboardRightArrow:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveRightApp : EscapeSequences.MoveRightNormal)
        case .keyboardPageUp:
            if terminal.applicationCursor {
                sentData = .bytes (EscapeSequences.CmdPageUp)
            } else {
                pageUp()
            }

        case .keyboardPageDown:
            if terminal.applicationCursor {
                sentData = .bytes (EscapeSequences.CmdPageDown)
            } else {
                pageDown()
            }
        case .keyboardHome:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveHomeApp : EscapeSequences.MoveHomeNormal)
            
        case .keyboardEnd:
            sentData = .bytes (terminal.applicationCursor ? EscapeSequences.MoveEndApp : EscapeSequences.MoveEndNormal)
        case .keyboardDeleteForward:
            sentData = .bytes (EscapeSequences.CmdDelKey)
            
        case .keyboardDeleteOrBackspace:
            sentData = .bytes ([0x7f])
            
        case .keyboardEscape:
            sentData = .bytes ([0x1b])
            
        case .keyboardInsert:
            print (".keyboardInsert ignored")
            break
            
        case .keyboardReturn:
            sentData = .bytes ([10])
            
        case .keyboardTab:
            sentData = .bytes ([9])

        case .keyboardF1:
            sentData = .bytes (EscapeSequences.CmdF [1])
        case .keyboardF2:
            sentData = .bytes (EscapeSequences.CmdF [2])
        case .keyboardF3:
            sentData = .bytes (EscapeSequences.CmdF [3])
        case .keyboardF4:
            sentData = .bytes (EscapeSequences.CmdF [4])
        case .keyboardF5:
            sentData = .bytes (EscapeSequences.CmdF [5])
        case .keyboardF6:
            sentData = .bytes (EscapeSequences.CmdF [6])
        case .keyboardF7:
            sentData = .bytes (EscapeSequences.CmdF [7])
        case .keyboardF8:
            sentData = .bytes (EscapeSequences.CmdF [8])
        case .keyboardF9:
            sentData = .bytes (EscapeSequences.CmdF [9])
        case .keyboardF10:
            sentData = .bytes (EscapeSequences.CmdF [10])
        case .keyboardF11:
            sentData = .bytes (EscapeSequences.CmdF [11])
        case .keyboardF12, .keyboardF13, .keyboardF14, .keyboardF15, .keyboardF16,
             .keyboardF17, .keyboardF18, .keyboardF19, .keyboardF20, .keyboardF21,
             .keyboardF22, .keyboardF23, .keyboardF24:
            break
            
        case .keyboardPause, .keyboardStop, .keyboardMute, .keyboardVolumeUp, .keyboardVolumeDown:
            break
            
        default:
            if key.modifierFlags.contains (.alternate) {
                send (EscapeSequences.CmdEsc)
                send (txt: key.charactersIgnoringModifiers)
            } else {
                sentData = .text (key.characters)
            }
        }
        
        // TODO - setup timer to keep sending the key until the key is released
        sendData (data: sentData)
    }
    
    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else { return }
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
        if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = NSURLComponents(string: fixedup) {
                if let nested = url.url {
                    UIApplication.shared.open (nested)
                }
            }
        }
    }
}

extension UIColor {
    func inverseColor() -> UIColor {
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor (red: 1.0 - red, green: 1.0 - green, blue: 1.0 - blue, alpha: alpha)
    }

    // TODO: Come up with something better
    static var selectedTextBackgroundColor: UIColor {
        get {
            UIColor.green
        }
    }
    
    static func make (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> TTColor
    {
        
        return UIColor(red: red,
                       green: green,
                       blue: blue,
                       alpha: 1.0)
    }
}
#endif
