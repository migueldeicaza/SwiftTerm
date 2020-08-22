//
//  SixelDcsHandler.swift
//  
//
//  Created by Anders Borum on 28/04/2020.
//

import Foundation
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
        var p = 0
        palette = [Int: RGBA]()
        pixels = [[RGBA]]()
        x = 0
        y = 0
        
        // read palette updates and pixel data
        skipToCharacter(&p, "#")
        var colorindex = 15
        while p + 1 < data.count {
            if data[p] == Character("#").asciiValue {
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

        // convert bitmap into image for terminal
        if let cgImage = buildImage() {
#if os(iOS)
            let image = UIImage(cgImage: cgImage)
#else
            let image = NSImage(cgImage: cgImage)
#endif
            let cell = ImageCell(image)            
            terminal.image(cell)
        }
    }
    
    private typealias RGBA = (Int, Int, Int, Int)
    private var palette = [Int: RGBA]()
    private var pixels = [[RGBA]]()
    private var x = 0
    private var y = 0
    
    private func updatePaletteEntry(_ color: [Int]) {
        if color.count >= 5 && color[1] == 1 {
            let index = color[0]
            let hue = CGFloat(color[2]) // angle in the range 0 to 360 degrees
            let lightness = 0.01 * CGFloat(color[3]) // percentage from 0 to 100
            let saturation = 0.01 * CGFloat(color[4]) // percentage from 0 to 100
            
            // it isn't entirely clear if lightness == brightness and this page might help:
            //   https://en.wikipedia.org/wiki/HSL_and_HSV
            //
            // using CoreGraphics to convert between HSL and RGB is perhaps a little
            // wasteful but HSL colors in Sixels seems rarely used
            let color = TTColor.make(hue: hue, saturation: saturation,
                                     brightness: lightness, alpha: 1)
            var red = CGFloat(0)
            var green = CGFloat(0)
            var blue = CGFloat(0)
            color.getRed(&red, green: &green, blue: &blue, alpha: nil)
            
            palette[index] = (Int(65535.0 * red),
                              Int(65535.0 * green),
                              Int(65535.0 * blue), 65535)
        }
        
        if color.count >= 5 && color[1] == 2 {
            let index = color[0]
            let red = 0.01 * CGFloat(color[2]) // percentage from 0 to 100
            let green = 0.01 * CGFloat(color[3]) // percentage from 0 to 100
            let blue = 0.01 * CGFloat(color[4]) // percentage from 0 to 100
            
            palette[index] = (Int(65535.0 * red),
                              Int(65535.0 * green),
                              Int(65535.0 * blue), 65535)
        }
    }
    
    // read lines building up bitmap[y][x] with index into
    // or -1 to mean transparent
    private func readPixels(_ p: inout Int, _ color: Int) {
        // determine color to write
        let transparent = (0,0,0,0)
        let rgba: RGBA
        if let known = palette[color] {
            rgba = known
        } else if color < terminal.defaultAnsiColors.count {
            let standard = terminal.defaultAnsiColors[color]
            rgba = (Int(standard.red), Int(standard.green), Int(standard.blue), 65535)
        } else {
            rgba = transparent
        }
        
        func write(sixel: Int) {
            for k in 0..<6 {
                let on = (sixel & (1 << k)) != 0
                if on {
                    // make sure we have lines enough
                    while y + k >= pixels.count {
                        pixels.append([RGBA]())
                    }
                    
                    // make sure we have room for this sixel
                    while x >= pixels[y+k].count {
                        pixels[y+k].append(transparent)
                    }

                    pixels[y+k][x] = rgba
                }
            }
            
            x += 1
        }
    
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

            case 36: // "$"  (dollar sign) character moves the sixel "cursor" to the
                     // "beginning of the current (same) line
                x = 0
                
            case 45: // (hyphen or minus sign) character moves the sixel "cursor" to
                     // the "beginning of the next line
                y += 6
                x = 0
                
            case 63...126:
                for _ in 0..<reps {
                    write(sixel: Int(c) - 63)
                }
                
                // back to not repeating
                reps = 1
                
            case 10, 13:
                () // ignore newline
                
            default:
#if DEBUG
                print("Not expected")
#endif
                ()
            }
        }
    }
    
    private func buildImage() -> CGImage? {
        // determine size of image
        let height = pixels.count
        var width = 0
        for y in 0 ..< height {
            let w = pixels[y].count
            if w > width {
                width = w
            }
        }
        
        guard width * height > 0 else {
            return nil
        }
        
        // build 8+24-bit representation
        var truecolor = [UInt8](repeating: 0, count: 4 * width * height)
        for y in 0 ..< height {
            let line = pixels[y]
            for x in 0 ..< width {
                let color = x < line.count ? line[x] : (0,0,0,0)

                let offset = 4 * (width * y + x)
                truecolor[offset + 0] = UInt8(255*color.0/65535)
                truecolor[offset + 1] = UInt8(255*color.1/65535)
                truecolor[offset + 2] = UInt8(255*color.2/65535)
                truecolor[offset + 3] = UInt8(255*color.3/65535)
            }
        }
        
        // create image from RGB representation
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let data = NSData(bytes: &truecolor, length: truecolor.count)
        let providerRef: CGDataProvider? = CGDataProvider(data: data)
        let cgimage: CGImage? = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: rgbColorSpace, bitmapInfo: bitmapInfo,
                                        provider: providerRef!, decode: nil, shouldInterpolate: true,
                                        intent: .defaultIntent)
        return cgimage
    }
}
