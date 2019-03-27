//
//  CharData.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/19/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation

struct CharData {
    let maxRune = 1 << 22;
    static var characters : [Character:Int32] = [:]
    static var lastCharIndex : Int32 = 1 << 22
    
    // flags << 18, fg << 9 | bg
    var Attribute : Int32
    
    // Contains a rune, or a pointer into a Grapheme Cluster
    var Code : Int32
    
    var Width : Int32
    
    static let defaultColor : Int32 = 256
    static let invertedDefaultColor : Int32 = 257
    
    static let defaultAttr : Int32 = defaultColor << 9
    static let invertedAttr : Int32 = invertedDefaultColor << 9 | invertedDefaultColor
    
    init (attribute : Int32, char : Character, size : Int = 1)
    {
        Attribute = attribute
        if let existingIdx = CharData.characters [char] {
            Code = existingIdx
        } else {
            CharData.characters [char] = CharData.lastCharIndex
            Code = CharData.lastCharIndex
            CharData.lastCharIndex = CharData.lastCharIndex + 1
        }
        Width = Int32 (size)
    }
    
    public var SimpleRune : Bool {
        get {
            return Code < maxRune
        }
    }
    
    static var Null : CharData = CharData (attribute: defaultAttr, char: "\u{0200}")
}
