//
//  Colors.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/1/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

class Color {
    public var red, green, blue: UInt8
    static var defaultAnsiColors: [Color] = setupDefaultAnsiColors (initialColors: miguelColors)
    static var defaultForeground = Color (red: 0xff, green: 0xff, blue: 0xff)
    static var defaultBackground = Color (red: 0, green: 0, blue: 0)
    
    static let paleColors: [Color] = [
        // dark colors
        Color (red: 0x2e, green: 0x34, blue: 0x36),
        Color (red: 0xcc, green: 0x00, blue: 0x00),
        Color (red: 0x4e, green: 0x9a, blue: 0x06),
        Color (red: 0xc4, green: 0xa0, blue: 0x00),
        Color (red: 0x34, green: 0x65, blue: 0xa4),
        Color (red: 0x75, green: 0x50, blue: 0x7b),
        Color (red: 0x06, green: 0x98, blue: 0x9a),
        Color (red: 0xd3, green: 0xd7, blue: 0xcf),
        
        // bright colors
        Color (red: 0x55, green: 0x57, blue: 0x53),
        Color (red: 0xef, green: 0x29, blue: 0x29),
        Color (red: 0x8a, green: 0xe2, blue: 0x34),
        Color (red: 0xfc, green: 0xe9, blue: 0x4f),
        Color (red: 0x72, green: 0x9f, blue: 0xcf),
        Color (red: 0xad, green: 0x7f, blue: 0xa8),
        Color (red: 0x34, green: 0xe2, blue: 0xe2),
        Color (red: 0xee, green: 0xee, blue: 0xec)
    ]
    
    static let vgaColors: [Color] = [
        // dark colors
        Color (red: 0, green: 0, blue: 0),
        Color (red: 170, green: 0, blue: 0),
        Color (red: 0, green: 170, blue: 0),
        Color (red: 170, green: 85, blue: 0),
        Color (red: 0, green: 0, blue: 170),
        Color (red: 170, green: 0, blue: 170),
        Color (red: 0, green: 170, blue: 170),
        Color (red: 170, green: 170, blue: 170),
        Color (red: 85, green: 85, blue: 85),
        Color (red: 255, green: 85, blue: 85),
        Color (red: 85, green: 255, blue: 85),
        Color (red: 255, green: 255, blue: 85),
        Color (red: 85, green: 85, blue: 255),
        Color (red: 255, green: 85, blue: 255),
        Color (red: 85, green: 255, blue: 255),
        Color (red: 255, green: 255, blue: 255),
    ]
    
    static let terminalAppColors: [Color] = [
        Color (red: 0, green: 0, blue: 0),
        Color (red: 194, green: 54, blue: 33),
        Color (red: 37, green: 188, blue: 36),
        Color (red: 173, green: 173, blue: 39),
        Color (red: 73, green: 46, blue: 225),
        Color (red: 211, green: 56, blue: 211),
        Color (red: 51, green: 187, blue: 200),
        Color (red: 203, green: 204, blue: 205),
        Color (red: 129, green: 131, blue: 131),
        Color (red: 252, green: 57, blue: 31),
        Color (red: 49, green: 231, blue: 34),
        Color (red: 234, green: 236, blue: 35),
        Color (red: 88, green: 51, blue: 255),
        Color (red: 249, green: 53, blue: 248),
        Color (red: 20, green: 240, blue: 240),
        Color (red: 233, green: 235, blue: 235),
    ]
    
    
    static let xtermColors: [Color] = [
        Color (red: 0, green: 0, blue: 0),
        Color (red: 205, green: 0, blue: 0),
        Color (red: 0, green: 205, blue: 0),
        Color (red: 205, green: 205, blue: 0),
        Color (red: 0, green: 0, blue: 238),
        Color (red: 205, green: 0, blue: 205),
        Color (red: 0, green: 205, blue: 205),
        Color (red: 229, green: 229, blue: 229),
        Color (red: 127, green: 127, blue: 127),
        Color (red: 255, green: 0, blue: 0),
        Color (red: 0, green: 255, blue: 0),
        Color (red: 255, green: 255, blue: 0),
        Color (red: 92, green: 92, blue: 255),
        Color (red: 255, green: 0, blue: 255),
        Color (red: 0, green: 255, blue: 255),
        Color (red: 255, green: 255, blue: 255),
    ]
    
    static let miguelColors: [Color] = [
        Color (red: 0, green: 0, blue: 0),
        Color (red: 153, green: 0, blue: 1),
        Color (red: 0, green: 166, blue: 3),
        Color (red: 153, green: 153, blue: 0),
        Color (red: 3, green: 0, blue: 178),
        Color (red: 178, green: 0, blue: 178),
        Color (red: 0, green: 165, blue: 178),
        Color (red: 191, green: 191, blue: 191),
        Color (red: 138, green: 137, blue: 138),
        Color (red: 229, green: 0, blue: 1),
        Color (red: 0, green: 216, blue: 0),
        Color (red: 229, green: 229, blue: 0),
        Color (red: 7, green: 0, blue: 254),
        Color (red: 229, green: 0, blue: 229),
        Color (red: 0, green: 229, blue: 229),
        Color (red: 229, green: 229, blue: 229),
    ]
    
    static func setupDefaultAnsiColors (initialColors: [Color]) -> [Color]
    {
        var colors = initialColors
        
        // Fill in the remaining 240 ANSI colors.
        let v = [ 0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff ];
        
        // Generate colors (16-231)
        for i in 0..<216 {
            let r = UInt8 (v [(i / 36) % 6])
            let g = UInt8 (v [(i / 6) % 6])
            let b = UInt8 (v [i % 6])

            colors.append(Color (red: r, green: g, blue: b))
        }

        // Generate greys (232-255)
        for i in 0..<24 {
            let c = UInt8 (8 + i * 10)
            colors.append (Color (red: c, green: c, blue: c))
        }
        return colors
    }
    
    public init(red: UInt8, green: UInt8, blue: UInt8)
    {
        self.red = red
        self.green = green
        self.blue = blue
    }
}
