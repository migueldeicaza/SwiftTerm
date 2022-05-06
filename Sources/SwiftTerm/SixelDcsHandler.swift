//
//  SixelDcsHandler.swift
//
//  Created by Anders Borum on 28/04/2020.
//

import Foundation

// DCS handler for sixel sequences, collects the image and
// then calls into the front-end to attach the parsed image
// into its internal representation to display the image.
class SixelDcsHandler : DcsHandler {
    var data: [UInt8]
    unowned var terminal: Terminal

    public init (terminal: Terminal)
    {
        self.terminal = terminal
        data = []
    }
    
    func hook (collect: cstring, parameters: [Int],  flag: UInt8)
    {
        data = []
    }
    
    func put (data : ArraySlice<UInt8>) {
        for x in data {
            self.data.append(x)
        }
    }
    
    private func nextInt(_ p: inout Int) -> Int? {
        var result: Int?
        while p < data.count {
            let c = data[p]
            guard c >= 48 && c <= 57 else {
                return result
            }
            
            let digit = Int(c) - 48
            if let existing = result {
                result = 10 * existing + digit
            } else {
                result = digit
            }
            
            p += 1
        }
        return nil
    }
    
    private func nextIntArray(_ p: inout Int) -> [Int] {
        var result = [Int]()
        while p < data.count {
            // jump past semicolon delimiting integers
            if data[p] == Character(";").asciiValue && p + 1 < data.count {
                p += 1
            }
            
            guard let next = nextInt(&p) else {
                break
            }
            
            result.append(next)
        }
        return result
    }
    
    private func skipToCharacter(_ p: inout Int, _ char: Character) {
        let value = char.asciiValue
        while p < data.count {
            if data[p] == value {
                return
            }
            p += 1
        }
    }
        
    let poundChar: UInt8 = 0x23 /* # */
    
    func unhook () {
        var p = 0
        palette = [Int: UInt32]()
        x = 0
        y = 0
        maxX = 0
        maxY = 0
        
        // First iteration, scan the image to compute the size
        skipToCharacter(&p, "#")
        let skipped = p
        var colorindex = 15
        
        while p + 1 < data.count {
            if data[p] == poundChar {
                p += 1 // jump past #
                
                // switch color and maybe update palette
                let color = nextIntArray(&p)
                guard let _ = color.first else {
                    // no more image data
                    break
                }
                continue
            }
            let oldP = p
            sizePixels(&p, colorindex)
            // stop if there is no advancement
            if p <= oldP {
                break
            }
        }
        
        // Allocate the buffer, and parse again, this time
        // plotting the data into the pixels buffer
        pixels = Array.init(repeating: 0, count: maxX*maxY*4)
        p = skipped
        x = 0
        y = 0
        while p + 1 < data.count {
            if data[p] == poundChar {
                p += 1 // jump past #
                
                // switch color and maybe update palette
                let color = nextIntArray(&p)
                guard let index = color.first else {
                    // no more image data
                    break
                }
                
                // more than one color value means we define the palette entry
                if color.count >= 2 {
                    updatePaletteEntry(color)
                }
                
                colorindex = index
                continue
            }
            
            // read pixel data for color at index
            let oldP = p
            readPixels(&p, colorindex)
            
            // stop if there is no advancement
            if p <= oldP {
                break
            }
        }

        terminal.tdel?.createImageFromBitmap(source: terminal, bytes: &pixels, width: maxX, height: maxY)
    }
    
    var palette = [Int: UInt32]()
    var pixels = [UInt8]()
    var x = 0
    var y = 0
    var maxX = 0
    var maxY = 0
    
    func pctToByte (_ pct: Int) -> Int {
        let pct = max (0, min (pct, 100))
        return (pct &* 255) / 100;
    }

    private func updatePaletteEntry(_ color: [Int]) {
        // converts an input percentage 0..100 into a 0..255 value suitable to encode in RGB

        if color.count >= 5 && color[1] == 1 {
            let index = color[0]
            let hue = max (0, min (color[2], 360))
            let lum = max (0, min (color[3], 100))
            let sat = max (0, min (color[4], 100))
            palette [index] = UInt32 ((hls_to_rgb (hue: hue, lum: lum, sat: sat) & 0xffffff) << 8) | 0xff
            return
        }
        
        if color.count >= 5 && color[1] == 2 {
            let index = color[0]
            let color: UInt32 = UInt32 ((pctToByte (color[2]) << 24) | (pctToByte(color [3]) << 16) | (pctToByte(color [4]) << 8) | 0xff)
            palette[index] = color
        }
    }

    // read lines building up bitmap[y][x] with index into
    // or -1 to mean transparent
    private func sizePixels(_ p: inout Int, _ color: Int) {
        func write(sixel: Int) {
            if (sixel & 32) != 0 {
                maxY = max (y&+6, maxY)
            }
            if (sixel & 16) != 0 {
                maxY = max (y&+5, maxY)
            }
            if (sixel & 8) != 0 {
                maxY = max (y&+4, maxY)
            }
            if (sixel & 4) != 0 {
                maxY = max (y&+3, maxY)
            }
            if (sixel & 2) != 0 {
                maxY = max (y&+2, maxY)
            }
            if (sixel & 1) != 0 {
                maxY = max (y&+1, maxY)
            }
            x = x &+ 1
        }

        var reps = 1
        while p < data.count && data[p] != poundChar {
            let c = data[p]
            p = p &+ 1
            
            switch c {
                
            case 33: // ! repeats the next sixel a number of times
                guard let value = nextInt(&p) else {
                    // ignore repeat
                    continue
                }
                reps = value

            // "$"  (dollar sign) character moves the sixel "cursor" to the "beginning of the current (same) line
            case 36:
                maxX = max (maxX, x)
                x = 0
                
            // (hyphen or minus sign) character moves the sixel "cursor" to the "beginning of the next line
            case 45:
                y = y &+ 6
                maxX = max (maxX, x)
                x = 0
                
            case 63...126:
                for _ in 0..<reps {
                    write(sixel: Int(c) - 63)
                }
                // back to not repeating
                reps = 1
                
            case 10, 13:
                break // ignore newline
                
            default:
                break
            }
        }
    }

    // read lines building up bitmap[y][x] with index into
    // or -1 to mean transparent
    private func readPixels(_ p: inout Int, _ color: Int) {
        // determine color to write
        let transparent: UInt32 = 0
        let rgba: UInt32
        if let known = palette[color] {
            rgba = known
        } else if color < terminal.defaultAnsiColors.count {
            let standard = terminal.defaultAnsiColors[color]
            rgba = UInt32 ((standard.red >> 8) << 24) |
                UInt32 ((standard.green >> 8) << 16) |
                UInt32 ((standard.blue >> 8) << 8) |
                UInt32 (0xff)
        } else {
            rgba = transparent
        }
        
        func write(sixel: Int) {
            var k = 0
            while k < 6 {
                let on = (sixel & (1 << k)) != 0
                if on {
                    let s = ((y &+ k)*maxX &+ x) * 4
                    pixels[s]   = UInt8 (rgba >> 24)
                    pixels[s &+ 1] = UInt8 ((rgba >> 16) & 0xff)
                    pixels[s &+ 2] = UInt8 ((rgba >> 8) & 0xff)
                    pixels[s &+ 3] = UInt8 ((rgba) & 0xff)
                }
                k = k &+ 1
            }
            
            x = x &+ 1
        }
    
        var reps = 1
        while p < data.count && data[p] != poundChar {
            let c = data[p]
            p += 1
            
            switch c {
            case 33: // ! repeats the next sixel a number of times
                guard let value = nextInt(&p) else {
                    // ignore repeat
                    continue
                }
                reps = value

            // "$"  (dollar sign) character moves the sixel "cursor" to the "beginning of the current (same) line
            case 36:
                x = 0
                
            // (hyphen or minus sign) character moves the sixel "cursor" to the "beginning of the next line
            case 45:
                y += 6
                x = 0
                
            case 63...126:
                for _ in 0..<reps {
                    write(sixel: Int(c) - 63)
                }
                // back to not repeating
                reps = 1
                
            case 10, 13:
                break // ignore new line
                
            default:
                break
            }
        }
    }
    
    // The following code is ported from libsixel:
    func sixelRgb (red: Int, green: Int, blue: Int) -> Int {
        (((red) << 16) + ((green) << 8) +  (blue))
    }

    func sixelXrgb (red: Int, green: Int, blue: Int) -> Int {
        return sixelRgb(red: pctToByte (red), green: pctToByte (green), blue: pctToByte (blue))
    }

    /*
     * Primary color hues:
     *  blue:    0 degrees
     *  red:   120 degrees
     *  green: 240 degrees
     */
    func hls_to_rgb(hue: Int, lum: Int, sat: Int) -> UInt32
    {
        var min, max: Double
        var dr, dg, db: Double

        let dlum = Double(lum)
        if sat == 0 {
            let lshort = UInt32 (pctToByte(lum))
            return (lshort << 16) | (lshort << 8) | (lshort)
        }

        let dsat = Double(sat)

        let c2 = abs ((2.0 * dlum/100.0) - 1.0)
        /* https://wikimedia.org/api/rest_v1/media/math/render/svg/17e876f7e3260ea7fed73f69e19c71eb715dd09d */
        max = dlum + dsat * (1.0 - c2) / 2.0

        /* https://wikimedia.org/api/rest_v1/media/math/render/svg/f6721b57985ad83db3d5b800dc38c9980eedde1d */
        min = dlum - dsat * (1.0 - c2) / 2.0
        
        /* sixel hue color ring is roteted -120 degree from nowdays general one. */
        let nhue = (hue + 240) % 360;
        let dhue = Double(nhue)


        /* https://wikimedia.org/api/rest_v1/media/math/render/svg/937e8abdab308a22ff99de24d645ec9e70f1e384 */
        switch (nhue / 60) {
        case 0:  /* 0 <= hue < 60 */
            dr = max
            dg = (min + (max - min) * (dhue / 60.0))
            db = min

        case 1:  /* 60 <= hue < 120 */
            dr = min + (max - min) * ((120 - dhue) / 60.0)
            dg = max
            db = min

        case 2:  /* 120 <= hue < 180 */
            dr = min
            dg = max
            db = (min + (max - min) * ((dhue - 120.0) / 60.0))

        case 3:  /* 180 <= hue < 240 */
            dr = min
            dg = (min + (max - min) * ((240.0 - dhue) / 60.0))
            db = max

        case 4:  /* 240 <= hue < 300 */
            dr = (min + (max - min) * ((dhue - 240.0) / 60.0))
            dg = min
            db = max

        case 5:  /* 300 <= hue < 360 */
            dr = max
            dg = min
            db = (min + (max - min) * ((360.0 - dhue) / 60.0))

        default:
            dr = 0
            dg = 0
            db = 0
        }
        return UInt32 (sixelXrgb(red: Int (dr), green: Int (dg), blue: Int (db)))
    }
}
