//
//  KittyGraphics.swift
//  SwiftTerm
//
//

import Foundation
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
#if canImport(Compression)
import Compression
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

#if !os(Windows)
@_silgen_name("shm_open")
private func swiftShmOpen(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32
#endif

struct KittyPlacementContext {
    var imageId: UInt32?
    var imageNumber: UInt32?
    var placementId: UInt32?
    var parentImageId: UInt32?
    var parentPlacementId: UInt32?
    var parentOffsetH: Int
    var parentOffsetV: Int
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
    let parentImageId: UInt32?
    let parentPlacementId: UInt32?
    let parentOffsetH: Int
    let parentOffsetV: Int
    var pixelOffsetX: Int
    var pixelOffsetY: Int
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
    let dataSize: Int
    let dataOffset: Int
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
    let byteSize: Int
    var lastAccessTick: UInt64
}

struct KittyGraphicsPending {
    let control: KittyGraphicsControl
    var base64Payload: [UInt8]
}

final class KittyGraphicsState {
    var imagesById: [UInt32: KittyGraphicsImage] = [:]
    var imageNumbers: [UInt32: UInt32] = [:]
    var nextImageId: UInt32 = 1
    var nextPlacementId: UInt32 = 1
    var pending: KittyGraphicsPending?
    var placementsByKey: [KittyPlacementKey: KittyPlacementRecord] = [:]
    var totalImageBytes: Int = 0
    var nextImageAccessTick: UInt64 = 1
}

extension Terminal {
    private static let kittyMaxImageBytes = 400 * 1024 * 1024
    private static let kittyMaxImageDimension = 10000
    private static let kittyMaxImageCacheBytes = 4 * 1024 * 1024 * 1024

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
        var more = intValue("m", default: 0)
        let compression = values["o"]?.first
        let columns = intValue("c", default: 0)
        let rows = intValue("r", default: 0)
        let cursorPolicy = intValue("C", default: 0)
        let deleteMode = values["d"]?.first
        let dataSize = intValue("S", default: 0)
        let dataOffset = intValue("O", default: 0)

        if transmission != "d" {
            more = 0
        }

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
                                           dataSize: dataSize,
                                           dataOffset: dataOffset,
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

        let payloadResult = loadKittyPayload(control: control, base64Payload: base64Payload)
        if let errorMessage = payloadResult.errorMessage {
            sendKittyError(control: control, message: errorMessage)
            return
        }
        guard let payload = payloadResult.payload else {
            sendKittyError(control: control, message: "EINVAL: bad payload")
            return
        }
        handleKittyTransmitPayload(control: control, payload: payload, display: display)
    }

    private func handleKittyTransmitPayload(control: KittyGraphicsControl, payload: KittyGraphicsPayload, display: Bool) {
        let resolved = resolveKittyImageId(control: control)
        if let error = resolved.errorMessage {
            sendKittyError(control: control, message: error)
            return
        }

        if let id = resolved.imageId {
            storeKittyImage(payload: payload, imageId: id, imageNumber: resolved.imageNumber)
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
        if let number = control.imageNumber, let imageId = kittyGraphicsState.imageNumbers[number], let image = updateKittyImageAccess(imageId: imageId) {
            return (image, imageId, number, control.suppressResponses == 0)
        }
        if let imageId = control.imageId, let image = updateKittyImageAccess(imageId: imageId) {
            return (image, imageId, nil, control.suppressResponses == 0)
        }
        return (nil, nil, nil, control.suppressResponses == 0)
    }

    private func decodeKittyPayload(control: KittyGraphicsControl, base64Payload: [UInt8]) -> KittyGraphicsPayload? {
        if base64Payload.isEmpty {
            return nil
        }
        guard let decoded = decodeKittyBase64Payload(base64Payload), decoded.count <= Terminal.kittyMaxImageBytes else {
            return nil
        }

        guard let rawData = decompressKittyData(decoded, compression: control.compression),
              rawData.count <= Terminal.kittyMaxImageBytes else {
            return nil
        }

        return decodeKittyPayloadData(control: control, rawData: rawData)
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
        guard validateKittyDimensions(width: width, height: height) else {
            return nil
        }
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

    private func kittyPngPixelSize(data: Data) -> (width: Int, height: Int)? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
        #else
        return nil
        #endif
    }

    private func kittyPlacementGridSize(payload: KittyGraphicsPayload,
                                        widthRequest: ImageSizeRequest,
                                        heightRequest: ImageSizeRequest,
                                        preserveAspectRatio: Bool,
                                        cellSize: (width: Int, height: Int)?,
                                        pixelOffsetX: Int,
                                        pixelOffsetY: Int) -> (cols: Int, rows: Int)? {
        if case .cells(let cols) = widthRequest,
           case .cells(let rows) = heightRequest {
            return (max(1, cols), max(1, rows))
        }

        guard let cellSize else {
            return nil
        }

        let imageSize: (width: Int, height: Int)?
        switch payload {
        case .rgba(_, let width, let height):
            imageSize = (width, height)
        case .png(let data):
            imageSize = kittyPngPixelSize(data: data)
        }
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let aspect = Double(imageSize.width) / Double(imageSize.height)
        var widthPx: Double
        var heightPx: Double

        switch widthRequest {
        case .auto:
            widthPx = Double(imageSize.width)
        case .cells(let cols):
            widthPx = Double(cols * cellSize.width)
        case .pixels(let px):
            widthPx = Double(px)
        case .percent:
            return nil
        }

        switch heightRequest {
        case .auto:
            heightPx = Double(imageSize.height)
        case .cells(let rows):
            heightPx = Double(rows * cellSize.height)
        case .pixels(let px):
            heightPx = Double(px)
        case .percent:
            return nil
        }

        if preserveAspectRatio {
            switch (widthRequest, heightRequest) {
            case (.auto, .auto):
                break
            case (.auto, _):
                widthPx = heightPx * aspect
            case (_, .auto):
                heightPx = widthPx / aspect
            default:
                break
            }
        }

        let cols = Int(ceil((widthPx + Double(pixelOffsetX)) / Double(cellSize.width)))
        let rows = Int(ceil((heightPx + Double(pixelOffsetY)) / Double(cellSize.height)))
        return (max(1, cols), max(1, rows))
    }

    private func applyKittyCursorMovement(startCol: Int, startRow: Int, cols: Int, rows: Int, useIndex: Bool) {
        if useIndex {
            buffer.x = startCol
            buffer.y = startRow - buffer.yBase
            for _ in 0..<rows {
                cmdIndex()
            }
            buffer.x = startCol + cols
        } else {
            buffer.x = startCol + cols
            buffer.y = startRow + rows - buffer.yBase
        }
        restrictCursor()
    }

    private func loadKittyPayload(control: KittyGraphicsControl, base64Payload: [UInt8]) -> (payload: KittyGraphicsPayload?, errorMessage: String?) {
        switch control.transmission {
        case "d":
            guard let payload = decodeKittyPayload(control: control, base64Payload: base64Payload) else {
                return (nil, "EINVAL: bad payload")
            }
            return (payload, nil)
        case "f":
            return loadKittyFilePayload(control: control, base64Payload: base64Payload, temporary: false)
        case "t":
            return loadKittyFilePayload(control: control, base64Payload: base64Payload, temporary: true)
        case "s":
            return loadKittySharedMemoryPayload(control: control, base64Payload: base64Payload)
        default:
            return (nil, "ENOTSUP: unsupported transmission")
        }
    }

    private func decodeKittyPayloadData(control: KittyGraphicsControl, rawData: Data) -> KittyGraphicsPayload? {
        guard rawData.count <= Terminal.kittyMaxImageBytes else {
            return nil
        }

        switch control.format {
        case 100:
            guard validateKittyPngDimensions(data: rawData) else {
                return nil
            }
            return .png(rawData)
        case 24:
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 3) else {
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
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 4) else {
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

    private func decodeKittyBase64Payload(_ payload: [UInt8]) -> Data? {
        Data(base64Encoded: Data(payload), options: .ignoreUnknownCharacters)
    }

    private func decompressKittyData(_ data: Data, compression: Character?) -> Data? {
        guard let compression else {
            return data
        }
        guard compression == "z" else {
            return nil
        }
        guard let inflated = decompressZlib(data), inflated.count <= Terminal.kittyMaxImageBytes else {
            return nil
        }
        return inflated
    }

    private func validateKittyDimensions(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else {
            return false
        }
        return width <= Terminal.kittyMaxImageDimension && height <= Terminal.kittyMaxImageDimension
    }

    private func validateKittyRawDimensions(width: Int, height: Int, bytesPerPixel: Int) -> Bool {
        guard validateKittyDimensions(width: width, height: height) else {
            return false
        }
        let pixelCount = Int64(width) * Int64(height)
        let limit = Int64(Terminal.kittyMaxImageBytes) / Int64(bytesPerPixel)
        return pixelCount <= limit
    }

    private func validateKittyPngDimensions(data: Data) -> Bool {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return false
        }
        return validateKittyDimensions(width: width, height: height)
        #else
        return true
        #endif
    }

    private func loadKittyFilePayload(control: KittyGraphicsControl, base64Payload: [UInt8], temporary: Bool) -> (payload: KittyGraphicsPayload?, errorMessage: String?) {
        #if os(Windows)
        return (nil, "ENOTSUP: unsupported transmission")
        #else
        guard let pathData = decodeKittyBase64Payload(base64Payload), !pathData.isEmpty else {
            return (nil, "EINVAL: bad payload")
        }
        guard !pathData.contains(0) else {
            return (nil, "EINVAL: bad path")
        }
        guard let path = String(data: pathData, encoding: .utf8),
              let resolved = resolveKittyRealPath(path) else {
            return (nil, "EINVAL: bad path")
        }
        guard isKittySafePath(resolved) else {
            return (nil, "EINVAL: bad path")
        }
        if temporary {
            guard isKittyTempPath(resolved) else {
                return (nil, "EINVAL: bad temp path")
            }
            guard resolved.contains("tty-graphics-protocol") else {
                return (nil, "EINVAL: bad temp path")
            }
        }

        guard let data = readKittyFileData(path: resolved,
                                           offset: control.dataOffset,
                                           size: control.dataSize,
                                           deleteAfterRead: temporary) else {
            return (nil, "EINVAL: bad payload")
        }

        guard let rawData = decompressKittyData(data, compression: control.compression),
              rawData.count <= Terminal.kittyMaxImageBytes else {
            return (nil, "EINVAL: bad payload")
        }
        guard let payload = decodeKittyPayloadData(control: control, rawData: rawData) else {
            return (nil, "EINVAL: bad payload")
        }
        return (payload, nil)
        #endif
    }

    private func loadKittySharedMemoryPayload(control: KittyGraphicsControl, base64Payload: [UInt8]) -> (payload: KittyGraphicsPayload?, errorMessage: String?) {
        #if os(Windows)
        return (nil, "ENOTSUP: unsupported transmission")
        #else
        guard let pathData = decodeKittyBase64Payload(base64Payload), !pathData.isEmpty else {
            return (nil, "EINVAL: bad payload")
        }
        guard !pathData.contains(0) else {
            return (nil, "EINVAL: bad payload")
        }
        guard let name = String(data: pathData, encoding: .utf8) else {
            return (nil, "EINVAL: bad payload")
        }

        let expectedSize = kittyExpectedDataSize(control: control)
        if control.format != 100, expectedSize == nil {
            return (nil, "EINVAL: bad payload")
        }

        guard let data = readKittySharedMemory(name: name,
                                               expectedSize: expectedSize,
                                               offset: control.dataOffset,
                                               size: control.dataSize) else {
            return (nil, "EINVAL: bad payload")
        }
        guard let rawData = decompressKittyData(data, compression: control.compression),
              rawData.count <= Terminal.kittyMaxImageBytes else {
            return (nil, "EINVAL: bad payload")
        }
        guard let payload = decodeKittyPayloadData(control: control, rawData: rawData) else {
            return (nil, "EINVAL: bad payload")
        }
        return (payload, nil)
        #endif
    }

    private func kittyExpectedDataSize(control: KittyGraphicsControl) -> Int? {
        switch control.format {
        case 100:
            return nil
        case 24:
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 3) else {
                return nil
            }
            return control.width * control.height * 3
        case 32:
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 4) else {
                return nil
            }
            return control.width * control.height * 4
        default:
            return nil
        }
    }

    #if os(Windows)
    private func resolveKittyRealPath(_ path: String) -> String? {
        nil
    }
    #else
    private func resolveKittyRealPath(_ path: String) -> String? {
        return path.withCString { cstr -> String? in
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(cstr, &buffer) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
    }
    #endif

    private func isKittySafePath(_ path: String) -> Bool {
        if path.hasPrefix("/proc/") || path.hasPrefix("/sys/") {
            return false
        }
        if path.hasPrefix("/dev/") && !path.hasPrefix("/dev/shm/") {
            return false
        }
        return true
    }

    private func isKittyTempPath(_ path: String) -> Bool {
        if path.hasPrefix("/tmp") || path.hasPrefix("/dev/shm") {
            return true
        }
        let tempDir = FileManager.default.temporaryDirectory.path
        if path.hasPrefix(tempDir) {
            return true
        }
        if let resolved = resolveKittyRealPath(tempDir), path.hasPrefix(resolved) {
            return true
        }
        return false
    }

    #if !os(Windows)
    private func readKittyFileData(path: String, offset: Int, size: Int, deleteAfterRead: Bool) -> Data? {
        guard offset >= 0, size >= 0 else {
            return nil
        }
        var st = stat()
        let statResult = path.withCString { stat($0, &st) }
        guard statResult == 0 else {
            return nil
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        let fileSize = Int64(st.st_size)
        guard fileSize >= 0 else {
            return nil
        }
        if fileSize > Int64(Terminal.kittyMaxImageBytes) {
            return nil
        }
        if Int64(offset) > fileSize {
            return nil
        }
        let fd = path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            close(fd)
            if deleteAfterRead {
                _ = path.withCString { unlink($0) }
            }
        }

        if offset > 0 {
            let seekResult = lseek(fd, off_t(offset), SEEK_SET)
            guard seekResult >= 0 else {
                return nil
            }
        }

        let maxRead = size > 0 ? min(size, Terminal.kittyMaxImageBytes) : Terminal.kittyMaxImageBytes
        let remaining = min(Int64(maxRead), fileSize - Int64(offset))
        if remaining <= 0 {
            return Data()
        }

        var data = Data()
        data.reserveCapacity(Int(remaining))
        var buffer = [UInt8](repeating: 0, count: 4096)
        var bytesLeft = remaining

        while bytesLeft > 0 {
            let chunkSize = min(buffer.count, Int(bytesLeft))
            let readCount = buffer.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else {
                    return -1
                }
                return read(fd, base, chunkSize)
            }
            if readCount < 0 {
                return nil
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
            bytesLeft -= Int64(readCount)
        }
        return data
    }
    #endif

    #if !os(Windows)
    private func readKittySharedMemory(name: String, expectedSize: Int?, offset: Int, size: Int) -> Data? {
        guard offset >= 0, size >= 0 else {
            return nil
        }
        var fd: Int32 = -1
        let openResult = name.withCString { swiftShmOpen($0, O_RDONLY, 0) }
        fd = openResult
        guard fd >= 0 else {
            return nil
        }
        defer {
            close(fd)
            _ = name.withCString { shm_unlink($0) }
        }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            return nil
        }
        let statSize = Int(st.st_size)
        guard statSize > 0 else {
            return nil
        }
        if statSize > Terminal.kittyMaxImageBytes {
            return nil
        }
        if let expectedSize, statSize < expectedSize {
            return nil
        }
        let effectiveExpectedSize = expectedSize ?? statSize

        let start = offset
        let end: Int
        if size > 0 {
            end = min(offset + size, effectiveExpectedSize)
        } else {
            end = effectiveExpectedSize
        }
        guard start < end, end <= statSize else {
            return nil
        }

        guard let map = mmap(nil, statSize, PROT_READ, MAP_SHARED, fd, 0),
              map != MAP_FAILED else {
            return nil
        }
        defer {
            munmap(map, statSize)
        }

        let startPtr = map.advanced(by: start)
        return Data(bytes: startPtr, count: end - start)
    }
    #endif

    private func displayKittyImage(payload: KittyGraphicsPayload, control: KittyGraphicsControl, imageId: UInt32?, imageNumber: UInt32?) -> Bool {
        if control.unicodePlaceholder == 1 {
            if control.parentImageId != nil || control.parentPlacementId != nil {
                sendKittyError(control: control, message: "EINVAL: virtual placement cannot refer to parent")
                return false
            }
            if let imageId = imageId {
                let origin = resolveKittyPlacementOrigin(control: control)
                if let errorMessage = origin.errorMessage {
                    sendKittyError(control: control, message: errorMessage)
                    return false
                }
                let placementId = control.placementId ?? nextKittyPlacementId()
                removeKittyPlacement(imageId: imageId, placementId: placementId)
                let col = origin.col ?? buffer.x
                let row = origin.row ?? (buffer.y + buffer.yBase)
                let cols = control.columns > 0 ? control.columns : 0
                let rows = control.rows > 0 ? control.rows : 0
                var pixelOffsetX = control.pixelOffsetX
                var pixelOffsetY = control.pixelOffsetY
                if pixelOffsetX < 0 { pixelOffsetX = 0 }
                if pixelOffsetY < 0 { pixelOffsetY = 0 }
                if (pixelOffsetX != 0 || pixelOffsetY != 0),
                   let cellSize = tdel?.cellSizeInPixels(source: self) {
                    let maxX = max(0, cellSize.width - 1)
                    let maxY = max(0, cellSize.height - 1)
                    pixelOffsetX = min(pixelOffsetX, maxX)
                    pixelOffsetY = min(pixelOffsetY, maxY)
                }
                registerKittyPlacement(imageId: imageId,
                                       placementId: placementId,
                                       parentImageId: nil,
                                       parentPlacementId: nil,
                                       parentOffsetH: 0,
                                       parentOffsetV: 0,
                                       pixelOffsetX: pixelOffsetX,
                                       pixelOffsetY: pixelOffsetY,
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
        var pixelOffsetX = control.pixelOffsetX
        var pixelOffsetY = control.pixelOffsetY
        if pixelOffsetX < 0 { pixelOffsetX = 0 }
        if pixelOffsetY < 0 { pixelOffsetY = 0 }
        if (pixelOffsetX != 0 || pixelOffsetY != 0),
           let cellSize = tdel?.cellSizeInPixels(source: self) {
            let maxX = max(0, cellSize.width - 1)
            let maxY = max(0, cellSize.height - 1)
            pixelOffsetX = min(pixelOffsetX, maxX)
            pixelOffsetY = min(pixelOffsetY, maxY)
        }

        kittyPlacementContext = KittyPlacementContext(imageId: imageId ?? control.imageId,
                                                      imageNumber: imageNumber ?? control.imageNumber,
                                                      placementId: control.placementId,
                                                      parentImageId: control.parentImageId,
                                                      parentPlacementId: control.parentPlacementId,
                                                      parentOffsetH: control.offsetH,
                                                      parentOffsetV: control.offsetV,
                                                      zIndex: control.zIndex,
                                                      widthRequest: widthRequest,
                                                      heightRequest: heightRequest,
                                                      preserveAspectRatio: preserveAspectRatio,
                                                      cursorPolicy: control.cursorPolicy,
                                                      isRelative: origin.isRelative,
                                                      pixelOffsetX: pixelOffsetX,
                                                      pixelOffsetY: pixelOffsetY)
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

        let placementCol = buffer.x
        let placementRow = buffer.y + buffer.yBase

        switch displayPayload {
        case .png(let data):
            tdel?.createImage(source: self, data: data, width: widthRequest, height: heightRequest, preserveAspectRatio: preserveAspectRatio)
        case .rgba(var bytes, let width, let height):
            tdel?.createImageFromBitmap(source: self, bytes: &bytes, width: width, height: height)
        }

        if origin.isRelative || control.cursorPolicy == 1 {
            buffer.x = savedX
            buffer.y = savedY
        } else if let grid = kittyPlacementGridSize(payload: displayPayload,
                                                    widthRequest: widthRequest,
                                                    heightRequest: heightRequest,
                                                    preserveAspectRatio: preserveAspectRatio,
                                                    cellSize: tdel?.cellSizeInPixels(source: self),
                                                    pixelOffsetX: pixelOffsetX,
                                                    pixelOffsetY: pixelOffsetY) {
            let moveCols = max(1, grid.cols)
            let moveRows = max(1, grid.rows)
            let useIndex = tdel?.cellSizeInPixels(source: self) == nil
            applyKittyCursorMovement(startCol: placementCol,
                                     startRow: placementRow,
                                     cols: moveCols,
                                     rows: moveRows,
                                     useIndex: useIndex)
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
        let positions = collectKittyPlacementPositions(in: buffer)
        var resolved: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        var visiting: Set<KittyPlacementKey> = []
        guard let parentPosition = resolveKittyPlacementPosition(for: key,
                                                                 positions: positions,
                                                                 resolved: &resolved,
                                                                 visiting: &visiting) else {
            return (nil, nil, true, "ENOPARENT: parent placement not found")
        }
        let col = parentPosition.col + control.offsetH
        let row = parentPosition.row + control.offsetV
        return (col, row, true, nil)
    }

    private func nextKittyPlacementId() -> UInt32 {
        var id = kittyGraphicsState.nextPlacementId
        kittyGraphicsState.nextPlacementId &+= 1
        if id == 0 {
            id = kittyGraphicsState.nextPlacementId
            kittyGraphicsState.nextPlacementId &+= 1
        }
        return id == 0 ? 1 : id
    }

    private func collectKittyPlacementPositions(in buffer: Buffer) -> [KittyPlacementKey: (row: Int, col: Int)] {
        var positions: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        for rowIndex in 0..<buffer.lines.count {
            let line = buffer.lines[rowIndex]
            guard let images = line.images else {
                continue
            }
            for image in images {
                guard let kitty = image as? KittyPlacementImage,
                      kitty.kittyIsKitty,
                      let imageId = kitty.kittyImageId,
                      let placementId = kitty.kittyPlacementId else {
                    continue
                }
                let key = KittyPlacementKey(imageId: imageId, placementId: placementId)
                if let existing = positions[key] {
                    if rowIndex < existing.row {
                        positions[key] = (row: rowIndex, col: existing.col)
                    }
                } else {
                    positions[key] = (row: rowIndex, col: image.col)
                }
            }
        }
        return positions
    }

    private func resolveKittyPlacementPosition(for key: KittyPlacementKey,
                                               positions: [KittyPlacementKey: (row: Int, col: Int)],
                                               resolved: inout [KittyPlacementKey: (row: Int, col: Int)],
                                               visiting: inout Set<KittyPlacementKey>) -> (row: Int, col: Int)? {
        if let cached = resolved[key] {
            return cached
        }
        guard let record = kittyGraphicsState.placementsByKey[key],
              record.isAlternateBuffer == isCurrentBufferAlternate else {
            return nil
        }
        if visiting.contains(key) {
            return nil
        }
        visiting.insert(key)

        var base: (row: Int, col: Int)?
        if record.isVirtual {
            base = (row: record.row, col: record.col)
        } else if let pos = positions[key] {
            base = pos
        } else {
            base = (row: record.row, col: record.col)
        }

        if let parentImageId = record.parentImageId,
           let parentPlacementId = record.parentPlacementId {
            let parentKey = KittyPlacementKey(imageId: parentImageId, placementId: parentPlacementId)
            if let parentPos = resolveKittyPlacementPosition(for: parentKey,
                                                             positions: positions,
                                                             resolved: &resolved,
                                                             visiting: &visiting) {
                base = (row: parentPos.row + record.parentOffsetV,
                        col: parentPos.col + record.parentOffsetH)
            } else {
                base = nil
            }
        }

        visiting.remove(key)
        if let base {
            resolved[key] = base
        }
        return base
    }

    private func moveKittyPlacementImages(in buffer: Buffer,
                                          key: KittyPlacementKey,
                                          deltaRow: Int,
                                          newTopRow: Int,
                                          newLeftCol: Int) {
        var moves: [(image: KittyPlacementImage, targetRow: Int)] = []

        for rowIndex in 0..<buffer.lines.count {
            let line = buffer.lines[rowIndex]
            guard let images = line.images else {
                continue
            }
            var kept: [TerminalImage] = []
            var moved: [KittyPlacementImage] = []
            for image in images {
                if let kitty = image as? KittyPlacementImage,
                   kitty.kittyIsKitty,
                   kitty.kittyImageId == key.imageId,
                   kitty.kittyPlacementId == key.placementId {
                    moved.append(kitty)
                } else {
                    kept.append(image)
                }
            }
            if !moved.isEmpty {
                line.images = kept.isEmpty ? nil : kept
                let targetRow = rowIndex + deltaRow
                for image in moved {
                    moves.append((image: image, targetRow: targetRow))
                }
            }
        }

        for move in moves {
            guard move.targetRow >= 0 && move.targetRow < buffer.lines.count else {
                continue
            }
            var image = move.image
            image.col = newLeftCol
            image.kittyCol = newLeftCol
            image.kittyRow = newTopRow
            buffer.attachImage(image, toLineAt: move.targetRow)
        }
    }

    func updateKittyRelativePlacementsForCurrentBuffer() {
        let isAlt = isCurrentBufferAlternate
        let positions = collectKittyPlacementPositions(in: buffer)

        for (key, record) in kittyGraphicsState.placementsByKey where record.isAlternateBuffer == isAlt {
            if record.isVirtual {
                continue
            }
            guard let pos = positions[key] else {
                continue
            }
            if record.row != pos.row || record.col != pos.col {
                var updated = record
                updated.row = pos.row
                updated.col = pos.col
                kittyGraphicsState.placementsByKey[key] = updated
            }
        }

        var resolved: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        var visiting: Set<KittyPlacementKey> = []

        for (key, record) in kittyGraphicsState.placementsByKey where record.isAlternateBuffer == isAlt {
            guard record.parentImageId != nil, record.parentPlacementId != nil else {
                continue
            }
            guard let desired = resolveKittyPlacementPosition(for: key,
                                                              positions: positions,
                                                              resolved: &resolved,
                                                              visiting: &visiting) else {
                continue
            }
            var updated = record
            if record.isVirtual {
                updated.row = desired.row
                updated.col = desired.col
                kittyGraphicsState.placementsByKey[key] = updated
                continue
            }
            let current = positions[key] ?? (row: record.row, col: record.col)
            let deltaRow = desired.row - current.row
            if deltaRow != 0 || desired.col != current.col {
                moveKittyPlacementImages(in: buffer,
                                         key: key,
                                         deltaRow: deltaRow,
                                         newTopRow: desired.row,
                                         newLeftCol: desired.col)
            }
            updated.row = desired.row
            updated.col = desired.col
            kittyGraphicsState.placementsByKey[key] = updated
        }
    }

    func registerKittyPlacement(imageId: UInt32,
                                placementId: UInt32,
                                parentImageId: UInt32?,
                                parentPlacementId: UInt32?,
                                parentOffsetH: Int,
                                parentOffsetV: Int,
                                pixelOffsetX: Int,
                                pixelOffsetY: Int,
                                col: Int,
                                row: Int,
                                cols: Int,
                                rows: Int,
                                zIndex: Int,
                                isVirtual: Bool) {
        let key = KittyPlacementKey(imageId: imageId, placementId: placementId)
        let record = KittyPlacementRecord(imageId: imageId,
                                          placementId: placementId,
                                          parentImageId: parentImageId,
                                          parentPlacementId: parentPlacementId,
                                          parentOffsetH: parentOffsetH,
                                          parentOffsetV: parentOffsetV,
                                          pixelOffsetX: pixelOffsetX,
                                          pixelOffsetY: pixelOffsetY,
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
            buffer.clearImagesFromLine(at: idx)
        }
        for idx in 0..<altBuffer.lines.count {
            altBuffer.clearImagesFromLine(at: idx)
        }
        kittyGraphicsState.imagesById.removeAll()
        kittyGraphicsState.imageNumbers.removeAll()
        kittyGraphicsState.placementsByKey.removeAll()
        kittyGraphicsState.totalImageBytes = 0
        kittyGraphicsState.nextImageAccessTick = 1
        updateRange(startLine: buffer.scrollTop, endLine: buffer.scrollBottom)
    }

    func clearKittyImages(in buffer: Buffer, isAlternateBuffer: Bool) {
        let removedKeys = removeKittyPlacements(in: buffer, lineRange: 0..<buffer.lines.count) { _ in true }
        let recordKeys = removePlacementRecords { record in
            record.isAlternateBuffer == isAlternateBuffer
        }
        let extraKeys = recordKeys.subtracting(removedKeys)
        if !extraKeys.isEmpty {
            _ = removeKittyPlacementsByKey(extraKeys)
        }
        cleanupUnusedKittyImages()
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
        let used = collectUsedKittyImageIds()
        let unusedIds = kittyGraphicsState.imagesById.keys.filter { !used.contains($0) }
        for id in unusedIds {
            removeKittyImage(imageId: id)
        }
    }

    private func storeKittyImage(payload: KittyGraphicsPayload, imageId: UInt32, imageNumber: UInt32?) {
        let byteSize = kittyPayloadByteSize(payload)
        let lastAccessTick = nextKittyImageAccessTick()
        if let existing = kittyGraphicsState.imagesById[imageId] {
            kittyGraphicsState.totalImageBytes = max(0, kittyGraphicsState.totalImageBytes - existing.byteSize)
        }
        kittyGraphicsState.imagesById[imageId] = KittyGraphicsImage(payload: payload,
                                                                   byteSize: byteSize,
                                                                   lastAccessTick: lastAccessTick)
        kittyGraphicsState.totalImageBytes += byteSize
        if let number = imageNumber {
            kittyGraphicsState.imageNumbers[number] = imageId
        }
        enforceKittyImageCacheLimit()
    }

    private func updateKittyImageAccess(imageId: UInt32) -> KittyGraphicsImage? {
        guard var image = kittyGraphicsState.imagesById[imageId] else {
            return nil
        }
        image.lastAccessTick = nextKittyImageAccessTick()
        kittyGraphicsState.imagesById[imageId] = image
        return image
    }

    private func kittyPayloadByteSize(_ payload: KittyGraphicsPayload) -> Int {
        switch payload {
        case .png(let data):
            return data.count
        case .rgba(let bytes, _, _):
            return bytes.count
        }
    }

    private func nextKittyImageAccessTick() -> UInt64 {
        let tick = kittyGraphicsState.nextImageAccessTick
        kittyGraphicsState.nextImageAccessTick &+= 1
        return tick
    }

    private func enforceKittyImageCacheLimit() {
        let limit = clampedKittyImageCacheLimitBytes()
        guard kittyGraphicsState.totalImageBytes > limit else {
            return
        }

        let used = collectUsedKittyImageIds()
        let unusedIds = kittyGraphicsState.imagesById
            .filter { !used.contains($0.key) }
            .sorted { $0.value.lastAccessTick < $1.value.lastAccessTick }
            .map { $0.key }
        for id in unusedIds {
            removeKittyImage(imageId: id)
            if kittyGraphicsState.totalImageBytes <= limit {
                return
            }
        }

        let oldestIds = kittyGraphicsState.imagesById
            .sorted { $0.value.lastAccessTick < $1.value.lastAccessTick }
            .map { $0.key }
        for id in oldestIds {
            removeKittyImage(imageId: id)
            if kittyGraphicsState.totalImageBytes <= limit {
                return
            }
        }
    }

    private func clampedKittyImageCacheLimitBytes() -> Int {
        let configured = options.kittyImageCacheLimitBytes
        if configured <= 0 {
            return 0
        }
        return min(configured, Terminal.kittyMaxImageCacheBytes)
    }

    private func removeKittyImage(imageId: UInt32) {
        guard let removed = kittyGraphicsState.imagesById.removeValue(forKey: imageId) else {
            return
        }
        kittyGraphicsState.totalImageBytes = max(0, kittyGraphicsState.totalImageBytes - removed.byteSize)
        removeKittyImageNumbers(for: imageId)
    }

    private func removeKittyImageNumbers(for imageId: UInt32) {
        let numbers = kittyGraphicsState.imageNumbers.filter { $0.value == imageId }.map { $0.key }
        for number in numbers {
            kittyGraphicsState.imageNumbers.removeValue(forKey: number)
        }
    }

    private func collectUsedKittyImageIds() -> Set<UInt32> {
        var used = Set<UInt32>()
        collectUsedKittyImageIds(from: normalBuffer, into: &used)
        collectUsedKittyImageIds(from: altBuffer, into: &used)
        for record in kittyGraphicsState.placementsByKey.values {
            used.insert(record.imageId)
        }
        return used
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
