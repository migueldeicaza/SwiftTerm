//
//  CharData.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

// TODO:
//   * CharData.defaultColor should go when we are ready to move to Attribute
//   * CharData.invertedDefaultColor should go when we are ready to move to Attribute
import Foundation

struct CharacterAttribute : OptionSet {
    let rawValue: UInt8
    
    /**
     * Constructs a character attribute from a raw value.
     */
    init (rawValue: UInt8)
    {
        self.rawValue = rawValue
    }
    
    /**
     * Constructs the CharacterAttribute from a CharData.attribute that encodes the foreground, background and flags
     */
    public init (attribute: Int32)
    {
        rawValue = UInt8 ((attribute >> 18) & 0xff)
    }
    static let none = CharacterAttribute ([])
    static let bold = CharacterAttribute (rawValue: 1)
    static let underline = CharacterAttribute (rawValue: 2)
    static let blink = CharacterAttribute (rawValue: 4)
    static let inverse = CharacterAttribute (rawValue: 8)
    static let invisible = CharacterAttribute (rawValue: 16)
    static let dim = CharacterAttribute (rawValue: 32)
    static let italic = CharacterAttribute (rawValue: 64)
    static let crossedOut = CharacterAttribute (rawValue: 128)
}

///
/// Attribute contains the foreground and background color cells, as well as the
/// character attributes (bold, underline, inverse) that the character should be drawn as
///
public struct Attribute {
    /// Determines how the foreground and background color shoudl be interpreted
    enum ColorKind {
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
    }
    
    var color: ColorKind
    // The cell attributes
    var attribute: CharacterAttribute
        
    // Temporary, longer term in Attribute we will add a proper encoding
    static func toSgr (_ attribute: Int32) -> String
    {
        var result = "0"
        let ca = CharacterAttribute (attribute: attribute)
        if ca.contains(.bold) {
            result += ";1"
        }
        if ca.contains (.underline) {
            result += ";4"
        }
        if ca.contains (.blink) {
            result += ";5"
        }
        if ca.contains (.inverse) {
            result += ";7"
        }
        if ca.contains (.invisible) {
            result += ";8"
        }
        
        let fg = (attribute >> 9) & 0x1ff
        
        if fg != CharData.defaultColor {
            if fg > 16 {
                result += ";38;5;\(fg)"
            } else {
                result += ";\(fg >= 8 ? 9 : 3)\(fg >= 8 ? fg - 8 : fg);"
            }
        }
        
        let bg = attribute & 0x1ff
        if bg != CharData.defaultColor {
            if bg > 16 {
                result += ";48;5;\(bg)"
            } else {
                result += ";\(bg >= 8 ? 10 : 4)\(bg >= 8 ? bg - 8 : bg);"
            }
        }
        result += "m"
        return result
    }
}

/**
 * Stores a cell with both the character being displayed as well as the color attribute.
 * This uses an Int32 to store the value, if the value can not be encoded as a single Unicode.Scalar,
 * then an index is stored that is looked up in parallel, so that full grapheme clusters can be tracked.
 */
public struct CharData {
    static let maxRune = 1 << 22
    
    // Contains the character to index mapping
    static var charToIndexMap: [Character:Int32] = [:]
    
    // Contains the index to character mapping, could be a plain array
    static var indexToCharMap: [Int32: Character] = [:]
    static var lastCharIndex: Int32 = (1 << 22)+1

    public static let defaultColor: Int32 = 256
    public static let invertedDefaultColor: Int32 = 257
    
    public static let defaultAttr: Int32 = (defaultColor << 9) | (defaultColor << 0)
    public static let invertedAttr: Int32 = invertedDefaultColor << 9 | invertedDefaultColor
    

    // flags << 18, fg << 9 | bg
    public var attribute: Int32
    
    // Contains a rune, or a pointer into a Grapheme Cluster
    var code: Int32
    public var width: Int8
    
    public var attr: Attribute
    
    public init (attribute: Attribute, char: Character, size: Int8 = 1)
    {
        self.attr = attribute
        self.attribute = 0
        if char.utf16.count == 1 {
            code = Int32 (char.utf16.first!)
        } else {
            if let existingIdx = CharData.charToIndexMap [char] {
                code = existingIdx
            } else {
                CharData.charToIndexMap [char] = CharData.lastCharIndex
                CharData.indexToCharMap [CharData.lastCharIndex] = char
                code = CharData.lastCharIndex
                CharData.lastCharIndex = CharData.lastCharIndex + 1
            }
        }
        width = Int8 (size)
    }
    
    public init (attribute: Int32, char: Character, size: Int8 = 1)
    {
        self.attribute = attribute
        self.attr = Attribute(color: .defaultColor, attribute: .none)
        if char.utf16.count == 1 {
            code = Int32 (char.utf16.first!)
        } else {
            if let existingIdx = CharData.charToIndexMap [char] {
                code = existingIdx
            } else {
                CharData.charToIndexMap [char] = CharData.lastCharIndex
                CharData.indexToCharMap [CharData.lastCharIndex] = char
                code = CharData.lastCharIndex
                CharData.lastCharIndex = CharData.lastCharIndex + 1
            }
        }
        width = Int8 (size)
    }

    // Empty cell sets the code to zero
    init (attribute: Int32)
    {
        self.attribute = attribute
        self.attr = Attribute(color: .defaultColor, attribute: .none)
        code = 0
        width = 1
    }
    
    public var isSimpleRune: Bool {
        get {
            return code < CharData.maxRune
        }
    }

    /// The `Null` character can be used when filling up parts of the screeb
    public static var Null : CharData = CharData (attribute: defaultAttr)
    
    /// Updates the contents of this CharData with a new character.
    /// - Parameter char: the new character that will be stored
    /// - Paramerter size: the number of fixed sized columns this character will take on the screen
    mutating public func setValue (char: Character, size: Int32)
    {
        if char.utf16.count == 1 {
            self.code = Int32 (char.utf16.first!)
        } else {
            if let existingIdx = CharData.charToIndexMap [char] {
                code = existingIdx
            } else {
                CharData.charToIndexMap [char] = CharData.lastCharIndex
                CharData.indexToCharMap [CharData.lastCharIndex] = char
                code = CharData.lastCharIndex
                CharData.lastCharIndex = CharData.lastCharIndex + 1
            }
        }
        width = Int8 (size)
    }
    
    /// Use this method to retrieve the Character stored in the CharData
    public func getCharacter () -> Character
    {
        if code > CharData.maxRune {
            // This is an invariant - no code can be stored without the equivalent being tracked, but for the sake
            // of not having a "!" return a space.
            return CharData.indexToCharMap [code] ?? " "
        }
        if let c = Unicode.Scalar (UInt32 (code)) {
            return Character(c)
        } else {
            return " "
        }
    }
}
