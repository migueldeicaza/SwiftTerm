//
//  CharData.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

/// This option set describes the character style for a cell, this includes
/// information about the font to use as well as decorations on the text
public struct CharacterStyle : OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    
    /**
     * Constructs a character attribute from a raw value.
     */
    public init (rawValue: UInt8)
    {
        self.rawValue = rawValue
    }
    
    /**
     * Constructs the CharacterStyle from a CharData.attribute that encodes the foreground, background and flags
     */
    public init (attribute: Int32)
    {
        rawValue = UInt8 ((attribute >> 18) & 0xff)
    }
    
    /// Empty style
    public static let none = CharacterStyle ([])
    /// Use a bold font
    public static let bold = CharacterStyle (rawValue: 1)
    /// Underline the currentlin line
    public static let underline = CharacterStyle (rawValue: 2)
    /// The text should blink
    public static let blink = CharacterStyle (rawValue: 4)
    /// The text should be inverted (background and foreground are swapped)
    public static let inverse = CharacterStyle (rawValue: 8)
    /// The text should be replaced with white space - there is a debate as to what to do about it when copy/pasting
    /// code as different terminal emulators have taken conflicting takes, so your UI driver might have to choose
    public static let invisible = CharacterStyle (rawValue: 16)
    /// Font should be rendered more lightly, implementation specific
    public static let dim = CharacterStyle (rawValue: 32)
    /// Use italic fonts
    public static let italic = CharacterStyle (rawValue: 64)
    /// Cross out the text
    public static let crossedOut = CharacterStyle (rawValue: 128)
}

public enum UnderlineStyle: UInt8, Sendable {
    case none = 0
    case single = 1
    case double = 2
    case curly = 3
    case dotted = 4
    case dashed = 5
}

///
/// Attribute contains the foreground and background color information for the invidual
/// cells, as well as the character style of the cell (bold, underline, inverse) that the character
/// should be drawn as.
///
public struct Attribute: Equatable, Hashable, Sendable {
    /// The various ways in which the color was expressed
    public enum Color: Equatable, Hashable, Sendable {
        /// This means that the foreground color stores 8 bits of information
        /// for the color (the original ANSI colors, plus a crop of colors
        /// and greys - those defined in Color.setupDefaultAnsiColors and additionally
        /// we reserve two values "defaultForeground" and "defaultBackground" that
        /// indicate that the terminal can pick the right values for those.
        case ansi256(code: UInt8)
        
        /// This means that the color has been configured to be a 24-bit true color
        /// and has 8 bits for red, green and blue
        case trueColor(red: UInt8, green: UInt8, blue: UInt8)
        
        /// Indicates that the cell uses the default foreground color
        case defaultColor
        
        /// Indicates that the cell uses teh default backgrond color (also used as the inverse color)
        case defaultInvertedColor
        
        public static func ==(lhs: Color, rhs: Color) -> Bool
        {
            switch (lhs, rhs) {
            case (.ansi256(let lc), .ansi256(let rc)):
                return lc == rc
            case (.defaultColor, .defaultColor):
                return true
            case (.defaultInvertedColor, .defaultInvertedColor):
                return true
            case (.trueColor(let lr, let lg, let lb), .trueColor(let rr, let rg, let rb)):
                return lr == rr && lg == rg && lb == rb
            default:
                return false
            }
        }
    }
    
    /// The empty attribute is configured to be use the defaultColor for the foreground, and the
    /// defaultInvertedColor for the background and an emptu style
    public static let empty = Attribute (fg: .defaultColor, bg: .defaultInvertedColor, style: .none)
    
    /// Foreground and background colors
    public private(set) var fg, bg: Color
    // The cell attributes
    public private(set) var style: CharacterStyle
    /// Underline style (optional)
    public private(set) var underlineStyle: UnderlineStyle = .none
    /// Optional underline color
    public private(set) var underlineColor: Color? = nil
    
    public static func ==(lhs: Attribute, rhs: Attribute) -> Bool
    {
        lhs.style == rhs.style &&
            lhs.fg == rhs.fg &&
            lhs.bg == rhs.bg &&
            lhs.underlineStyle == rhs.underlineStyle &&
            lhs.underlineColor == rhs.underlineColor
    }
    
    // Returns an attribute with just the colors
    func justColor () -> Attribute
    {
        Attribute (fg: fg, bg: bg, style: .none, underlineStyle: .none, underlineColor: underlineColor)
    }
    
    // Temporary, longer term in Attribute we will add a proper encoding
    func toSgr () -> String
    {
        var result = "0"
        
        if style.contains(.bold) {
            result += ";1"
        }
        if style.contains (.underline) {
            result += ";4"
        }
        if style.contains (.blink) {
            result += ";5"
        }
        if style.contains (.inverse) {
            result += ";7"
        }
        if style.contains (.invisible) {
            result += ";8"
        }
        
        switch fg {
        case .ansi256(let c):
            if c > 16 {
                result += ";38;5;\(c)"
            } else {
                result += ";\(c >= 8 ? 9 : 3)\(c >= 8 ? c - 8 : c);"
            }
        case .trueColor(let r, let g, let b):
            result += ";38;2;\(r);\(g);\(b)"
        default:
            break
        }

        switch bg {
        case .ansi256(let c):
            if c > 16 {
                result += ";48;5;\(c)"
            } else {
                result += ";\(c >= 8 ? 10 : 4)\(c >= 8 ? c - 8 : c);"
            }
        case .trueColor(let r, let g, let b):
            result += ";48;2;\(r);\(g);\(b)"
        default:
            break
        }
        result += "m"
        return result
    }
}

/// TinyAtoms are 16-bit values that can be used to represent a value as a number.
/// You create them by calling `TinyAtom.lookup(value:)` with a `Sendable` value.
/// Retrieve the value with the `target` property. They store URLs and other
/// parameters for OSC 8, or binary data for images.
///
/// The packed terminal cell stores this code in 16 bits. It could use 24 bits
/// if the packed-cell layout changes.
public struct TinyAtom: Sendable {
    var code: UInt16
    private struct State {
        var map: [UInt16: any Sendable] = [:]
        var lastUsed: UInt16 = 0
    }
    private static let state = Locked(State())
    static let empty = TinyAtom (code: 0)
   
    private init(code: UInt16)
    {
        self.code = code
    }

    /// Rebuilds an atom value that a cell-storage page owns.
    ///
    /// The page stores only the 16-bit code. The global atom table continues
    /// to own the target until the terminal releases the code.
    static func stored(code: UInt16) -> TinyAtom {
        TinyAtom(code: code)
    }
    
    /// Creates a caller-owned TinyAtom for the specified value, or returns nil if no codes remain.
    ///
    /// The caller must call ``release()`` when the atom is no longer in use. Use
    /// ``Terminal/makePayload(value:)`` for an atom whose lifetime is managed by a terminal.
    public static func lookup<Value: Sendable>(value: Value) -> TinyAtom? {
        state.withLock { state in
            guard state.lastUsed < UInt16.max - 1 else {
                return nil
            }
            state.lastUsed += 1
            let code = state.lastUsed

            state.map [code] = value
            return TinyAtom (code: code)
        }
    }
    
    public static func release(code: UInt16) {
        release(codes: [code])
    }

    /// Releases a caller-owned atom.
    ///
    /// After this call, ``target`` returns nil for this atom and for all copies of it.
    public func release() {
        TinyAtom.release(code: code)
    }

    static func release<S: Sequence>(codes: S) where S.Element == UInt16 {
        state.withLock { state in
            for code in codes where code != 0 {
                state.map.removeValue(forKey: code)
            }
        }
    }
    
    /// Returns the target for the TinyAtom
    public var target: (any Sendable)? {
        get {
            if code == 0 {
                return nil
            }
            return TinyAtom.state.withLock { state in
                state.map [code]
            }
        }
    }
}

/**
 * Provides an API value for one terminal cell.
 *
 * `BufferLine` stores an 8-byte `PackedCell`. It creates a `CharData` value
 * when a caller reads a cell and stores large values in its page side tables.
 * Use `getCharacter()` for both simple scalars and grapheme clusters.
 */
public struct CharData: CustomDebugStringConvertible, Sendable {
    public var debugDescription: String {
        let ch: Character
        if let scalar = UnicodeScalar(Int(code)) {
            ch = Character(scalar)
        } else {
            ch = "?"
        }
        
        return "CharData: \(code) \(ch)"
    }
    
    static let maxRune = 0x10ffff

    static let defaultAttr = Attribute(fg: .defaultColor, bg: .defaultColor, style: .none)
    static let invertedAttr = Attribute(fg: .defaultInvertedColor, bg: .defaultInvertedColor, style: .none)
    
    // Contains the scalar or the first scalar of a grapheme cluster.
    var code: Int32

    // BufferLine stores these values in its page grapheme table. This field
    // exists only in the temporary CharData value that the public API returns.
    // It is not part of the terminal cell array.
    private var graphemeScalarValues: [UInt32]?
    
    ///Contains the number of columns used by the `Character` stored in this `CharData` on the screen.
    public private(set) var width: Int8
    
    // This contains an assigned key
    var payload: TinyAtom
    
    // Kept in the byte that previously existed only for alignment, so OSC 133
    // semantic metadata does not increase the size of a terminal cell.
    private var semanticContentCode: UInt8

    // The packed width state distinguishes a normal tail from a spacer at a
    // soft-wrap boundary. Existing API users continue to use `width`.
    private var widthStateCode: UInt8

    /// True when selective erase must preserve this cell.
    public private(set) var isProtected: Bool

    // The single source of truth for the cell-storage encoding of a
    // SemanticContent. Both directions switch exhaustively over this enum, so
    // a new SemanticContent (or SemanticPromptKind) case fails to compile
    // until it is mapped in both — it can never silently decode to `.none`.
    private enum SemanticContentCode: UInt8 {
        case none = 0
        case promptInitial = 1
        case promptRight = 2
        case promptContinuation = 3
        case promptSecondary = 4
        case input = 5
        case output = 6

        var content: SemanticContent {
            switch self {
            case .none: return .none
            case .promptInitial: return .prompt(.initial)
            case .promptRight: return .prompt(.right)
            case .promptContinuation: return .prompt(.continuation)
            case .promptSecondary: return .prompt(.secondary)
            case .input: return .input
            case .output: return .output
            }
        }

        init(_ content: SemanticContent) {
            switch content {
            case .none: self = .none
            case .prompt(.initial): self = .promptInitial
            case .prompt(.right): self = .promptRight
            case .prompt(.continuation): self = .promptContinuation
            case .prompt(.secondary): self = .promptSecondary
            case .input: self = .input
            case .output: self = .output
            }
        }
    }

    /// The OSC 133 role assigned to this cell, if any.
    public var semanticContent: SemanticContent {
        // An out-of-range byte can only come from corrupt storage; decode it
        // as `.none` rather than trapping.
        (SemanticContentCode(rawValue: semanticContentCode) ?? .none).content
    }
    
    /// The color and character attributes for the cell
    public var attribute: Attribute
    
    /// Initializes a new instance of the CharData structure with the provided attribute and code.
    /// Use `Terminal.makeCharData` for Character-based construction.
    /// - Parameter attribute: an attribute containing the color and style attributes for the cell
    /// - Parameter code: the character code that will be stored in this cell
    /// - Parameter size: the number of columns used by the `Character` stored in this `CharData` on the screen.
    init (attribute: Attribute, code: Int32, size: Int8 = 1)
    {
        self.attribute = attribute
        self.code = code
        graphemeScalarValues = nil
        width = size
        payload = TinyAtom.empty
        semanticContentCode = 0
        widthStateCode = CharData.widthStateCode(for: size)
        isProtected = false
    }
    
    init (attribute: Attribute, scalar: UnicodeScalar, size: Int8 = 1) {
        self.init(attribute: attribute, code: Int32(scalar.value), size: size)
    }

    // Empty cell sets the code to zero
    init (attribute: Attribute)
    {
        self.init(attribute: attribute, code: 0, size: 1)
    }
    
    public var isSimpleRune: Bool {
        get {
            return graphemeScalarValues == nil
        }
    }

    private static func widthStateCode(for width: Int8) -> UInt8 {
        switch width {
        case 0: return 2
        case 2: return 1
        default: return 0
        }
    }

    var packedWidthStateCode: UInt8 {
        widthStateCode
    }

    /// The uncommon multi-scalar value used when this public value crosses the
    /// packed-storage boundary. Simple scalar cells do not allocate an array.
    var packedGraphemeScalars: [UInt32]? {
        graphemeScalarValues
    }

    init(attribute: Attribute, code: Int32, graphemeScalarValues: [UInt32]?, size: Int8,
         widthStateCode: UInt8, payloadCode: UInt16,
         semanticContent: SemanticContent, isProtected: Bool)
    {
        self.attribute = attribute
        self.code = code
        self.graphemeScalarValues = graphemeScalarValues
        width = size
        payload = TinyAtom.stored(code: payloadCode)
        semanticContentCode = SemanticContentCode(semanticContent).rawValue
        self.widthStateCode = widthStateCode
        self.isProtected = isProtected
    }

    /// Sets the Url token for the this CharData.
    mutating public func setPayload (atom: TinyAtom)
    {
        self.payload = atom
    }

    mutating func setSemanticContent(_ content: SemanticContent) {
        semanticContentCode = SemanticContentCode(content).rawValue
    }

    /// Sets whether selective erase must preserve this cell.
    mutating public func setProtected(_ value: Bool) {
        isProtected = value
    }
    
    public func getPayload () -> (any Sendable)?
    {
         payload.target
    }
    
    public var hasPayload: Bool {
        get {
            return payload.code != 0
        }
    }
    
    /// The `Null` character can be used when filling up parts of the screeb
    public static let Null : CharData = CharData (attribute: defaultAttr)
    
    /// Updates the contents of this CharData with a new code.
    /// - Parameter code: the new character code that will be stored
    /// - Paramerter size: the number of fixed sized columns this character will take on the screen
    public mutating func setValue (code: Int32, size: Int32)
    {
        self.code = code
        graphemeScalarValues = nil
        width = Int8 (size)
        widthStateCode = CharData.widthStateCode(for: width)
    }

    mutating func setCharacter(_ character: Character, size: Int32)
    {
        let values = character.unicodeScalars.map(\.value)
        code = Int32(values.first ?? 0)
        graphemeScalarValues = values.count > 1 ? values : nil
        width = Int8(size)
        widthStateCode = CharData.widthStateCode(for: width)
    }
    
    /// Returns the character that this API value contains.
    public func getCharacter () -> Character
    {
        if let values = graphemeScalarValues {
            var text = ""
            for value in values {
                guard let scalar = Unicode.Scalar(value) else {
                    return " "
                }
                text.unicodeScalars.append(scalar)
            }
            return text.first ?? " "
        }
        if code >= 0, let scalar = Unicode.Scalar(UInt32(code)) {
            return Character(scalar)
        } else {
            return " "
        }
    }
}

#if !(os(iOS) || os(visionOS) || os(macOS) || os(visionOS))
public class TTImage {
    
}
#endif

/// Represents an image that can be attached to a
public class ImageCell {
    let image: TTImage
    
    // cell size
    var width: Int?
    var height: Int?
    
    public init(_ image: TTImage) {
        self.image = image
    }
}
