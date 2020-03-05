//
//  CharData.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

/**
 * Stores a cell with both the character being displayed as well as the color attribute.
 * This uses an Int32 to store the value, if the value can not be encoded as a single Unicode.Scalar,
 * then an index is stored that is looked up in parallel, so that full grapheme clusters can be tracked.
 */
struct CharData {
    let maxRune = 1 << 22
    
    // Contains the character to index mapping
    static var charToIndexMap: [Character:Int32] = [:]
    
    // Contains the index to character mapping, could be a plain array
    static var indexToCharMap: [Int32: Character] = [:]
    static var lastCharIndex: Int32 = 1 << 22
    
    // flags << 18, fg << 9 | bg
    public var attribute: Int32
    
    // Contains a rune, or a pointer into a Grapheme Cluster
    var code: Int32
    public var width: Int8
    
    public static let defaultColor: Int32 = 256
    public static let invertedDefaultColor: Int32 = 257
    
    public static let defaultAttr: Int32 = defaultColor << 9
    public static let invertedAttr: Int32 = invertedDefaultColor << 9 | invertedDefaultColor
    
    public init (attribute: Int32, char: Character, size: Int8 = 1)
    {
        self.attribute = attribute
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
    
    public init (attribute: Int32)
    {
        self.init (attribute: attribute, char: "\u{0200}")
    }
    
    public var SimpleRune: Bool {
        get {
            return code < maxRune
        }
    }
    
    public static var Null : CharData = CharData (attribute: defaultAttr, char: "\u{0200}")
    
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
    
    public func getCharacter () -> Character
    {
        if code > maxRune {
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
