//
//  File.swift
//  
//
//  Created by Anders Borum on 28/04/2020.
//

import Core
import CoreGraphics

class SixelDcsHandler : DcsHandler {
    var data: [UInt8]
    var terminal: Terminal

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
        
    func unhook () {
        // palette is sparse where we use default color values for unspecified entries
        var palette = [Int: TTColor]()

        // skip to # to read palette
        var p = 0
        skipToCharacter(&p, "#")
        while p + 1 < data.count && data[p] == Character("#").asciiValue {
            p += 1 // jump past #
            let color = nextIntArray(&p)
            if color.count >= 5 && color[1] == 1 {
                let index = color[0]
                let hue = CGFloat(color[2]) // angle in the range 0 to 360 degrees
                let lightness = 0.01 * CGFloat(color[3]) // percentage from 0 to 100
                let saturation = 0.01 * CGFloat(color[4]) // percentage from 0 to 100
                
                // it isn't entirely clear if lightness == brightness and this page might help:
                //   https://en.wikipedia.org/wiki/HSL_and_HSV
                palette[index] = TTColor.make(hue: hue, saturation: saturation,
                                              brightness: lightness, alpha: 1)
            }
            
            if color.count >= 5 && color[1] == 2 {
                let index = color[0]
                let red = 0.01 * CGFloat(color[2]) // percentage from 0 to 100
                let green = 0.01 * CGFloat(color[3]) // percentage from 0 to 100
                let blue = 0.01 * CGFloat(color[4]) // percentage from 0 to 100

                palette[index] = TTColor.make(red: red, green: green,
                                              blue: blue, alpha: 1)
            }
        }
        
        // read lines building up bitmap
        var bitmap = [[Int]]()
        var y = 0
        var x = 0
        func write(color: Int, sixel: Int) {
            for k in 0..<6 {
                let on = (sixel & (1 << k)) != 0
                if on {
                    // make sure we have lines enough
                    while y + k >= bitmap.count {
                        bitmap.append([Int]())
                    }
                    
                    // make sure we have room for this sixel
                    while x >= bitmap[y+k].count {
                        bitmap[y+k].append(0)
                    }

                    bitmap[y+k][x] = color
                }
            }
            
            x += 1
        }
        
        while p < data.count {
            // read the color entry to use
            skipToCharacter(&p, "#")
            p += 1 // skip past #
            guard let color = nextInt(&p) else {
                // aborting as we failed to read the color
                break
            }
            
            // everything inside loop is for this color
            var reps = 1
            while p < data.count && data[p] != Character("#").asciiValue {
                let c = data[p]
                p += 1
                
                switch c {
                    
                case 33: // ! repeats the next sixel a number of times
                    guard let value = nextInt(&p) else {
                        // ignore repeat
                        continue
                    }
                    reps = value

                case 36: // "$"  (dollar  sign)  character  moves  the  sixel  "cursor"  to the
                         // "beginning of  the current  (same) line
                    x = 0
                    
                case 45: // (hyphen or  minus sign)  character moves the sixel "cursor" to
                         // the "beginning of the next line
                    y += 6
                    x = 0
                    
                case 63...126:
                    for _ in 0..<reps {
                        write(color: color, sixel: Int(c) - 63)
                    }
                    
                    // back to not repeating
                    reps = 1
                    
                default:
                    ()
                }
            }

        }
        
        // convert bitmap into image
        if let image = buildImage(palette: palette, bitmap: bitmap) {
            let todo = "deliver to terminal"
        }
        
        
        data.append(0)
        data.withUnsafeBytes { ptr in
         let unsafeBound = ptr.bindMemory(to: UInt8.self)
         let unsafePointer = unsafeBound.baseAddress!
        
            let s = String (cString: unsafePointer)
            NSLog("Sixel: \(s)")
        }
    }
    
    private func buildImage(palette: [Int: TTColor], bitmap: [[Int]]) -> TTImage? {
        // determine size of image
        let height = bitmap.count
        var width = 0
        for y in 0 ..< height {
            let w = bitmap[y].count
            if w > width {
                width = w
            }
        }
        
        guard width * height > 0 else {
            return nil
        }
        
        // build 24-bit representation
        var truecolor = [UInt8](repeating: 0, count: 3 * width * height)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        for y in 0 ..< height {
            let line = bitmap[y]
            for x in 0 ..< width {
                guard x < line.count,
                      let color = palette[line[x]] else {
                
                    // no color to write
                    continue
                }

                color.getRed(&red, green: &green, blue: &blue, alpha: nil)
                
                let offset = 3 * (width * y + x)
                truecolor[offset + 0] = UInt8(255.0 * red);
                truecolor[offset + 1] = UInt8(255.0 * green);
                truecolor[offset + 2] = UInt8(255.0 * blue);
            }
        }
        
        // create image from RGB representation
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        let data = NSData(bytes: &truecolor, length: truecolor.count)
        let providerRef: CGDataProvider? = CGDataProvider(data: data)
        let cgimage: CGImage? = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                        bytesPerRow: width * 3, space: rgbColorSpace, bitmapInfo: bitmapInfo,
                                        provider: providerRef!, decode: nil, shouldInterpolate: true,
                                        intent: .defaultIntent)
        return TTImage(cgImage: cgimage!)
    }
}
