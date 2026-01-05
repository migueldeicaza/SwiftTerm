//
//  KittyPlaceholder.swift
//  SwiftTerm
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct KittyPlaceholderCell {
    let row: Int
    let col: Int
    let imageId: UInt32
    let placementId: UInt32
    let placeholderRow: Int
    let placeholderCol: Int
    let msb: Int
}

enum KittyPlaceholderDecoder {
    static func decode(character: Character,
                       attribute: Attribute,
                       row: Int,
                       col: Int,
                       previous: KittyPlaceholderCell?,
                       previousAttribute: Attribute?) -> KittyPlaceholderCell? {
        var scalars = character.unicodeScalars
        guard let first = scalars.first, first.value == KittyPlaceholder.baseScalar else {
            return nil
        }

        var diacritics: [Int] = []
        scalars.removeFirst()
        for scalar in scalars {
            if let idx = KittyPlaceholder.diacriticIndex[scalar.value] {
                diacritics.append(idx)
            }
        }

        let explicitRow = diacritics.count > 0 ? diacritics[0] : nil
        let explicitCol = diacritics.count > 1 ? diacritics[1] : nil
        let explicitMsb = diacritics.count > 2 ? diacritics[2] : nil

        let sameFg = previousAttribute?.fg == attribute.fg
        let sameUnderline = previousAttribute?.underlineColor == attribute.underlineColor
        let isAdjacent = previous?.row == row && previous?.col == col - 1

        var placeholderRow: Int?
        var placeholderCol: Int?
        var msb = explicitMsb ?? 0

        switch diacritics.count {
        case 0:
            if let prev = previous, sameFg, sameUnderline, isAdjacent {
                placeholderRow = prev.placeholderRow
                placeholderCol = prev.placeholderCol + 1
                msb = prev.msb
            } else {
                placeholderRow = 0
                placeholderCol = 0
            }
        case 1:
            placeholderRow = explicitRow
            if let prev = previous, sameFg, sameUnderline, isAdjacent, prev.placeholderRow == placeholderRow {
                placeholderCol = prev.placeholderCol + 1
                msb = prev.msb
            } else {
                placeholderCol = 0
            }
        case 2:
            placeholderRow = explicitRow
            placeholderCol = explicitCol
            if let prev = previous, sameFg, sameUnderline, isAdjacent, prev.placeholderRow == placeholderRow, prev.placeholderCol + 1 == placeholderCol {
                msb = prev.msb
            }
        default:
            placeholderRow = explicitRow
            placeholderCol = explicitCol
        }

        guard let placeholderRow, let placeholderCol else {
            return nil
        }

        guard let imageBaseId = colorToId(attribute.fg) else {
            return nil
        }

        let imageId = imageBaseId | (UInt32(min(msb, 255)) << 24)
        let placementId = colorToId(attribute.underlineColor) ?? 0

        return KittyPlaceholderCell(row: row,
                                    col: col,
                                    imageId: imageId,
                                    placementId: placementId,
                                    placeholderRow: placeholderRow,
                                    placeholderCol: placeholderCol,
                                    msb: msb)
    }

    private static func colorToId(_ color: Attribute.Color?) -> UInt32? {
        guard let color else {
            return nil
        }
        switch color {
        case .ansi256(let code):
            return UInt32(code)
        case .trueColor(let red, let green, let blue):
            return UInt32(red) | (UInt32(green) << 8) | (UInt32(blue) << 16)
        case .defaultColor, .defaultInvertedColor:
            return 0
        }
    }
}

#if canImport(CoreGraphics)
struct KittyPlaceholderRenderPlacement: Equatable {
    let offsetX: Int
    let offsetY: Int
    let sourceX: Int
    let sourceY: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let destWidth: Int
    let destHeight: Int

    static func compute(imageSize: CGSize,
                        placementCols: Int,
                        placementRows: Int,
                        cellSize: CGSize,
                        col: Int,
                        row: Int,
                        width: Int,
                        height: Int) -> KittyPlaceholderRenderPlacement? {
        guard imageSize.width > 0,
              imageSize.height > 0,
              placementCols > 0,
              placementRows > 0,
              cellSize.width > 0,
              cellSize.height > 0 else {
            return nil
        }

        let placementWidth = CGFloat(placementCols) * cellSize.width
        let placementHeight = CGFloat(placementRows) * cellSize.height
        let scale = min(placementWidth / imageSize.width, placementHeight / imageSize.height)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let imageOffsetX = (placementWidth - scaledWidth) / 2
        let imageOffsetY = (placementHeight - scaledHeight) / 2

        let runX = CGFloat(col) * cellSize.width
        let runY = CGFloat(row) * cellSize.height
        let runWidth = CGFloat(width) * cellSize.width
        let runHeight = CGFloat(height) * cellSize.height

        let destLeft = max(runX, imageOffsetX)
        let destTop = max(runY, imageOffsetY)
        let destRight = min(runX + runWidth, imageOffsetX + scaledWidth)
        let destBottom = min(runY + runHeight, imageOffsetY + scaledHeight)

        let destWidth = destRight - destLeft
        let destHeight = destBottom - destTop
        if destWidth <= 0 || destHeight <= 0 {
            return nil
        }

        let offsetX = destLeft - runX
        let offsetY = destTop - runY
        let sourceX = (destLeft - imageOffsetX) / scale
        let sourceY = (destTop - imageOffsetY) / scale
        let sourceWidth = destWidth / scale
        let sourceHeight = destHeight / scale

        func roundInt(_ value: CGFloat) -> Int {
            Int(value.rounded())
        }

        return KittyPlaceholderRenderPlacement(offsetX: roundInt(offsetX),
                                               offsetY: roundInt(offsetY),
                                               sourceX: roundInt(sourceX),
                                               sourceY: roundInt(sourceY),
                                               sourceWidth: roundInt(sourceWidth),
                                               sourceHeight: roundInt(sourceHeight),
                                               destWidth: roundInt(destWidth),
                                               destHeight: roundInt(destHeight))
    }
}
#endif

enum KittyPlaceholder {
    static let baseScalar: UInt32 = 0x10EEEE
    static let diacritics: [UInt32] = [
        0x0305,
        0x030D,
        0x030E,
        0x0310,
        0x0312,
        0x033D,
        0x033E,
        0x033F,
        0x0346,
        0x034A,
        0x034B,
        0x034C,
        0x0350,
        0x0351,
        0x0352,
        0x0357,
        0x035B,
        0x0363,
        0x0364,
        0x0365,
        0x0366,
        0x0367,
        0x0368,
        0x0369,
        0x036A,
        0x036B,
        0x036C,
        0x036D,
        0x036E,
        0x036F,
        0x0483,
        0x0484,
        0x0485,
        0x0486,
        0x0487,
        0x0592,
        0x0593,
        0x0594,
        0x0595,
        0x0597,
        0x0598,
        0x0599,
        0x059C,
        0x059D,
        0x059E,
        0x059F,
        0x05A0,
        0x05A1,
        0x05A8,
        0x05A9,
        0x05AB,
        0x05AC,
        0x05AF,
        0x05C4,
        0x0610,
        0x0611,
        0x0612,
        0x0613,
        0x0614,
        0x0615,
        0x0616,
        0x0617,
        0x0657,
        0x0658,
        0x0659,
        0x065A,
        0x065B,
        0x065D,
        0x065E,
        0x06D6,
        0x06D7,
        0x06D8,
        0x06D9,
        0x06DA,
        0x06DB,
        0x06DC,
        0x06DF,
        0x06E0,
        0x06E1,
        0x06E2,
        0x06E4,
        0x06E7,
        0x06E8,
        0x06EB,
        0x06EC,
        0x0730,
        0x0732,
        0x0733,
        0x0735,
        0x0736,
        0x073A,
        0x073D,
        0x073F,
        0x0740,
        0x0741,
        0x0743,
        0x0745,
        0x0747,
        0x0749,
        0x074A,
        0x07EB,
        0x07EC,
        0x07ED,
        0x07EE,
        0x07EF,
        0x07F0,
        0x07F1,
        0x07F3,
        0x0816,
        0x0817,
        0x0818,
        0x0819,
        0x081B,
        0x081C,
        0x081D,
        0x081E,
        0x081F,
        0x0820,
        0x0821,
        0x0822,
        0x0823,
        0x0825,
        0x0826,
        0x0827,
        0x0829,
        0x082A,
        0x082B,
        0x082C,
        0x082D,
        0x0951,
        0x0953,
        0x0954,
        0x0F82,
        0x0F83,
        0x0F86,
        0x0F87,
        0x135D,
        0x135E,
        0x135F,
        0x17DD,
        0x193A,
        0x1A17,
        0x1A75,
        0x1A76,
        0x1A77,
        0x1A78,
        0x1A79,
        0x1A7A,
        0x1A7B,
        0x1A7C,
        0x1B6B,
        0x1B6D,
        0x1B6E,
        0x1B6F,
        0x1B70,
        0x1B71,
        0x1B72,
        0x1B73,
        0x1CD0,
        0x1CD1,
        0x1CD2,
        0x1CDA,
        0x1CDB,
        0x1CE0,
        0x1DC0,
        0x1DC1,
        0x1DC3,
        0x1DC4,
        0x1DC5,
        0x1DC6,
        0x1DC7,
        0x1DC8,
        0x1DC9,
        0x1DCB,
        0x1DCC,
        0x1DD1,
        0x1DD2,
        0x1DD3,
        0x1DD4,
        0x1DD5,
        0x1DD6,
        0x1DD7,
        0x1DD8,
        0x1DD9,
        0x1DDA,
        0x1DDB,
        0x1DDC,
        0x1DDD,
        0x1DDE,
        0x1DDF,
        0x1DE0,
        0x1DE1,
        0x1DE2,
        0x1DE3,
        0x1DE4,
        0x1DE5,
        0x1DE6,
        0x1DFE,
        0x20D0,
        0x20D1,
        0x20D4,
        0x20D5,
        0x20D6,
        0x20D7,
        0x20DB,
        0x20DC,
        0x20E1,
        0x20E7,
        0x20E9,
        0x20F0,
        0x2CEF,
        0x2CF0,
        0x2CF1,
        0x2DE0,
        0x2DE1,
        0x2DE2,
        0x2DE3,
        0x2DE4,
        0x2DE5,
        0x2DE6,
        0x2DE7,
        0x2DE8,
        0x2DE9,
        0x2DEA,
        0x2DEB,
        0x2DEC,
        0x2DED,
        0x2DEE,
        0x2DEF,
        0x2DF0,
        0x2DF1,
        0x2DF2,
        0x2DF3,
        0x2DF4,
        0x2DF5,
        0x2DF6,
        0x2DF7,
        0x2DF8,
        0x2DF9,
        0x2DFA,
        0x2DFB,
        0x2DFC,
        0x2DFD,
        0x2DFE,
        0x2DFF,
        0xA66F,
        0xA67C,
        0xA67D,
        0xA6F0,
        0xA6F1,
        0xA8E0,
        0xA8E1,
        0xA8E2,
        0xA8E3,
        0xA8E4,
        0xA8E5,
        0xA8E6,
        0xA8E7,
        0xA8E8,
        0xA8E9,
        0xA8EA,
        0xA8EB,
        0xA8EC,
        0xA8ED,
        0xA8EE,
        0xA8EF,
        0xA8F0,
        0xA8F1,
        0xAAB0,
        0xAAB2,
        0xAAB3,
        0xAAB7,
        0xAAB8,
        0xAABE,
        0xAABF,
        0xAAC1,
        0xFE20,
        0xFE21,
        0xFE22,
        0xFE23,
        0xFE24,
        0xFE25,
        0xFE26,
        0x10A0F,
        0x10A38,
        0x1D185,
        0x1D186,
        0x1D187,
        0x1D188,
        0x1D189,
        0x1D1AA,
        0x1D1AB,
        0x1D1AC,
        0x1D1AD,
        0x1D242,
        0x1D243,
        0x1D244,
    ]
    static let diacriticIndex: [UInt32: Int] = {
        var map: [UInt32: Int] = [:]
        for (idx, scalar) in KittyPlaceholder.diacritics.enumerated() {
            map[scalar] = idx
        }
        return map
    }()
}
