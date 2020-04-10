//
//  Colors.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/1/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

public class Color {
    public var red, green, blue: UInt8
    static var defaultAnsiColors: [Color] = setupDefaultAnsiColors ()
    static var defaultForeground = Color (red: 0xff, green: 0xff, blue: 0xff)
    static var defaultBackground = Color (red: 0, green: 0, blue: 0)
    
    static func setupDefaultAnsiColors () -> [Color]
    {
        var colors: [Color] = [
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
