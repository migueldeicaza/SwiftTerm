//
//  KittyGraphics.swift
//  SwiftTerm
//
//

import Foundation
#if canImport(Compression)
import Compression
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

struct KittyPlacementContext {
    var imageId: UInt32?
    var imageNumber: UInt32?
    var placementId: UInt32?
    var zIndex: Int
    var widthRequest: ImageSizeRequest
    var heightRequest: ImageSizeRequest
    var preserveAspectRatio: Bool
    var cursorPolicy: Int
    var isRelative: Bool
    var pixelOffsetX: Int
    var pixelOffsetY: Int
}

protocol KittyPlacementImage: TerminalImage {
    var kittyIsKitty: Bool { get set }
    var kittyImageId: UInt32? { get set }
    var kittyImageNumber: UInt32? { get set }
    var kittyPlacementId: UInt32? { get set }
    var kittyZIndex: Int { get set }
    var kittyCol: Int { get set }
    var kittyRow: Int { get set }
    var kittyCols: Int { get set }
    var kittyRows: Int { get set }
    var kittyPixelOffsetX: Int { get set }
    var kittyPixelOffsetY: Int { get set }
}

struct KittyPlacementKey: Hashable {
    let imageId: UInt32
    let placementId: UInt32
}

struct KittyPlacementRecord {
    let imageId: UInt32
    let placementId: UInt32
    var col: Int
    var row: Int
    var cols: Int
    var rows: Int
    var zIndex: Int
    var isVirtual: Bool
    var isAlternateBuffer: Bool
}

struct KittyGraphicsControl {
    let action: Character
    let suppressResponses: Int
    let format: Int
    let transmission: Character
    let width: Int
    let height: Int
    let cropX: Int
    let cropY: Int
    let cropWidth: Int
    let cropHeight: Int
    let imageId: UInt32?
    let imageNumber: UInt32?
    let placementId: UInt32?
    let parentImageId: UInt32?
    let parentPlacementId: UInt32?
    let offsetH: Int
    let offsetV: Int
    let pixelOffsetX: Int
    let pixelOffsetY: Int
    let unicodePlaceholder: Int
    let zIndex: Int
    let more: Int
    let compression: Character?
    let columns: Int
    let rows: Int
    let cursorPolicy: Int
    let deleteMode: Character?
}

enum KittyGraphicsPayload {
    case png(Data)
    case rgba(bytes: [UInt8], width: Int, height: Int)
}

struct KittyGraphicsImage {
    let payload: KittyGraphicsPayload
}

struct KittyGraphicsPending {
    let control: KittyGraphicsControl
    var base64Payload: [UInt8]
}

final class KittyGraphicsState {
    var imagesById: [UInt32: KittyGraphicsImage] = [:]
    var imageNumbers: [UInt32: UInt32] = [:]
    var nextImageId: UInt32 = 1
    var pending: KittyGraphicsPending?
    var placementsByKey: [KittyPlacementKey: KittyPlacementRecord] = [:]
}

extension Terminal {
    func handleKittyGraphics(_ data: ArraySlice<UInt8>) {
        guard let (control, payload) = parseKittyGraphicsControl(data) else {
            return
        }

        if control.action == "d" || control.action == "D" {
            kittyGraphicsState.pending = nil
        }

        if control.more == 1 {
            if kittyGraphicsState.pending == nil {
                kittyGraphicsState.pending = KittyGraphicsPending(control: control, base64Payload: Array(payload))
            } else {
                kittyGraphicsState.pending?.base64Payload.append(contentsOf: payload)
            }
            return
        }

        if var pending = kittyGraphicsState.pending {
            pending.base64Payload.append(contentsOf: payload)
            kittyGraphicsState.pending = nil
            processKittyGraphics(control: pending.control, base64Payload: pending.base64Payload)
            return
        }

        processKittyGraphics(control: control, base64Payload: Array(payload))
    }

    private func parseKittyGraphicsControl(_ data: ArraySlice<UInt8>) -> (KittyGraphicsControl, ArraySlice<UInt8>)? {
        let separator = data.firstIndex(of: UInt8(ascii: ";"))
        let controlBytes: ArraySlice<UInt8>
        let payload: ArraySlice<UInt8>
        if let separator = separator {
            controlBytes = data[data.startIndex..<separator]
            payload = data[(separator+1)..<data.endIndex]
        } else {
            controlBytes = data
            payload = data[data.endIndex..<data.endIndex]
        }

        var values: [String: String] = [:]
        var start = controlBytes.startIndex
        while start < controlBytes.endIndex {
            let end = controlBytes[start..<controlBytes.endIndex].firstIndex(of: UInt8(ascii: ",")) ?? controlBytes.endIndex
            let chunk = controlBytes[start..<end]
            if let eq = chunk.firstIndex(of: UInt8(ascii: "=")) {
                let keyBytes = chunk[chunk.startIndex..<eq]
                let valueBytes = chunk[(eq+1)..<chunk.endIndex]
                if let key = String(bytes: keyBytes, encoding: .ascii),
                   let value = String(bytes: valueBytes, encoding: .ascii) {
                    values[key] = value
                }
            }
            start = end == controlBytes.endIndex ? end : end + 1
        }

        func intValue(_ key: String, default value: Int = 0) -> Int {
            guard let raw = values[key], let val = Int(raw) else {
                return value
            }
            return val
        }

        func uintValue(_ key: String) -> UInt32? {
            guard let raw = values[key], let val = UInt32(raw), val > 0 else {
                return nil
            }
            return val
        }

        func charValue(_ key: String, default value: Character) -> Character {
            guard let raw = values[key], let ch = raw.first else {
                return value
            }
            return ch
        }

        let action = charValue("a", default: "t")
        let suppressResponses = intValue("q", default: 0)
        let format = intValue("f", default: 32)
        let transmission = charValue("t", default: "d")
        let width = intValue("s", default: 0)
        let height = intValue("v", default: 0)
        let cropX = intValue("x", default: 0)
        let cropY = intValue("y", default: 0)
        let cropWidth = intValue("w", default: 0)
        let cropHeight = intValue("h", default: 0)
        let imageId = uintValue("i")
        let imageNumber = uintValue("I")
        let placementId = uintValue("p")
        let parentImageId = uintValue("P")
        let parentPlacementId = uintValue("Q")
        let offsetH = intValue("H", default: 0)
        let offsetV = intValue("V", default: 0)
        let pixelOffsetX = intValue("X", default: 0)
        let pixelOffsetY = intValue("Y", default: 0)
        let unicodePlaceholder = intValue("U", default: 0)
        let zIndex = intValue("z", default: 0)
        let more = intValue("m", default: 0)
        let compression = values["o"]?.first
        let columns = intValue("c", default: 0)
        let rows = intValue("r", default: 0)
        let cursorPolicy = intValue("C", default: 0)
        let deleteMode = values["d"]?.first

        let control = KittyGraphicsControl(action: action,
                                           suppressResponses: suppressResponses,
                                           format: format,
                                           transmission: transmission,
                                           width: width,
                                           height: height,
                                           cropX: cropX,
                                           cropY: cropY,
                                           cropWidth: cropWidth,
                                           cropHeight: cropHeight,
                                           imageId: imageId,
                                           imageNumber: imageNumber,
                                           placementId: placementId,
                                           parentImageId: parentImageId,
                                           parentPlacementId: parentPlacementId,
                                           offsetH: offsetH,
                                           offsetV: offsetV,
                                           pixelOffsetX: pixelOffsetX,
                                           pixelOffsetY: pixelOffsetY,
                                           unicodePlaceholder: unicodePlaceholder,
                                           zIndex: zIndex,
                                           more: more,
                                           compression: compression,
                                           columns: columns,
                                           rows: rows,
                                           cursorPolicy: cursorPolicy,
                                           deleteMode: deleteMode)
        return (control, payload)
    }

    private func processKittyGraphics(control: KittyGraphicsControl, base64Payload: [UInt8]) {
        switch control.action {
        case "q":
            handleKittyQuery(control: control, base64Payload: base64Payload)
        case "t", "T":
            handleKittyTransmit(control: control, base64Payload: base64Payload, display: control.action == "T")
        case "p":
            handleKittyPut(control: control)
        case "d", "D":
            handleKittyDelete(control: control)
        default:
            sendKittyError(control: control, message: "EINVAL: unsupported action")
        }
    }

    private func handleKittyQuery(control: KittyGraphicsControl, base64Payload: [UInt8]) {
        guard decodeKittyPayload(control: control, base64Payload: base64Payload) != nil else {
            sendKittyError(control: control, message: "EINVAL: bad payload")
            return
        }
        sendKittyOk(control: control, imageId: control.imageId, imageNumber: control.imageNumber, placementId: control.placementId)
    }

    private func handleKittyTransmit(control: KittyGraphicsControl, base64Payload: [UInt8], display: Bool) {
        guard control.imageId == nil || control.imageNumber == nil else {
            sendKittyError(control: control, message: "EINVAL: i and I are mutually exclusive")
            return
        }

        guard control.transmission == "d" else {
            sendKittyError(control: control, message: "ENOTSUP: unsupported transmission")
            return
        }

        guard let payload = decodeKittyPayload(control: control, base64Payload: base64Payload) else {
            sendKittyError(control: control, message: "EINVAL: bad payload")
            return
        }

        let resolved = resolveKittyImageId(control: control)
        if let error = resolved.errorMessage {
            sendKittyError(control: control, message: error)
            return
        }

        if let id = resolved.imageId {
            kittyGraphicsState.imagesById[id] = KittyGraphicsImage(payload: payload)
            if let number = resolved.imageNumber {
                kittyGraphicsState.imageNumbers[number] = id
            }
        }

        var displayed = true
        if display {
            displayed = displayKittyImage(payload: payload, control: control, imageId: resolved.imageId, imageNumber: resolved.imageNumber)
        }

        if resolved.shouldReply && displayed {
            sendKittyOk(control: control, imageId: resolved.imageId, imageNumber: resolved.imageNumber, placementId: control.placementId)
        }
    }

    private func handleKittyPut(control: KittyGraphicsControl) {
        let resolved = resolveKittyImageForDisplay(control: control)
        guard let image = resolved.image else {
            sendKittyError(control: control, message: "ENOENT: image not found")
            return
        }

        let displayed = displayKittyImage(payload: image.payload, control: control, imageId: resolved.imageId, imageNumber: resolved.imageNumber)

        if resolved.shouldReply && displayed {
            sendKittyOk(control: control, imageId: resolved.imageId, imageNumber: resolved.imageNumber, placementId: control.placementId)
        }
    }

    private func handleKittyDelete(control: KittyGraphicsControl) {
        let mode = control.deleteMode ?? "a"
        let freesData = String(mode).uppercased() == String(mode)
        switch String(mode).lowercased() {
        case "a":
            deletePlacementsVisibleOnScreen()
        case "i":
            guard let imageId = control.imageId else {
                sendKittyError(control: control, message: "EINVAL: missing image id")
                return
            }
            deletePlacementsByImageId(imageId: imageId, placementId: control.placementId)
        case "n":
            guard let imageNumber = control.imageNumber else {
                sendKittyError(control: control, message: "EINVAL: missing image number")
                return
            }
            deletePlacementsByImageNumber(imageNumber: imageNumber, placementId: control.placementId)
        case "c":
            deletePlacementsAtCell(col: buffer.x + 1, row: buffer.y + 1, zIndex: nil)
        case "p":
            guard control.cropX > 0, control.cropY > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing cell position")
                return
            }
            deletePlacementsAtCell(col: control.cropX, row: control.cropY, zIndex: nil)
        case "q":
            guard control.cropX > 0, control.cropY > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing cell position")
                return
            }
            deletePlacementsAtCell(col: control.cropX, row: control.cropY, zIndex: control.zIndex)
        case "x":
            guard control.cropX > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing column")
                return
            }
            deletePlacementsInColumn(control.cropX)
        case "y":
            guard control.cropY > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing row")
                return
            }
            deletePlacementsInRow(control.cropY)
        case "z":
            deletePlacementsWithZIndex(control.zIndex)
        case "r":
            guard control.cropX > 0, control.cropY > 0 else {
                sendKittyError(control: control, message: "EINVAL: missing id range")
                return
            }
            let minId = UInt32(min(control.cropX, control.cropY))
            let maxId = UInt32(max(control.cropX, control.cropY))
            deletePlacementsByImageIdRange(minId: minId, maxId: maxId)
        default:
            sendKittyError(control: control, message: "EINVAL: unsupported delete")
        }
        if freesData {
            cleanupUnusedKittyImages()
        }
    }

    private func resolveKittyImageId(control: KittyGraphicsControl) -> (imageId: UInt32?, imageNumber: UInt32?, shouldReply: Bool, errorMessage: String?) {
        if let number = control.imageNumber {
            let newId = kittyGraphicsState.nextImageId
            kittyGraphicsState.nextImageId &+= 1
            return (newId, number, control.suppressResponses == 0, nil)
        }

        if let id = control.imageId {
            return (id, nil, control.suppressResponses == 0, nil)
        }

        return (nil, nil, false, nil)
    }

    private func resolveKittyImageForDisplay(control: KittyGraphicsControl) -> (image: KittyGraphicsImage?, imageId: UInt32?, imageNumber: UInt32?, shouldReply: Bool) {
        if let number = control.imageNumber, let imageId = kittyGraphicsState.imageNumbers[number], let image = kittyGraphicsState.imagesById[imageId] {
            return (image, imageId, number, control.suppressResponses == 0)
        }
        if let imageId = control.imageId, let image = kittyGraphicsState.imagesById[imageId] {
            return (image, imageId, nil, control.suppressResponses == 0)
        }
        return (nil, nil, nil, control.suppressResponses == 0)
    }

    private func decodeKittyPayload(control: KittyGraphicsControl, base64Payload: [UInt8]) -> KittyGraphicsPayload? {
        if base64Payload.isEmpty {
            return nil
        }
        guard let decoded = Data(base64Encoded: Data(base64Payload), options: .ignoreUnknownCharacters) else {
            return nil
        }

        let rawData: Data
        if let compression = control.compression {
            if compression != "z" {
                return nil
            }
            guard let inflated = decompressZlib(decoded) else {
                return nil
            }
            rawData = inflated
        } else {
            rawData = decoded
        }

        switch control.format {
        case 100:
            return .png(rawData)
        case 24:
            guard control.width > 0, control.height > 0 else {
                return nil
            }
            let expected = control.width * control.height * 3
            guard rawData.count == expected else {
                return nil
            }
            var rgba = [UInt8]()
            rgba.reserveCapacity(control.width * control.height * 4)
            var idx = rawData.startIndex
            while idx < rawData.endIndex {
                let r = rawData[idx]
                let g = rawData[rawData.index(after: idx)]
                let b = rawData[rawData.index(idx, offsetBy: 2)]
                rgba.append(r)
                rgba.append(g)
                rgba.append(b)
                rgba.append(255)
                idx = rawData.index(idx, offsetBy: 3)
            }
            return .rgba(bytes: rgba, width: control.width, height: control.height)
        case 32:
            guard control.width > 0, control.height > 0 else {
                return nil
            }
            let expected = control.width * control.height * 4
            guard rawData.count == expected else {
                return nil
            }
            return .rgba(bytes: [UInt8](rawData), width: control.width, height: control.height)
        default:
            return nil
        }
    }

    private func cropRgba(bytes: [UInt8], width: Int, height: Int, x: Int, y: Int, w: Int, h: Int) -> (bytes: [UInt8], width: Int, height: Int)? {
        let startX = max(0, min(x, width))
        let startY = max(0, min(y, height))
        let maxWidth = width - startX
        let maxHeight = height - startY
        let cropWidth = max(0, min(w > 0 ? w : maxWidth, maxWidth))
        let cropHeight = max(0, min(h > 0 ? h : maxHeight, maxHeight))

        if cropWidth == width && cropHeight == height && startX == 0 && startY == 0 {
            return (bytes, width, height)
        }
        if cropWidth <= 0 || cropHeight <= 0 {
            return nil
        }

        var cropped = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        let srcRowBytes = width * 4
        let dstRowBytes = cropWidth * 4
        for row in 0..<cropHeight {
            let srcIndex = (startY + row) * srcRowBytes + startX * 4
            let dstIndex = row * dstRowBytes
            cropped.replaceSubrange(dstIndex..<(dstIndex + dstRowBytes), with: bytes[srcIndex..<(srcIndex + dstRowBytes)])
        }
        return (cropped, cropWidth, cropHeight)
    }

    private func decodePngToRgba(_ data: Data) -> (bytes: [UInt8], width: Int, height: Int)? {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var output = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(data: &output,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (output, width, height)
        #else
        return nil
        #endif
    }

    private func displayKittyImage(payload: KittyGraphicsPayload, control: KittyGraphicsControl, imageId: UInt32?, imageNumber: UInt32?) -> Bool {
        if control.unicodePlaceholder == 1 {
            if let imageId = imageId, let placementId = control.placementId {
                let origin = resolveKittyPlacementOrigin(control: control)
                if let errorMessage = origin.errorMessage {
                    sendKittyError(control: control, message: errorMessage)
                    return false
                }
                removeKittyPlacement(imageId: imageId, placementId: placementId)
                let col = origin.col ?? buffer.x
                let row = origin.row ?? (buffer.y + buffer.yBase)
                let cols = control.columns > 0 ? control.columns : 0
                let rows = control.rows > 0 ? control.rows : 0
                registerKittyPlacement(imageId: imageId,
                                       placementId: placementId,
                                       col: col,
                                       row: row,
                                       cols: cols,
                                       rows: rows,
                                       zIndex: control.zIndex,
                                       isVirtual: true)
            }
            return true
        }

        let widthRequest: ImageSizeRequest = control.columns > 0 ? .cells(control.columns) : .auto
        let heightRequest: ImageSizeRequest = control.rows > 0 ? .cells(control.rows) : .auto
        let preserveAspectRatio = control.columns == 0 || control.rows == 0
        let cropRequested = control.cropX != 0 || control.cropY != 0 || control.cropWidth != 0 || control.cropHeight != 0
        var displayPayload = payload
        let origin = resolveKittyPlacementOrigin(control: control)
        if let errorMessage = origin.errorMessage {
            sendKittyError(control: control, message: errorMessage)
            return false
        }
        if cropRequested {
            switch payload {
            case .rgba(let bytes, let width, let height):
                guard let cropped = cropRgba(bytes: bytes,
                                             width: width,
                                             height: height,
                                             x: control.cropX,
                                             y: control.cropY,
                                             w: control.cropWidth,
                                             h: control.cropHeight) else {
                    sendKittyError(control: control, message: "EINVAL: bad crop")
                    return false
                }
                displayPayload = .rgba(bytes: cropped.bytes, width: cropped.width, height: cropped.height)
            case .png(let data):
                guard let rgba = decodePngToRgba(data) else {
                    sendKittyError(control: control, message: "ENOTSUP: cannot crop png")
                    return false
                }
                guard let cropped = cropRgba(bytes: rgba.bytes,
                                             width: rgba.width,
                                             height: rgba.height,
                                             x: control.cropX,
                                             y: control.cropY,
                                             w: control.cropWidth,
                                             h: control.cropHeight) else {
                    sendKittyError(control: control, message: "EINVAL: bad crop")
                    return false
                }
                displayPayload = .rgba(bytes: cropped.bytes, width: cropped.width, height: cropped.height)
            }
        }
        kittyPlacementContext = KittyPlacementContext(imageId: imageId ?? control.imageId,
                                                      imageNumber: imageNumber ?? control.imageNumber,
                                                      placementId: control.placementId,
                                                      zIndex: control.zIndex,
                                                      widthRequest: widthRequest,
                                                      heightRequest: heightRequest,
                                                      preserveAspectRatio: preserveAspectRatio,
                                                      cursorPolicy: control.cursorPolicy,
                                                      isRelative: origin.isRelative,
                                                      pixelOffsetX: control.pixelOffsetX,
                                                      pixelOffsetY: control.pixelOffsetY)
        defer {
            kittyPlacementContext = nil
        }
        let savedX = buffer.x
        let savedY = buffer.y

        if let imageId = imageId, let placementId = control.placementId {
            removeKittyPlacement(imageId: imageId, placementId: placementId)
        }

        if let col = origin.col, let row = origin.row {
            let targetRow = row - buffer.yBase
            if targetRow >= 0 && targetRow < buffer.lines.count {
                buffer.y = targetRow
                buffer.x = max(0, min(col, cols - 1))
            } else {
                sendKittyError(control: control, message: "EINVAL: placement out of range")
                return false
            }
        }

        switch displayPayload {
        case .png(let data):
            tdel?.createImage(source: self, data: data, width: widthRequest, height: heightRequest, preserveAspectRatio: preserveAspectRatio)
        case .rgba(var bytes, let width, let height):
            tdel?.createImageFromBitmap(source: self, bytes: &bytes, width: width, height: height)
        }

        if origin.isRelative || control.cursorPolicy == 1 {
            buffer.x = savedX
            buffer.y = savedY
        }
        return true
    }

    private func resolveKittyPlacementOrigin(control: KittyGraphicsControl) -> (col: Int?, row: Int?, isRelative: Bool, errorMessage: String?) {
        guard let parentImageId = control.parentImageId, let parentPlacementId = control.parentPlacementId else {
            return (nil, nil, false, nil)
        }
        let key = KittyPlacementKey(imageId: parentImageId, placementId: parentPlacementId)
        guard let parent = kittyGraphicsState.placementsByKey[key] else {
            return (nil, nil, true, "ENOPARENT: parent placement not found")
        }
        if parent.isAlternateBuffer != isCurrentBufferAlternate {
            return (nil, nil, true, "ENOPARENT: parent placement not in current buffer")
        }
        let col = parent.col + control.offsetH
        let row = parent.row + control.offsetV
        return (col, row, true, nil)
    }

    func registerKittyPlacement(imageId: UInt32, placementId: UInt32, col: Int, row: Int, cols: Int, rows: Int, zIndex: Int, isVirtual: Bool) {
        let key = KittyPlacementKey(imageId: imageId, placementId: placementId)
        let record = KittyPlacementRecord(imageId: imageId,
                                          placementId: placementId,
                                          col: col,
                                          row: row,
                                          cols: cols,
                                          rows: rows,
                                          zIndex: zIndex,
                                          isVirtual: isVirtual,
                                          isAlternateBuffer: isCurrentBufferAlternate)
        kittyGraphicsState.placementsByKey[key] = record
    }

    private func removeKittyPlacement(imageId: UInt32, placementId: UInt32) {
        let predicate: (KittyPlacementImage) -> Bool = { image in
            image.kittyImageId == imageId && image.kittyPlacementId == placementId
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        let combined = removedKeys.union(altRemoved)
        for key in combined {
            kittyGraphicsState.placementsByKey.removeValue(forKey: key)
        }
        kittyGraphicsState.placementsByKey.removeValue(forKey: KittyPlacementKey(imageId: imageId, placementId: placementId))
    }

    private func sendKittyOk(control: KittyGraphicsControl, imageId: UInt32?, imageNumber: UInt32?, placementId: UInt32?) {
        if control.suppressResponses != 0 {
            return
        }
        var parts: [String] = []
        if let id = imageId {
            parts.append("i=\(id)")
        }
        if let number = imageNumber {
            parts.append("I=\(number)")
        }
        if let placement = placementId {
            parts.append("p=\(placement)")
        }
        var controlData = "G"
        if !parts.isEmpty {
            controlData += parts.joined(separator: ",")
        }
        sendResponse(cc.APC, "\(controlData);OK", cc.ST)
    }

    private func sendKittyError(control: KittyGraphicsControl, message: String) {
        if control.suppressResponses != 0 {
            return
        }
        var controlData = "G"
        if let id = control.imageId {
            controlData += "i=\(id)"
        } else if let number = control.imageNumber {
            controlData += "I=\(number)"
        }
        sendResponse(cc.APC, "\(controlData);\(message)", cc.ST)
    }

    func clearAllKittyImages() {
        for idx in 0..<buffer.lines.count {
            buffer.lines[idx].images = nil
        }
        for idx in 0..<altBuffer.lines.count {
            altBuffer.lines[idx].images = nil
        }
        kittyGraphicsState.imagesById.removeAll()
        kittyGraphicsState.imageNumbers.removeAll()
        kittyGraphicsState.placementsByKey.removeAll()
        updateRange(startLine: buffer.scrollTop, endLine: buffer.scrollBottom)
    }

    private func deletePlacementsVisibleOnScreen() {
        let start = buffer.yBase
        let end = min(buffer.yBase + rows, buffer.lines.count)
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: start..<end) { _ in true }
        let recordKeys = removePlacementRecords { record in
            recordIntersectsScreen(record)
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsByImageId(imageId: UInt32, placementId: UInt32?) {
        let predicate: (KittyPlacementImage) -> Bool = { image in
            guard image.kittyImageId == imageId else { return false }
            if let placementId = placementId {
                return image.kittyPlacementId == placementId
            }
            return true
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        let allRemoved = removedKeys.union(altRemoved)
        let recordKeys = removePlacementRecords { record in
            guard record.imageId == imageId else { return false }
            if let placementId = placementId {
                return record.placementId == placementId
            }
            return true
        }
        let extraKeys = recordKeys.subtracting(allRemoved)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsByImageNumber(imageNumber: UInt32, placementId: UInt32?) {
        guard let imageId = kittyGraphicsState.imageNumbers[imageNumber] else {
            return
        }
        deletePlacementsByImageId(imageId: imageId, placementId: placementId)
    }

    private func deletePlacementsByImageIdRange(minId: UInt32, maxId: UInt32) {
        let predicate: (KittyPlacementImage) -> Bool = { image in
            guard let imageId = image.kittyImageId else { return false }
            return imageId >= minId && imageId <= maxId
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        let allRemoved = removedKeys.union(altRemoved)
        let recordKeys = removePlacementRecords { record in
            record.imageId >= minId && record.imageId <= maxId
        }
        let extraKeys = recordKeys.subtracting(allRemoved)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsAtCell(col: Int, row: Int, zIndex: Int?) {
        let colIndex = col - 1
        let rowIndex = row - 1 + buffer.yBase
        let predicate: (KittyPlacementImage) -> Bool = { image in
            guard image.kittyIsKitty else { return false }
            if let zIndex = zIndex, image.kittyZIndex != zIndex {
                return false
            }
            return self.kittyPlacementIntersectsCell(image, col: colIndex, row: rowIndex)
        }
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: 0..<buffer.lines.count, predicate: predicate)
        let recordKeys = removePlacementRecords { record in
            if let zIndex = zIndex, record.zIndex != zIndex {
                return false
            }
            return recordIntersectsCell(record, col: colIndex, row: rowIndex)
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsInColumn(_ col: Int) {
        let colIndex = col - 1
        let predicate: (KittyPlacementImage) -> Bool = { image in
            self.kittyPlacementIntersectsColumn(image, col: colIndex)
        }
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: 0..<buffer.lines.count, predicate: predicate)
        let recordKeys = removePlacementRecords { record in
            recordIntersectsColumn(record, col: colIndex)
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsInRow(_ row: Int) {
        let rowIndex = row - 1 + buffer.yBase
        let predicate: (KittyPlacementImage) -> Bool = { image in
            self.kittyPlacementIntersectsRow(image, row: rowIndex)
        }
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: 0..<buffer.lines.count, predicate: predicate)
        let recordKeys = removePlacementRecords { record in
            recordIntersectsRow(record, row: rowIndex)
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func deletePlacementsWithZIndex(_ zIndex: Int) {
        let predicate: (KittyPlacementImage) -> Bool = { image in
            image.kittyZIndex == zIndex
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        let allRemoved = removedKeys.union(altRemoved)
        let recordKeys = removePlacementRecords { record in
            record.zIndex == zIndex
        }
        let extraKeys = recordKeys.subtracting(allRemoved)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
    }

    private func removeKittyPlacements(in buffer: Buffer, lineRange: Range<Int>, predicate: (KittyPlacementImage) -> Bool) -> Set<KittyPlacementKey> {
        let lower = max(0, lineRange.lowerBound)
        let upper = min(lineRange.upperBound, buffer.lines.count)
        if lower >= upper {
            return []
        }
        var removedKeys = Set<KittyPlacementKey>()
        var minLine = Int.max
        var maxLine = -1
        for idx in lower..<upper {
            let line = buffer.lines[idx]
            guard let images = line.images else {
                continue
            }
            var kept: [TerminalImage] = []
            var lineRemoved = false
            for image in images {
                if let kitty = image as? KittyPlacementImage, kitty.kittyIsKitty, predicate(kitty) {
                    if let imageId = kitty.kittyImageId, let placementId = kitty.kittyPlacementId {
                        removedKeys.insert(KittyPlacementKey(imageId: imageId, placementId: placementId))
                    }
                    lineRemoved = true
                } else {
                    kept.append(image)
                }
            }
            if lineRemoved {
                line.images = kept.isEmpty ? nil : kept
                minLine = min(minLine, idx)
                maxLine = max(maxLine, idx)
            }
        }
        if !removedKeys.isEmpty, buffer === self.buffer, minLine <= maxLine {
            updateRange(startLine: minLine, endLine: maxLine)
        }
        return removedKeys
    }

    private func removeKittyPlacementsByKey(_ keys: Set<KittyPlacementKey>) -> Set<KittyPlacementKey> {
        if keys.isEmpty {
            return []
        }
        let predicate: (KittyPlacementImage) -> Bool = { image in
            guard let imageId = image.kittyImageId, let placementId = image.kittyPlacementId else {
                return false
            }
            return keys.contains(KittyPlacementKey(imageId: imageId, placementId: placementId))
        }
        let removedKeys = removeKittyPlacements(in: normalBuffer, lineRange: 0..<normalBuffer.lines.count, predicate: predicate)
        let altRemoved = removeKittyPlacements(in: altBuffer, lineRange: 0..<altBuffer.lines.count, predicate: predicate)
        return removedKeys.union(altRemoved)
    }

    private func removePlacementRecords(_ predicate: (KittyPlacementRecord) -> Bool) -> Set<KittyPlacementKey> {
        var removed = Set<KittyPlacementKey>()
        for (key, record) in kittyGraphicsState.placementsByKey where predicate(record) {
            removed.insert(key)
        }
        for key in removed {
            kittyGraphicsState.placementsByKey.removeValue(forKey: key)
        }
        return removed
    }

    private func recordIntersectsCell(_ record: KittyPlacementRecord, col: Int, row: Int) -> Bool {
        let left = record.col
        let top = record.row
        let width = max(1, record.cols)
        let height = max(1, record.rows)
        let right = left + width - 1
        let bottom = top + height - 1
        return col >= left && col <= right && row >= top && row <= bottom
    }

    private func recordIntersectsRow(_ record: KittyPlacementRecord, row: Int) -> Bool {
        let top = record.row
        let height = max(1, record.rows)
        let bottom = top + height - 1
        return row >= top && row <= bottom
    }

    private func recordIntersectsColumn(_ record: KittyPlacementRecord, col: Int) -> Bool {
        let left = record.col
        let width = max(1, record.cols)
        let right = left + width - 1
        return col >= left && col <= right
    }

    private func recordIntersectsScreen(_ record: KittyPlacementRecord) -> Bool {
        let screenTop = buffer.yBase
        let screenBottom = buffer.yBase + rows - 1
        let screenLeft = 0
        let screenRight = cols - 1
        let left = record.col
        let top = record.row
        let width = max(1, record.cols)
        let height = max(1, record.rows)
        let right = left + width - 1
        let bottom = top + height - 1
        return right >= screenLeft && left <= screenRight && bottom >= screenTop && top <= screenBottom
    }

    private func cleanupUnusedKittyImages() {
        var used = Set<UInt32>()
        collectUsedKittyImageIds(from: normalBuffer, into: &used)
        collectUsedKittyImageIds(from: altBuffer, into: &used)
        for record in kittyGraphicsState.placementsByKey.values {
            used.insert(record.imageId)
        }
        let unusedIds = kittyGraphicsState.imagesById.keys.filter { !used.contains($0) }
        for id in unusedIds {
            kittyGraphicsState.imagesById.removeValue(forKey: id)
        }
        let unusedNumbers = kittyGraphicsState.imageNumbers.filter { !used.contains($0.value) }.map { $0.key }
        for number in unusedNumbers {
            kittyGraphicsState.imageNumbers.removeValue(forKey: number)
        }
    }

    private func collectUsedKittyImageIds(from buffer: Buffer, into set: inout Set<UInt32>) {
        for idx in 0..<buffer.lines.count {
            let line = buffer.lines[idx]
            guard let images = line.images else { continue }
            for image in images {
                if let kitty = image as? KittyPlacementImage, let imageId = kitty.kittyImageId {
                    set.insert(imageId)
                }
            }
        }
    }

    private func kittyPlacementIntersectsCell(_ image: KittyPlacementImage, col: Int, row: Int) -> Bool {
        let left = image.kittyCol
        let top = image.kittyRow
        let width = max(1, image.kittyCols)
        let height = max(1, image.kittyRows)
        let right = left + width - 1
        let bottom = top + height - 1
        return col >= left && col <= right && row >= top && row <= bottom
    }

    private func kittyPlacementIntersectsRow(_ image: KittyPlacementImage, row: Int) -> Bool {
        let top = image.kittyRow
        let height = max(1, image.kittyRows)
        let bottom = top + height - 1
        return row >= top && row <= bottom
    }

    private func kittyPlacementIntersectsColumn(_ image: KittyPlacementImage, col: Int) -> Bool {
        let left = image.kittyCol
        let width = max(1, image.kittyCols)
        let right = left + width - 1
        return col >= left && col <= right
    }

    private func decompressZlib(_ data: Data) -> Data? {
#if canImport(Compression)
        let dummyDst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let dummySrc = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        var stream = compression_stream(dst_ptr: dummyDst,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer(dummySrc),
                                        src_size: 0,
                                        state: nil)
        let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            dummyDst.deallocate()
            dummySrc.deallocate()
            return nil
        }
        defer {
            compression_stream_destroy(&stream)
            dummyDst.deallocate()
            dummySrc.deallocate()
        }

        var output = Data()
        let dstSize = 64 * 1024
        var dstBuffer = [UInt8](repeating: 0, count: dstSize)

        return data.withUnsafeBytes { srcPtr -> Data? in
            guard let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            stream.src_ptr = srcBase
            stream.src_size = data.count

            while true {
                let status = dstBuffer.withUnsafeMutableBytes { dstPtr -> compression_status in
                    guard let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress else {
                        return COMPRESSION_STATUS_ERROR
                    }
                    stream.dst_ptr = dstBase
                    stream.dst_size = dstSize
                    return compression_stream_process(&stream, 0)
                }
                let produced = dstSize - stream.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    continue
                default:
                    return nil
                }
            }
        }
#else
        return nil
#endif
    }
}
