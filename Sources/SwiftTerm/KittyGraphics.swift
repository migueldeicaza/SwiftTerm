//
//  KittyGraphics.swift
//  SwiftTerm
//
//

import Foundation
#if canImport(Musl)
// The Swift Static Linux SDK builds against musl, where the C library module
// is `Musl` and `Glibc` does not exist.
import Musl
#elseif canImport(Glibc)
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
#if canImport(PNG)
import PNG
#endif
#if canImport(LZ77)
import LZ77
#endif

#if !os(Windows)
@_silgen_name("shm_open")
private func swiftShmOpen(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32
#endif

#if canImport(PNG)
private struct KittyPngDataSource: PNG.BytestreamSource {
    let bytes: [UInt8]
    var offset = 0

    mutating func read(count: Int) -> [UInt8]? {
        guard count >= 0, offset <= bytes.count - count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}
#endif

struct KittyPlacementKey: Hashable {
    let imageId: UInt32
    let placementId: UInt32
}

struct KittyPlacementRecord {
    let token: UInt64
    let imageId: UInt32
    let clientPlacementId: UInt32
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
    var sourceX: Int
    var sourceY: Int
    var sourceWidth: Int
    var sourceHeight: Int
    let insertionOrder: UInt64
}

struct KittyGraphicsControl {
    let action: Character
    var suppressResponses: Int
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
    let usage: UInt32
}

enum KittyGraphicsPayload {
    case rgba(bytes: [UInt8], width: Int, height: Int)
}

struct KittyGraphicsImage {
    var payload: KittyGraphicsPayload
    var byteSize: Int
    var lastAccessTick: UInt64
    var imageNumber: UInt32?
    var contentGeneration: UInt64
    var transient: Bool
    var animation: KittyGraphicsAnimation?
}

struct KittyGraphicsAnimationFrame {
    var rgba: [UInt8]
    var gapMilliseconds: UInt32
}

struct KittyGraphicsAnimation {
    enum PlaybackState {
        case stopped
        case runningWait
        case running
    }

    var frames: [KittyGraphicsAnimationFrame]
    var currentIndex: Int = 0
    var playbackState: PlaybackState = .stopped
    var maxLoops: UInt32 = 0
    var currentLoop: UInt32 = 0
    var frameShownAtNanoseconds: UInt64? = nil
}

struct KittyGraphicsPending {
    var control: KittyGraphicsControl
    var base64Payload: [UInt8]
}

final class KittyGraphicsScreenState {
    var imagesById: [UInt32: KittyGraphicsImage] = [:]
    var imageNumbers: [UInt32: UInt32] = [:]
    var nextImplicitImageId: UInt32 = 0x8000_0000
    var nextPlacementId: UInt32 = 1
    var pending: KittyGraphicsPending?
    var placementsByKey: [KittyPlacementKey: KittyPlacementRecord] = [:]
    var totalImageBytes: Int = 0
    var nextImageAccessTick: UInt64 = 1
    var generation: UInt64 = 0
    var nextToken: UInt64 = 1
    var nextInsertionOrder: UInt64 = 1
}

final class KittyGraphicsState {
    let primary = KittyGraphicsScreenState()
    let alternate = KittyGraphicsScreenState()
    var activeIsAlternate = false
    var nextGeneration: UInt64 = 1

    var active: KittyGraphicsScreenState {
        activeIsAlternate ? alternate : primary
    }

    // Internal compatibility accessors for existing semantic tests.
    var imagesById: [UInt32: KittyGraphicsImage] {
        get { active.imagesById }
        set { active.imagesById = newValue }
    }
    var imageNumbers: [UInt32: UInt32] {
        get { active.imageNumbers }
        set { active.imageNumbers = newValue }
    }
    var placementsByKey: [KittyPlacementKey: KittyPlacementRecord] {
        get { active.placementsByKey }
        set { active.placementsByKey = newValue }
    }
    var nextImageId: UInt32 {
        get { active.nextImplicitImageId }
        set { active.nextImplicitImageId = newValue }
    }
    var nextPlacementId: UInt32 {
        get { active.nextPlacementId }
        set { active.nextPlacementId = newValue }
    }
    var pending: KittyGraphicsPending? {
        get { active.pending }
        set { active.pending = newValue }
    }
    var totalImageBytes: Int {
        get { active.totalImageBytes }
        set { active.totalImageBytes = newValue }
    }
    var nextImageAccessTick: UInt64 {
        get { active.nextImageAccessTick }
        set { active.nextImageAccessTick = newValue }
    }
}

extension Terminal {
    private static let kittyMaxImageBytes = 400 * 1024 * 1024
    private static let kittyMaxImageDimension = 10000
    static let kittyMaxApcBytes = 65 * 1024 * 1024

    private var kittyGraphicsStore: KittyGraphicsScreenState {
        kittyGraphicsState.activeIsAlternate = isCurrentBufferAlternate
        return kittyGraphicsState.active
    }

    private func nextKittyGeneration() -> UInt64 {
        let result = kittyGraphicsState.nextGeneration
        kittyGraphicsState.nextGeneration &+= 1
        if kittyGraphicsState.nextGeneration == 0 {
            kittyGraphicsState.nextGeneration = 1
        }
        kittyGraphicsStore.generation = result
        return result
    }

    func handleKittyGraphics(_ data: ArraySlice<UInt8>) {
        guard options.kittyGraphics.storageLimitBytesPerScreen > 0,
              data.count <= Terminal.kittyMaxApcBytes else {
            return
        }
        kittyGraphicsState.activeIsAlternate = isCurrentBufferAlternate
        guard let (control, payload) = parseKittyGraphicsControl(data) else {
            return
        }

        if control.imageId != nil && control.imageNumber != nil {
            sendKittyError(control: control, message: "EINVAL: image ID and number are mutually exclusive")
            return
        }

        if control.action == "d" || control.action == "D" {
            kittyGraphicsState.pending = nil
        }

        if control.more == 1 {
            if kittyGraphicsState.pending == nil {
                // Ghostty invalidates an explicitly identified retransmission as
                // soon as its first chunk arrives. A later abort must not expose
                // the old pixels or placements again.
                if (control.action == "t" || control.action == "T"),
                   let imageId = control.imageId {
                    removeKittyImage(imageId: imageId)
                }
                kittyGraphicsState.pending = KittyGraphicsPending(control: control, base64Payload: Array(payload))
            } else {
                guard var pending = kittyGraphicsState.pending,
                      pending.base64Payload.count <= Terminal.kittyMaxApcBytes - payload.count else {
                    kittyGraphicsState.pending = nil
                    return
                }
                if control.suppressResponses > pending.control.suppressResponses {
                    pending.control.suppressResponses = control.suppressResponses
                }
                pending.base64Payload.append(contentsOf: payload)
                kittyGraphicsState.pending = pending
            }
            return
        }

        if var pending = kittyGraphicsState.pending {
            guard pending.base64Payload.count <= Terminal.kittyMaxApcBytes - payload.count else {
                kittyGraphicsState.pending = nil
                return
            }
            if control.suppressResponses > pending.control.suppressResponses {
                pending.control.suppressResponses = control.suppressResponses
            }
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

        var values: [UInt8: UInt32] = [:]
        var start = controlBytes.startIndex
        while start < controlBytes.endIndex {
            let end = controlBytes[start..<controlBytes.endIndex].firstIndex(of: UInt8(ascii: ",")) ?? controlBytes.endIndex
            let chunk = controlBytes[start..<end]
            if let eq = chunk.firstIndex(of: UInt8(ascii: "=")),
               chunk.distance(from: chunk.startIndex, to: eq) == 1 {
                let keyBytes = chunk[chunk.startIndex..<eq]
                let valueBytes = chunk[(eq+1)..<chunk.endIndex]
                let key = keyBytes[keyBytes.startIndex]
                let isLetter = (key >= UInt8(ascii: "a") && key <= UInt8(ascii: "z")) ||
                    (key >= UInt8(ascii: "A") && key <= UInt8(ascii: "Z"))
                if isLetter, !valueBytes.isEmpty, valueBytes.count <= 11 {
                    if valueBytes.count == 1,
                       let value = valueBytes.first,
                       value < UInt8(ascii: "0") || value > UInt8(ascii: "9") {
                        values[key] = UInt32(value)
                    } else {
                        guard let raw = String(bytes: valueBytes, encoding: .ascii) else {
                            return nil
                        }
                        if key == UInt8(ascii: "z") || key == UInt8(ascii: "H") || key == UInt8(ascii: "V") {
                            guard let value = Int32(raw) else { return nil }
                            values[key] = UInt32(bitPattern: value)
                        } else {
                            guard let value = UInt32(raw) else { return nil }
                            values[key] = value
                        }
                    }
                }
            }
            start = end == controlBytes.endIndex ? end : end + 1
        }

        func intValue(_ key: String, default value: Int = 0) -> Int {
            guard let ascii = key.utf8.first, let raw = values[ascii] else { return value }
            if key == "z" || key == "H" || key == "V" {
                return Int(Int32(bitPattern: raw))
            }
            return Int(raw)
        }

        func uintValue(_ key: String) -> UInt32? {
            guard let ascii = key.utf8.first, let value = values[ascii], value > 0 else { return nil }
            return value
        }

        func charValue(_ key: String, default value: Character) -> Character {
            guard let ascii = key.utf8.first,
                  let raw = values[ascii], raw <= UInt8.max,
                  let scalar = UnicodeScalar(Int(raw)) else { return value }
            return Character(scalar)
        }

        let action = charValue("a", default: "t")
        let quietValue = intValue("q", default: 0)
        let suppressResponses = quietValue == 0 ? 0 : (quietValue == 1 ? 1 : 2)
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
        var more = intValue("m", default: 0) > 0 ? 1 : 0
        let compression = values[UInt8(ascii: "o")].flatMap { raw -> Character? in
            guard raw <= UInt8.max, let scalar = UnicodeScalar(Int(raw)) else { return nil }
            return Character(scalar)
        }
        let columns = intValue("c", default: 0)
        let rows = intValue("r", default: 0)
        let cursorPolicy = intValue("C", default: 0)
        let deleteMode = values[UInt8(ascii: "d")].flatMap { raw -> Character? in
            guard raw <= UInt8.max, let scalar = UnicodeScalar(Int(raw)) else { return nil }
            return Character(scalar)
        }
        let dataSize = intValue("S", default: 0)
        let dataOffset = intValue("O", default: 0)
        let usage = values[UInt8(ascii: "N")] ?? 0

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
                                           deleteMode: deleteMode,
                                           usage: usage)
        return (control, payload)
    }

    private func processKittyGraphics(control: KittyGraphicsControl, base64Payload: [UInt8]) {
        if control.imageId != nil && control.imageNumber != nil {
            sendKittyError(control: control, message: "EINVAL: image ID and number are mutually exclusive")
            return
        }
        switch control.action {
        case "q":
            handleKittyQuery(control: control, base64Payload: base64Payload)
        case "t", "T":
            handleKittyTransmit(control: control, base64Payload: base64Payload, display: control.action == "T")
        case "p":
            handleKittyPut(control: control)
        case "d", "D":
            handleKittyDelete(control: control)
        case "f":
            handleKittyAnimationFrame(control: control, base64Payload: base64Payload)
        case "a":
            handleKittyAnimationControl(control: control)
        case "c":
            handleKittyAnimationComposition(control: control)
        default:
            sendKittyError(control: control, message: "EINVAL: unsupported action")
        }
    }

    private func handleKittyQuery(control: KittyGraphicsControl, base64Payload: [UInt8]) {
        guard control.imageId != nil else {
            sendKittyError(control: control, message: "EINVAL: image ID required")
            return
        }
        let decoded = decodeKittyPayloadDetailed(control: control, base64Payload: base64Payload)
        guard decoded.payload != nil else {
            sendKittyError(control: control, message: decoded.errorMessage ?? "EINVAL: invalid data")
            return
        }
        sendKittyOk(control: control, imageId: control.imageId, imageNumber: control.imageNumber, placementId: control.placementId)
    }

    private func handleKittyAnimationFrame(control: KittyGraphicsControl, base64Payload: [UInt8]) {
        guard let resolved = resolveExistingKittyImage(control: control) else {
            sendKittyError(control: control, message: control.imageId == nil && control.imageNumber == nil
                ? "EINVAL: image ID or number required"
                : "ENOENT: image not found")
            return
        }
        let loaded = loadKittyPayload(control: control, base64Payload: base64Payload)
        guard let payload = loaded.payload else {
            sendKittyError(control: control, message: loaded.errorMessage ?? "EINVAL: invalid data")
            return
        }
        guard case .rgba(let frameBytes, let frameWidth, let frameHeight) = payload,
              case .rgba(let rootBytes, let imageWidth, let imageHeight) = resolved.image.payload else {
            sendKittyError(control: control, message: "EINVAL: invalid data")
            return
        }
        guard frameWidth <= imageWidth, frameHeight <= imageHeight else {
            sendKittyError(control: control, message: "EINVAL: frame dimensions exceed image")
            return
        }

        var image = resolved.image
        var animation = image.animation ?? KittyGraphicsAnimation(frames: [
            KittyGraphicsAnimationFrame(rgba: rootBytes, gapMilliseconds: 0)
        ])
        let count = animation.frames.count
        let requested = control.rows
        let frameNumber = requested == 0 || requested > count + 1 ? count + 1 : requested
        let overwrite = control.pixelOffsetX == 1

        if frameNumber == count + 1 {
            let baseFrame = control.columns
            if baseFrame > 0 && baseFrame > count {
                sendKittyError(control: control, message: "EINVAL: base frame not found")
                return
            }
            let background = UInt32(truncatingIfNeeded: control.pixelOffsetY)
            let red = UInt8(truncatingIfNeeded: background >> 24)
            let green = UInt8(truncatingIfNeeded: background >> 16)
            let blue = UInt8(truncatingIfNeeded: background >> 8)
            let alpha = UInt8(truncatingIfNeeded: background)
            var canvas: [UInt8]
            if baseFrame > 0 {
                canvas = animation.frames[baseFrame - 1].rgba
            } else {
                canvas = []
                canvas.reserveCapacity(imageWidth * imageHeight * 4)
                for _ in 0..<(imageWidth * imageHeight) {
                    canvas.append(red)
                    canvas.append(green)
                    canvas.append(blue)
                    canvas.append(alpha)
                }
            }
            composeKittyPixels(
                destination: &canvas,
                destinationWidth: imageWidth,
                destinationHeight: imageHeight,
                source: frameBytes,
                sourceWidth: frameWidth,
                sourceHeight: frameHeight,
                destinationX: control.cropX,
                destinationY: control.cropY,
                overwrite: overwrite)
            guard reserveKittyStorageBytes(
                canvas.count,
                excludingImageId: resolved.imageId) else {
                sendKittyError(control: control, message: "ENOSPC: animation frame storage full")
                return
            }
            let gap: UInt32 = control.zIndex > 0
                ? UInt32(control.zIndex)
                : (control.zIndex < 0 ? 0 : 40)
            animation.frames.append(KittyGraphicsAnimationFrame(
                rgba: canvas, gapMilliseconds: gap))
            image.byteSize += canvas.count
            kittyGraphicsState.totalImageBytes += canvas.count
        } else {
            let index = frameNumber - 1
            if control.zIndex != 0 {
                animation.frames[index].gapMilliseconds = control.zIndex > 0
                    ? UInt32(control.zIndex) : 0
            }
            composeKittyPixels(
                destination: &animation.frames[index].rgba,
                destinationWidth: imageWidth,
                destinationHeight: imageHeight,
                source: frameBytes,
                sourceWidth: frameWidth,
                sourceHeight: frameHeight,
                destinationX: control.cropX,
                destinationY: control.cropY,
                overwrite: overwrite)
            if index == animation.currentIndex {
                image.contentGeneration = nextKittyGeneration()
                animation.frameShownAtNanoseconds = nil
            }
        }
        image.animation = animation
        kittyGraphicsState.imagesById[resolved.imageId] = image
        _ = nextKittyGeneration()
        if animation.playbackState != .stopped {
            scheduleKittyAnimationTimer()
        }
        sendKittyOk(
            control: control,
            imageId: resolved.imageId,
            imageNumber: control.imageNumber,
            placementId: control.placementId,
            frame: UInt32(frameNumber))
    }

    private func handleKittyAnimationControl(control: KittyGraphicsControl) {
        guard let resolved = resolveExistingKittyImage(control: control) else {
            sendKittyError(control: control, message: control.imageId == nil && control.imageNumber == nil
                ? "EINVAL: image ID or number required"
                : "ENOENT: image not found")
            return
        }
        var image = resolved.image
        guard case .rgba(let rootBytes, _, _) = image.payload else { return }
        var animation = image.animation ?? KittyGraphicsAnimation(frames: [
            KittyGraphicsAnimationFrame(rgba: rootBytes, gapMilliseconds: 0)
        ])
        let frame = control.rows
        if frame > 0 && frame <= animation.frames.count && control.zIndex != 0 {
            animation.frames[frame - 1].gapMilliseconds = control.zIndex > 0
                ? UInt32(control.zIndex) : 0
        }
        let current = control.columns
        if current > 0 && current <= animation.frames.count {
            animation.currentIndex = current - 1
            animation.frameShownAtNanoseconds = nil
            image.contentGeneration = nextKittyGeneration()
        }
        if control.height > 0 {
            animation.maxLoops = UInt32(control.height - 1)
        }
        let previousState = animation.playbackState
        switch control.width {
        case 1:
            animation.playbackState = .stopped
        case 2:
            animation.playbackState = .runningWait
        case 3:
            animation.playbackState = .running
        default:
            break
        }
        if control.width >= 1 && control.width <= 3 {
            animation.currentLoop = 0
            if previousState == .stopped && animation.playbackState != .stopped {
                animation.frameShownAtNanoseconds = nil
            }
        }
        image.animation = animation
        kittyGraphicsState.imagesById[resolved.imageId] = image
        _ = nextKittyGeneration()
        if animation.playbackState != .stopped {
            scheduleKittyAnimationTimer()
        }
    }

    private func handleKittyAnimationComposition(control: KittyGraphicsControl) {
        guard let resolved = resolveExistingKittyImage(control: control) else {
            sendKittyError(control: control, message: control.imageId == nil && control.imageNumber == nil
                ? "EINVAL: image ID or number required"
                : "ENOENT: image not found")
            return
        }
        guard case .rgba(let rootBytes, let imageWidth, let imageHeight) = resolved.image.payload else {
            sendKittyError(control: control, message: "EINVAL: image data incomplete")
            return
        }
        var animation = resolved.image.animation ?? KittyGraphicsAnimation(frames: [
            KittyGraphicsAnimationFrame(rgba: rootBytes, gapMilliseconds: 0)
        ])
        let destinationFrame = control.columns
        let sourceFrame = control.rows
        guard sourceFrame > 0, sourceFrame <= animation.frames.count else {
            sendKittyError(control: control, message: "ENOENT: source frame not found")
            return
        }
        guard destinationFrame > 0, destinationFrame <= animation.frames.count else {
            sendKittyError(control: control, message: "ENOENT: destination frame not found")
            return
        }
        let width = control.cropWidth > 0 ? control.cropWidth : imageWidth
        let height = control.cropHeight > 0 ? control.cropHeight : imageHeight
        let sourceX = control.pixelOffsetX
        let sourceY = control.pixelOffsetY
        guard control.cropX >= 0, control.cropY >= 0,
              control.cropX <= imageWidth - width,
              control.cropY <= imageHeight - height else {
            sendKittyError(control: control, message: "EINVAL: destination rectangle out of bounds")
            return
        }
        guard sourceX >= 0, sourceY >= 0,
              sourceX <= imageWidth - width,
              sourceY <= imageHeight - height else {
            sendKittyError(control: control, message: "EINVAL: source rectangle out of bounds")
            return
        }
        if sourceFrame == destinationFrame,
           kittyRectanglesOverlap(
            x1: sourceX, y1: sourceY, x2: control.cropX, y2: control.cropY,
            width: width, height: height) {
            sendKittyError(control: control, message: "EINVAL: source and destination rectangles overlap")
            return
        }
        let source = animation.frames[sourceFrame - 1].rgba
        composeKittyCanvasPixels(
            destination: &animation.frames[destinationFrame - 1].rgba,
            source: source,
            canvasWidth: imageWidth,
            width: width,
            height: height,
            sourceX: sourceX,
            sourceY: sourceY,
            destinationX: control.cropX,
            destinationY: control.cropY,
            overwrite: control.cursorPolicy != 0)
        var image = resolved.image
        if animation.frames.count == 1 {
            image.payload = .rgba(
                bytes: animation.frames[0].rgba,
                width: imageWidth,
                height: imageHeight)
            image.animation = nil
        } else {
            image.animation = animation
        }
        if destinationFrame - 1 == animation.currentIndex {
            image.contentGeneration = nextKittyGeneration()
        }
        kittyGraphicsState.imagesById[resolved.imageId] = image
        _ = nextKittyGeneration()
        sendKittyOk(
            control: control,
            imageId: resolved.imageId,
            imageNumber: control.imageNumber,
            placementId: control.placementId)
    }

    private func resolveExistingKittyImage(
        control: KittyGraphicsControl
    ) -> (imageId: UInt32, image: KittyGraphicsImage)? {
        if let imageId = control.imageId,
           let image = kittyGraphicsState.imagesById[imageId] {
            return (imageId, image)
        }
        if let number = control.imageNumber,
           let imageId = kittyGraphicsState.imageNumbers[number],
           let image = kittyGraphicsState.imagesById[imageId] {
            return (imageId, image)
        }
        return nil
    }

    private func handleKittyTransmit(control: KittyGraphicsControl, base64Payload: [UInt8], display: Bool) {
        if let imageId = control.imageId {
            removeKittyImage(imageId: imageId)
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
            guard storeKittyImage(
                payload: payload,
                imageId: id,
                imageNumber: resolved.imageNumber,
                transient: (control.usage & 1) != 0) else {
                sendKittyError(control: control, message: "ENOMEM: out of memory")
                return
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
        var selectedImageIds = Set<UInt32>()
        switch String(mode).lowercased() {
        case "a":
            selectedImageIds = imageIdsForPlacements { !$0.isVirtual && recordIntersectsScreen($0) }
            deletePlacementsVisibleOnScreen()
        case "i":
            guard let imageId = control.imageId else { return }
            selectedImageIds.insert(imageId)
            deletePlacementsByImageId(imageId: imageId, placementId: control.placementId)
        case "n":
            guard let imageNumber = control.imageNumber else { return }
            if let imageId = kittyGraphicsState.imageNumbers[imageNumber] {
                selectedImageIds.insert(imageId)
            }
            deletePlacementsByImageNumber(imageNumber: imageNumber, placementId: control.placementId)
        case "c":
            selectedImageIds = imageIdsAtCell(col: buffer.x + 1, row: buffer.y + 1, zIndex: nil)
            deletePlacementsAtCell(col: buffer.x + 1, row: buffer.y + 1, zIndex: nil)
        case "p":
            guard control.cropX > 0, control.cropY > 0 else { return }
            selectedImageIds = imageIdsAtCell(col: control.cropX, row: control.cropY, zIndex: nil)
            deletePlacementsAtCell(col: control.cropX, row: control.cropY, zIndex: nil)
        case "q":
            guard control.cropX > 0, control.cropY > 0 else { return }
            selectedImageIds = imageIdsAtCell(col: control.cropX, row: control.cropY, zIndex: control.zIndex)
            deletePlacementsAtCell(col: control.cropX, row: control.cropY, zIndex: control.zIndex)
        case "x":
            guard control.cropX > 0 else { return }
            selectedImageIds = imageIdsForPlacements { !$0.isVirtual && recordIntersectsColumn($0, col: control.cropX - 1) }
            deletePlacementsInColumn(control.cropX)
        case "y":
            guard control.cropY > 0 else { return }
            let row = control.cropY - 1 + buffer.yBase
            selectedImageIds = imageIdsForPlacements { !$0.isVirtual && recordIntersectsRow($0, row: row) }
            deletePlacementsInRow(control.cropY)
        case "z":
            selectedImageIds = imageIdsForPlacements { !$0.isVirtual && $0.zIndex == control.zIndex }
            deletePlacementsWithZIndex(control.zIndex)
        case "r":
            guard control.cropY > 0, control.cropX <= control.cropY else { return }
            let minId = UInt32(max(0, control.cropX))
            let maxId = UInt32(control.cropY)
            selectedImageIds = Set(kittyGraphicsState.imagesById.keys.filter { $0 >= minId && $0 <= maxId })
            deletePlacementsByImageIdRange(minId: minId, maxId: maxId)
        case "f":
            deleteKittyAnimationFrame(control: control, freesData: freesData)
            return
        default:
            return
        }
        selectedImageIds.formUnion(removeOrphanedKittyPlacements())
        if freesData {
            cleanupUnusedKittyImages(imageIds: selectedImageIds)
        }
    }

    private func deleteKittyAnimationFrame(
        control: KittyGraphicsControl,
        freesData: Bool
    ) {
        guard let resolved = resolveExistingKittyImage(control: control) else { return }
        guard var animation = resolved.image.animation,
              animation.frames.count > 1 else {
            if freesData { removeKittyImage(imageId: resolved.imageId) }
            return
        }
        let requested = max(1, min(control.rows, animation.frames.count))
        let index = requested - 1
        let removed = animation.frames.remove(at: index)
        var image = resolved.image
        image.byteSize = max(0, image.byteSize - removed.rgba.count)
        kittyGraphicsState.totalImageBytes = max(
            0, kittyGraphicsState.totalImageBytes - removed.rgba.count)
        if animation.frames.count == 1 {
            let root = animation.frames[0]
            if case .rgba(_, let width, let height) = image.payload {
                image.payload = .rgba(bytes: root.rgba, width: width, height: height)
            }
            image.animation = nil
        } else {
            if index < animation.currentIndex {
                animation.currentIndex -= 1
            } else if animation.currentIndex >= animation.frames.count {
                animation.currentIndex = animation.frames.count - 1
            }
            animation.frameShownAtNanoseconds = nil
            image.animation = animation
        }
        image.contentGeneration = nextKittyGeneration()
        kittyGraphicsState.imagesById[resolved.imageId] = image
        _ = nextKittyGeneration()
        updateFullScreen()
    }

    private func resolveKittyImageId(control: KittyGraphicsControl) -> (imageId: UInt32?, imageNumber: UInt32?, shouldReply: Bool, errorMessage: String?) {
        if let number = control.imageNumber {
            var newId: UInt32 = 1
            while newId != 0 && kittyGraphicsState.imagesById[newId] != nil {
                newId &+= 1
            }
            if newId == 0 { newId = 1 }
            return (newId, number, true, nil)
        }

        if let id = control.imageId {
            return (id, nil, true, nil)
        }

        var id = kittyGraphicsState.nextImageId
        while id == 0 || kittyGraphicsState.imagesById[id] != nil {
            id &+= 1
        }
        kittyGraphicsState.nextImageId = id &+ 1
        return (id, nil, false, nil)
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
        decodeKittyPayloadDetailed(
            control: control, base64Payload: base64Payload).payload
    }

    private func decodeKittyPayloadDetailed(
        control: KittyGraphicsControl,
        base64Payload: [UInt8]
    ) -> (payload: KittyGraphicsPayload?, errorMessage: String?) {
        guard !base64Payload.isEmpty,
              let decoded = decodeKittyBase64Payload(base64Payload),
              decoded.count <= Terminal.kittyMaxImageBytes else {
            return (nil, "EINVAL: invalid data")
        }
        if control.format != 0 && control.format != 24 &&
            control.format != 32 && control.format != 100 {
            return (nil, "EINVAL: unsupported format")
        }
        if control.format != 100 {
            guard control.width > 0, control.height > 0 else {
                return (nil, "EINVAL: dimensions required")
            }
            guard control.width <= Terminal.kittyMaxImageDimension,
                  control.height <= Terminal.kittyMaxImageDimension else {
                return (nil, "EINVAL: dimensions too large")
            }
        }
        let rawData: Data
        if let compression = control.compression {
            guard compression == "z" else { return (nil, "EINVAL: unsupported format") }
            guard let inflated = decompressZlib(decoded),
                  inflated.count <= Terminal.kittyMaxImageBytes else {
                return (nil, "EINVAL: decompression failed")
            }
            rawData = inflated
        } else {
            rawData = decoded
        }
        if control.format != 100 {
            let bytesPerPixel = control.format == 24 ? 3 : 4
            let expected = control.width * control.height * bytesPerPixel
            if rawData.count < expected {
                return (nil, "ENODATA: insufficient data")
            }
            if rawData.count > expected {
                if control.action != "f" {
                    return (nil, "EINVAL: invalid data")
                }
            }
        }
        guard let payload = decodeKittyPayloadData(control: control, rawData: rawData) else {
            return (nil, "EINVAL: invalid data")
        }
        return (payload, nil)
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
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &output,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Core Graphics renders into premultiplied RGBA. The terminal core and
        // both renderers use canonical straight-alpha RGBA.
        for index in stride(from: 0, to: output.count, by: 4) {
            let alpha = Int(output[index + 3])
            if alpha == 0 {
                output[index] = 0
                output[index + 1] = 0
                output[index + 2] = 0
            } else if alpha < 255 {
                for component in index..<(index + 3) {
                    output[component] = UInt8(min(255, (Int(output[component]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        return (output, width, height)
        #elseif canImport(PNG)
        var source = KittyPngDataSource(bytes: Array(data))
        guard let image = try? PNG.Image.decompress(stream: &source),
              validateKittyDimensions(width: image.size.x, height: image.size.y) else {
            return nil
        }
        let pixels = image.unpack(as: PNG.RGBA<UInt8>.self)
        var output: [UInt8] = []
        output.reserveCapacity(pixels.count * 4)
        for pixel in pixels {
            output.append(pixel.r)
            output.append(pixel.g)
            output.append(pixel.b)
            output.append(pixel.a)
        }
        return (output, image.size.x, image.size.y)
        #else
        return nil
        #endif
    }

    private func loadKittyPayload(control: KittyGraphicsControl, base64Payload: [UInt8]) -> (payload: KittyGraphicsPayload?, errorMessage: String?) {
        switch control.transmission {
        case "d":
            return decodeKittyPayloadDetailed(
                control: control, base64Payload: base64Payload)
        case "f":
            guard options.kittyGraphics.localMediaPolicy.contains(.regularFiles) else {
                return (nil, "EINVAL: unsupported medium")
            }
            return loadKittyFilePayload(control: control, base64Payload: base64Payload, temporary: false)
        case "t":
            guard options.kittyGraphics.localMediaPolicy.contains(.temporaryFiles),
                  options.kittyGraphics.trustedTemporaryDirectory != nil else {
                return (nil, "EINVAL: unsupported medium")
            }
            return loadKittyFilePayload(control: control, base64Payload: base64Payload, temporary: true)
        case "s":
            guard options.kittyGraphics.localMediaPolicy.contains(.sharedMemory) else {
                return (nil, "EINVAL: unsupported medium")
            }
            return loadKittySharedMemoryPayload(control: control, base64Payload: base64Payload)
        default:
            return (nil, "EINVAL: unsupported medium")
        }
    }

    private func decodeKittyPayloadData(control: KittyGraphicsControl, rawData: Data) -> KittyGraphicsPayload? {
        guard rawData.count <= Terminal.kittyMaxImageBytes else {
            return nil
        }

        switch control.format {
        case 100:
            guard let decoded = decodePngToRgba(rawData) else { return nil }
            return .rgba(bytes: decoded.bytes, width: decoded.width, height: decoded.height)
        case 24:
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 3) else {
                return nil
            }
            let expected = control.width * control.height * 3
            guard rawData.count >= expected else {
                return nil
            }
            var rgba = [UInt8]()
            rgba.reserveCapacity(control.width * control.height * 4)
            var idx = rawData.startIndex
            let end = rawData.index(rawData.startIndex, offsetBy: expected)
            while idx < end {
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
        case 0, 32:
            guard validateKittyRawDimensions(width: control.width, height: control.height, bytesPerPixel: 4) else {
                return nil
            }
            let expected = control.width * control.height * 4
            guard rawData.count >= expected else {
                return nil
            }
            return .rgba(
                bytes: Array(rawData.prefix(expected)),
                width: control.width,
                height: control.height)
        default:
            return nil
        }
    }

    private func decodeKittyBase64Payload(_ payload: [UInt8]) -> Data? {
        guard !payload.isEmpty,
              payload.allSatisfy({ byte in
                  (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ||
                  (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) ||
                  (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
                  byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/") ||
                  byte == UInt8(ascii: "=")
              }) else {
            return nil
        }
        return Data(base64Encoded: Data(payload), options: [])
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
            guard isKittyTrustedTemporaryPath(resolved),
                  URL(fileURLWithPath: resolved).lastPathComponent.hasPrefix("tty-graphics-protocol") else {
                return (nil, "EINVAL: temporary file not in temp dir")
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

        let decodedSize = kittyExpectedDataSize(control: control)
        if control.format != 100, decodedSize == nil {
            return (nil, "EINVAL: bad payload")
        }
        let storedSize = control.compression == nil ? decodedSize : nil

        guard let data = readKittySharedMemory(name: name,
                                               expectedSize: storedSize,
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
        case 0, 32:
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
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            return String(
                decoding: buffer[..<end].map { UInt8(bitPattern: $0) },
                as: UTF8.self)
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

    private func isKittyTrustedTemporaryPath(_ path: String) -> Bool {
        guard let configured = options.kittyGraphics.trustedTemporaryDirectory else { return false }
        let directory = configured.standardizedFileURL.path
        let resolvedDirectory = resolveKittyRealPath(directory) ?? directory
        let prefix = resolvedDirectory.hasSuffix("/") ? resolvedDirectory : resolvedDirectory + "/"
        return path.hasPrefix(prefix)
    }

    #if !os(Windows)
    private func readKittyFileData(path: String, offset: Int, size: Int, deleteAfterRead: Bool) -> Data? {
        guard offset >= 0, size >= 0 else {
            return nil
        }
        let fd = path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            close(fd)
            if deleteAfterRead {
                _ = path.withCString { unlink($0) }
            }
        }

        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let fileSize = Int64(st.st_size)
        guard fileSize >= 0,
              fileSize <= Int64(Terminal.kittyMaxImageBytes),
              Int64(offset) <= fileSize else { return nil }
        if size > 0, Int64(size) > fileSize - Int64(offset) { return nil }

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
        guard let imageId else { return false }
        let isVirtual = control.unicodePlaceholder != 0
        if isVirtual && (control.parentImageId != nil || control.parentPlacementId != nil) {
            sendKittyError(control: control, message: "EINVAL: virtual placement cannot refer to a parent")
            return false
        }
        let origin = resolveKittyPlacementOrigin(control: control)
        if let errorMessage = origin.errorMessage {
            sendKittyError(control: control, message: errorMessage)
            return false
        }
        if let parentImageId = control.parentImageId,
           let parentPlacementId = control.parentPlacementId,
           parentImageId == imageId,
           parentPlacementId == control.placementId {
            sendKittyError(control: control, message: "EINVAL: placement cannot be its own parent")
            return false
        }

        if let placementId = control.placementId {
            removeKittyPlacement(imageId: imageId, placementId: placementId)
        }

        let imageSize: (width: Int, height: Int)
        switch payload {
        case .rgba(_, let width, let height):
            imageSize = (width, height)
        }

        let sourceX = max(0, min(control.cropX, imageSize.width))
        let sourceY = max(0, min(control.cropY, imageSize.height))
        let availableWidth = imageSize.width - sourceX
        let availableHeight = imageSize.height - sourceY
        let sourceWidth = max(0, min(control.cropWidth > 0 ? control.cropWidth : availableWidth, availableWidth))
        let sourceHeight = max(0, min(control.cropHeight > 0 ? control.cropHeight : availableHeight, availableHeight))
        guard sourceWidth > 0, sourceHeight > 0 else {
            sendKittyError(control: control, message: "EINVAL: invalid source rectangle")
            return false
        }

        let cellSize = tdel?.cellSizeInPixels(source: self)
        let pixelOffsetX = cellSize.map { min(max(0, control.pixelOffsetX), max(0, $0.width - 1)) } ?? 0
        let pixelOffsetY = cellSize.map { min(max(0, control.pixelOffsetY), max(0, $0.height - 1)) } ?? 0
        let grid: (cols: Int, rows: Int)
        if control.columns > 0 && control.rows > 0 {
            grid = (control.columns, control.rows)
        } else if let cellSize, cellSize.width > 0, cellSize.height > 0 {
            if control.columns > 0 {
                let widthPixels = max(1, control.columns * cellSize.width - pixelOffsetX)
                let heightPixels = max(1, Int((Double(widthPixels) * Double(sourceHeight) / Double(sourceWidth)).rounded(.up)))
                grid = (control.columns, max(1, Int(ceil(Double(heightPixels + pixelOffsetY) / Double(cellSize.height)))))
            } else if control.rows > 0 {
                let heightPixels = max(1, control.rows * cellSize.height - pixelOffsetY)
                let widthPixels = max(1, Int((Double(heightPixels) * Double(sourceWidth) / Double(sourceHeight)).rounded(.up)))
                grid = (max(1, Int(ceil(Double(widthPixels + pixelOffsetX) / Double(cellSize.width)))), control.rows)
            } else {
                grid = (max(1, Int(ceil(Double(sourceWidth + pixelOffsetX) / Double(cellSize.width)))),
                        max(1, Int(ceil(Double(sourceHeight + pixelOffsetY) / Double(cellSize.height)))))
            }
        } else {
            grid = (max(1, control.columns), max(1, control.rows))
        }

        let internalPlacementId = control.placementId ?? nextKittyPlacementId()
        let placementCol = origin.col ?? buffer.x
        let placementRow = origin.row ?? (buffer.y + buffer.yBase)
        registerKittyPlacement(
            imageId: imageId,
            placementId: internalPlacementId,
            parentImageId: control.parentImageId,
            parentPlacementId: origin.parentPlacementId,
            parentOffsetH: control.offsetH,
            parentOffsetV: control.offsetV,
            pixelOffsetX: pixelOffsetX,
            pixelOffsetY: pixelOffsetY,
            col: placementCol,
            row: placementRow,
            cols: grid.cols,
            rows: grid.rows,
            zIndex: control.zIndex,
            isVirtual: isVirtual,
            clientPlacementId: control.placementId ?? 0,
            sourceX: sourceX,
            sourceY: sourceY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight)

        if let animation = kittyGraphicsState.imagesById[imageId]?.animation,
           animation.playbackState != .stopped {
            scheduleKittyAnimationTimer()
        }

        if !isVirtual && !origin.isRelative && control.cursorPolicy != 1 {
            let targetColumn = placementCol + grid.cols
            let wraps = targetColumn >= cols
            let rowsToMove = max(0, grid.rows - 1) + (wraps ? 1 : 0)
            let maximumMoves = rows + max(0, buffer.scrollBottom - buffer.y)
            for _ in 0..<min(rowsToMove, maximumMoves) {
                cmdIndex()
            }
            buffer.x = wraps ? 0 : targetColumn
            restrictCursor()
        }
        updateFullScreen()
        return true
    }

    private func resolveKittyPlacementOrigin(control: KittyGraphicsControl) -> (
        col: Int?, row: Int?, isRelative: Bool,
        parentPlacementId: UInt32?, errorMessage: String?
    ) {
        guard let parentImageId = control.parentImageId else {
            return (nil, nil, false, nil, nil)
        }
        guard kittyGraphicsState.imagesById[parentImageId] != nil else {
            return (nil, nil, true, nil, "ENOPARENT: parent image not found")
        }
        let candidates = kittyGraphicsState.placementsByKey.filter {
            $0.key.imageId == parentImageId && $0.value.isAlternateBuffer == isCurrentBufferAlternate
        }
        let key: KittyPlacementKey
        if let requested = control.parentPlacementId {
            key = KittyPlacementKey(imageId: parentImageId, placementId: requested)
            guard kittyGraphicsState.placementsByKey[key] != nil else {
                return (nil, nil, true, nil, "ENOPARENT: parent placement not found")
            }
        } else {
            guard let selected = candidates.min(by: { lhs, rhs in
                let lhsExternal = lhs.value.clientPlacementId > 0
                let rhsExternal = rhs.value.clientPlacementId > 0
                if lhsExternal != rhsExternal { return lhsExternal }
                if lhs.value.clientPlacementId != rhs.value.clientPlacementId {
                    return lhs.value.clientPlacementId < rhs.value.clientPlacementId
                }
                return lhs.value.insertionOrder < rhs.value.insertionOrder
            }) else {
                return (nil, nil, true, nil, "ENOPARENT: parent placement not found")
            }
            key = selected.key
        }

        let child = control.imageId.flatMap { imageId in
            control.placementId.map { KittyPlacementKey(imageId: imageId, placementId: $0) }
        }
        if let child, child == key {
                return (nil, nil, true, nil, "EINVAL: placement cannot be its own parent")
        }
        var ancestor = key
        var depth = 1
        while let record = kittyGraphicsState.placementsByKey[ancestor],
              let nextImageId = record.parentImageId,
              let nextPlacementId = record.parentPlacementId {
            if depth >= 8 {
                return (nil, nil, true, nil, "ETOODEEP: parent chain too deep")
            }
            ancestor = KittyPlacementKey(imageId: nextImageId, placementId: nextPlacementId)
            if let child, ancestor == child {
                return (nil, nil, true, nil, "ECYCLE: parent chain creates a cycle")
            }
            guard kittyGraphicsState.placementsByKey[ancestor] != nil else {
                return (nil, nil, true, nil, "ENOENT: parent chain ancestor not found")
            }
            depth += 1
        }
        let positions: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        var resolved: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        var visiting: Set<KittyPlacementKey> = []
        guard let parentPosition = resolveKittyPlacementPosition(for: key,
                                                                 positions: positions,
                                                                 resolved: &resolved,
                                                                 visiting: &visiting) else {
            return (nil, nil, true, nil, "ENOPARENT: parent placement not found")
        }
        let col = parentPosition.col + control.offsetH
        let row = parentPosition.row + control.offsetV
        return (col, row, true, key.placementId, nil)
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

    /// Move root placements for an in-place scroll region. Virtual
    /// placements follow placeholder cells, and relative placements follow
    /// their parent, so this method does not move either kind directly.
    func scrollKittyPlacementsInMargins(
        top: Int,
        bottom: Int,
        left: Int,
        right: Int,
        delta: Int
    ) {
        var removals = Set<KittyPlacementKey>()
        var contentChanged = false
        for (key, original) in kittyGraphicsStore.placementsByKey {
            guard !original.isVirtual, original.parentImageId == nil else { continue }
            let placementRight = min(original.col + max(1, original.cols) - 1, cols - 1)
            let placementBottom = original.row + max(1, original.rows) - 1
            guard original.row >= top, placementBottom <= bottom,
                  original.col >= left, placementRight <= right else { continue }

            var record = original
            let newRow = record.row + delta
            let topClip = max(0, top - newRow)
            let bottomClip = max(0, newRow + record.rows - 1 - bottom)
            if topClip >= record.rows || bottomClip >= record.rows {
                removals.insert(key)
                contentChanged = true
                continue
            }
            if topClip > 0 {
                let clippedPixels = record.sourceHeight * topClip / max(1, record.rows)
                record.sourceY += clippedPixels
                record.sourceHeight -= clippedPixels
                record.rows -= topClip
                record.row = top
                contentChanged = true
            } else {
                record.row = newRow
            }
            if bottomClip > 0 {
                let clippedPixels = record.sourceHeight * bottomClip / max(1, record.rows)
                record.sourceHeight -= clippedPixels
                record.rows -= bottomClip
                contentChanged = true
            }
            kittyGraphicsStore.placementsByKey[key] = record
        }
        if !removals.isEmpty {
            _ = removePlacementRecords { record in
                removals.contains(KittyPlacementKey(imageId: record.imageId, placementId: record.placementId))
            }
            _ = removeOrphanedKittyPlacements()
        } else if contentChanged {
            _ = nextKittyGeneration()
        }
    }

    /// Translate absolute row anchors when the bounded scrollback buffer
    /// recycles its oldest row.
    func trimKittyPlacementRows() {
        var removals = Set<KittyPlacementKey>()
        for (key, original) in kittyGraphicsStore.placementsByKey {
            guard !original.isVirtual, original.parentImageId == nil else { continue }
            var record = original
            record.row -= 1
            if record.row + max(1, record.rows) <= 0 {
                removals.insert(key)
            } else {
                kittyGraphicsStore.placementsByKey[key] = record
            }
        }
        if !removals.isEmpty {
            _ = removePlacementRecords { record in
                removals.contains(KittyPlacementKey(imageId: record.imageId, placementId: record.placementId))
            }
            _ = removeOrphanedKittyPlacements()
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
                                isVirtual: Bool,
                                clientPlacementId: UInt32? = nil,
                                sourceX: Int = 0,
                                sourceY: Int = 0,
                                sourceWidth: Int = 0,
                                sourceHeight: Int = 0) {
        let key = KittyPlacementKey(imageId: imageId, placementId: placementId)
        let store = kittyGraphicsStore
        let token = store.nextToken
        store.nextToken &+= 1
        let insertionOrder = store.nextInsertionOrder
        store.nextInsertionOrder &+= 1
        let record = KittyPlacementRecord(token: token,
                                          imageId: imageId,
                                          clientPlacementId: clientPlacementId ?? placementId,
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
                                          isAlternateBuffer: isCurrentBufferAlternate,
                                          sourceX: sourceX,
                                          sourceY: sourceY,
                                          sourceWidth: sourceWidth,
                                          sourceHeight: sourceHeight,
                                          insertionOrder: insertionOrder)
        kittyGraphicsState.placementsByKey[key] = record
        _ = nextKittyGeneration()
    }

    private func removeKittyPlacement(imageId: UInt32, placementId: UInt32) {
        _ = removePlacementRecords { record in
            record.imageId == imageId && record.placementId == placementId
        }
    }

    private func sendKittyOk(
        control: KittyGraphicsControl,
        imageId: UInt32?,
        imageNumber: UInt32?,
        placementId: UInt32?,
        frame: UInt32? = nil
    ) {
        if control.suppressResponses != 0 || (imageId == nil && imageNumber == nil) {
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
        if let frame, frame > 0 {
            parts.append("r=\(frame)")
        }
        var controlData = "G"
        if !parts.isEmpty {
            controlData += parts.joined(separator: ",")
        }
        sendResponse(cc.APC, "\(controlData);OK", cc.ST)
    }

    private func sendKittyError(control: KittyGraphicsControl, message: String) {
        if control.suppressResponses >= 2 || (control.imageId == nil && control.imageNumber == nil) {
            return
        }
        var parts: [String] = []
        if let id = control.imageId {
            parts.append("i=\(id)")
        }
        if let number = control.imageNumber {
            parts.append("I=\(number)")
        }
        if let placement = control.placementId {
            parts.append("p=\(placement)")
        }
        let controlData = "G" + parts.joined(separator: ",")
        sendResponse(cc.APC, "\(controlData);\(message)", cc.ST)
    }

    func clearAllKittyImages() {
        resetKittyGraphicsStore(kittyGraphicsState.primary)
        resetKittyGraphicsStore(kittyGraphicsState.alternate)
        updateRange(startLine: buffer.scrollTop, endLine: buffer.scrollBottom)
    }

    private func resetKittyGraphicsStore(_ store: KittyGraphicsScreenState) {
        store.imagesById.removeAll()
        store.imageNumbers.removeAll()
        store.placementsByKey.removeAll()
        store.pending = nil
        store.totalImageBytes = 0
        store.nextImageAccessTick = 1
        store.nextImplicitImageId = 0x8000_0000
        store.generation = kittyGraphicsState.nextGeneration
        kittyGraphicsState.nextGeneration &+= 1
        if kittyGraphicsState.nextGeneration == 0 {
            kittyGraphicsState.nextGeneration = 1
        }
    }

    func clearKittyImages(in buffer: Buffer, isAlternateBuffer: Bool) {
        kittyGraphicsState.activeIsAlternate = isAlternateBuffer
        _ = removePlacementRecords { record in
            record.isAlternateBuffer == isAlternateBuffer
        }
        cleanupUnusedKittyImages()
        kittyGraphicsState.activeIsAlternate = isCurrentBufferAlternate
    }

    private func deletePlacementsVisibleOnScreen() {
        _ = removePlacementRecords { record in
            !record.isVirtual && recordIntersectsScreen(record)
        }
    }

    private func deletePlacementsByImageId(imageId: UInt32, placementId: UInt32?) {
        _ = removePlacementRecords { record in
            guard record.imageId == imageId else { return false }
            if let placementId = placementId {
                return record.placementId == placementId
            }
            return true
        }
    }

    private func deletePlacementsByImageNumber(imageNumber: UInt32, placementId: UInt32?) {
        guard let imageId = kittyGraphicsState.imageNumbers[imageNumber] else {
            return
        }
        deletePlacementsByImageId(imageId: imageId, placementId: placementId)
    }

    private func deletePlacementsByImageIdRange(minId: UInt32, maxId: UInt32) {
        _ = removePlacementRecords { record in
            record.imageId >= minId && record.imageId <= maxId
        }
    }

    private func deletePlacementsAtCell(col: Int, row: Int, zIndex: Int?) {
        let colIndex = col - 1
        let rowIndex = row - 1 + buffer.yBase
        _ = removePlacementRecords { record in
            guard !record.isVirtual else { return false }
            if let zIndex = zIndex, record.zIndex != zIndex {
                return false
            }
            return recordIntersectsCell(record, col: colIndex, row: rowIndex)
        }
    }

    private func deletePlacementsInColumn(_ col: Int) {
        let colIndex = col - 1
        _ = removePlacementRecords { record in
            !record.isVirtual && recordIntersectsColumn(record, col: colIndex)
        }
    }

    private func deletePlacementsInRow(_ row: Int) {
        let rowIndex = row - 1 + buffer.yBase
        _ = removePlacementRecords { record in
            !record.isVirtual && recordIntersectsRow(record, row: rowIndex)
        }
    }

    private func deletePlacementsWithZIndex(_ zIndex: Int) {
        _ = removePlacementRecords { record in
            !record.isVirtual && record.zIndex == zIndex
        }
    }

    private func removePlacementRecords(_ predicate: (KittyPlacementRecord) -> Bool) -> Set<KittyPlacementKey> {
        var removed = Set<KittyPlacementKey>()
        var needsFullRedraw = false
        for (key, record) in kittyGraphicsState.placementsByKey where predicate(record) {
            removed.insert(key)
            if record.isAlternateBuffer == isCurrentBufferAlternate {
                needsFullRedraw = true
            }
        }
        for key in removed {
            kittyGraphicsState.placementsByKey.removeValue(forKey: key)
        }
        if needsFullRedraw {
            updateFullScreen()
        }
        if !removed.isEmpty {
            _ = nextKittyGeneration()
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

    private func imageIdsForPlacements(
        _ predicate: (KittyPlacementRecord) -> Bool
    ) -> Set<UInt32> {
        Set(kittyGraphicsState.placementsByKey.values.lazy.filter(predicate).map(\.imageId))
    }

    private func imageIdsAtCell(col: Int, row: Int, zIndex: Int?) -> Set<UInt32> {
        let colIndex = col - 1
        let rowIndex = row - 1 + buffer.yBase
        return imageIdsForPlacements { record in
            guard !record.isVirtual else { return false }
            if let zIndex, record.zIndex != zIndex { return false }
            return recordIntersectsCell(record, col: colIndex, row: rowIndex)
        }
    }

    /// Remove relative descendants whose parent no longer exists. The return
    /// value identifies images that an uppercase selector can reclaim.
    private func removeOrphanedKittyPlacements() -> Set<UInt32> {
        var removedImageIds = Set<UInt32>()
        while true {
            let orphanKeys: Set<KittyPlacementKey> = Set(
                kittyGraphicsState.placementsByKey.compactMap { element -> KittyPlacementKey? in
                let (key, record) = element
                guard let parentImageId = record.parentImageId else { return nil }
                let parentPlacementId = record.parentPlacementId ?? 0
                if parentPlacementId > 0 {
                    let parent = KittyPlacementKey(imageId: parentImageId, placementId: parentPlacementId)
                    return kittyGraphicsState.placementsByKey[parent] == nil ? key : nil
                }
                let hasParent = kittyGraphicsState.placementsByKey.contains {
                    $0.key.imageId == parentImageId && $0.value.clientPlacementId > 0
                }
                return hasParent ? nil : key
            })
            if orphanKeys.isEmpty { break }
            for key in orphanKeys {
                if let record = kittyGraphicsState.placementsByKey[key] {
                    removedImageIds.insert(record.imageId)
                }
            }
            _ = removePlacementRecords { orphanKeys.contains(KittyPlacementKey(imageId: $0.imageId, placementId: $0.placementId)) }
        }
        return removedImageIds
    }

    private func cleanupUnusedKittyImages() {
        let used = collectUsedKittyImageIds()
        let unusedIds = kittyGraphicsState.imagesById.keys.filter { !used.contains($0) }
        for id in unusedIds {
            removeKittyImage(imageId: id)
        }
    }

    private func cleanupUnusedKittyImages(imageIds: Set<UInt32>) {
        let used = collectUsedKittyImageIds()
        for id in imageIds where !used.contains(id) {
            removeKittyImage(imageId: id)
        }
    }

    private func storeKittyImage(
        payload: KittyGraphicsPayload,
        imageId: UInt32,
        imageNumber: UInt32?,
        transient: Bool
    ) -> Bool {
        let byteSize = kittyPayloadByteSize(payload)
        guard reserveKittyStorageBytes(byteSize, excludingImageId: imageId) else {
            return false
        }
        let lastAccessTick = nextKittyImageAccessTick()
        if let existing = kittyGraphicsState.imagesById[imageId] {
            kittyGraphicsState.totalImageBytes = max(0, kittyGraphicsState.totalImageBytes - existing.byteSize)
            deletePlacementsByImageId(imageId: imageId, placementId: nil)
            removeKittyImageNumbers(for: imageId)
        }
        let contentGeneration = nextKittyGeneration()
        kittyGraphicsState.imagesById[imageId] = KittyGraphicsImage(payload: payload,
                                                                   byteSize: byteSize,
                                                                   lastAccessTick: lastAccessTick,
                                                                   imageNumber: imageNumber,
                                                                   contentGeneration: contentGeneration,
                                                                   transient: transient,
                                                                   animation: nil)
        kittyGraphicsState.totalImageBytes += byteSize
        if let number = imageNumber {
            kittyGraphicsState.imageNumbers[number] = imageId
        }
        return true
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
        case .rgba(let bytes, _, _):
            return bytes.count
        }
    }

    private func nextKittyImageAccessTick() -> UInt64 {
        let tick = kittyGraphicsState.nextImageAccessTick
        kittyGraphicsState.nextImageAccessTick &+= 1
        return tick
    }

    private func reserveKittyStorageBytes(
        _ bytes: Int,
        excludingImageId: UInt32?
    ) -> Bool {
        let limit = clampedKittyImageCacheLimitBytes()
        guard bytes <= limit else { return false }
        guard kittyGraphicsState.totalImageBytes <= limit - bytes else {
            let used = collectUsedKittyImageIds()
            let oldestIds = kittyGraphicsState.imagesById
                .filter { $0.key != excludingImageId }
                .sorted { lhs, rhs in
                    if lhs.value.transient != rhs.value.transient {
                        return lhs.value.transient
                    }
                    let lhsUsed = used.contains(lhs.key)
                    let rhsUsed = used.contains(rhs.key)
                    if lhsUsed != rhsUsed {
                        return !lhsUsed
                    }
                    return lhs.value.lastAccessTick < rhs.value.lastAccessTick
                }
                .map { $0.key }
            for id in oldestIds {
                removeKittyImage(imageId: id)
                if kittyGraphicsState.totalImageBytes <= limit - bytes {
                    return true
                }
            }
            return false
        }
        return true
    }

    private func clampedKittyImageCacheLimitBytes() -> Int {
        Int(options.kittyGraphics.storageLimitBytesPerScreen)
    }

    private func removeKittyImage(imageId: UInt32) {
        deletePlacementsByImageId(imageId: imageId, placementId: nil)
        guard let removed = kittyGraphicsState.imagesById.removeValue(forKey: imageId) else {
            return
        }
        kittyGraphicsState.totalImageBytes = max(0, kittyGraphicsState.totalImageBytes - removed.byteSize)
        removeKittyImageNumbers(for: imageId)
        _ = nextKittyGeneration()
    }

    private func removeKittyImageNumbers(for imageId: UInt32) {
        let numbers = kittyGraphicsState.imageNumbers.filter { $0.value == imageId }.map { $0.key }
        for number in numbers {
            kittyGraphicsState.imageNumbers.removeValue(forKey: number)
        }
    }

    private func collectUsedKittyImageIds() -> Set<UInt32> {
        Set(kittyGraphicsState.placementsByKey.values.map(\.imageId))
    }

    private func composeKittyPixels(
        destination: inout [UInt8],
        destinationWidth: Int,
        destinationHeight: Int,
        source: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        destinationX: Int,
        destinationY: Int,
        overwrite: Bool
    ) {
        guard destinationX < destinationWidth, destinationY < destinationHeight else { return }
        let startX = max(0, destinationX)
        let startY = max(0, destinationY)
        let sourceStartX = max(0, -destinationX)
        let sourceStartY = max(0, -destinationY)
        let copyWidth = min(sourceWidth - sourceStartX, destinationWidth - startX)
        let copyHeight = min(sourceHeight - sourceStartY, destinationHeight - startY)
        guard copyWidth > 0, copyHeight > 0 else { return }
        for row in 0..<copyHeight {
            for column in 0..<copyWidth {
                let destinationIndex = ((startY + row) * destinationWidth + startX + column) * 4
                let sourceIndex = ((sourceStartY + row) * sourceWidth + sourceStartX + column) * 4
                composeKittyPixel(
                    destination: &destination,
                    destinationIndex: destinationIndex,
                    source: source,
                    sourceIndex: sourceIndex,
                    overwrite: overwrite)
            }
        }
    }

    private func composeKittyCanvasPixels(
        destination: inout [UInt8],
        source: [UInt8],
        canvasWidth: Int,
        width: Int,
        height: Int,
        sourceX: Int,
        sourceY: Int,
        destinationX: Int,
        destinationY: Int,
        overwrite: Bool
    ) {
        for row in 0..<height {
            for column in 0..<width {
                let destinationIndex = ((destinationY + row) * canvasWidth + destinationX + column) * 4
                let sourceIndex = ((sourceY + row) * canvasWidth + sourceX + column) * 4
                composeKittyPixel(
                    destination: &destination,
                    destinationIndex: destinationIndex,
                    source: source,
                    sourceIndex: sourceIndex,
                    overwrite: overwrite)
            }
        }
    }

    private func composeKittyPixel(
        destination: inout [UInt8],
        destinationIndex: Int,
        source: [UInt8],
        sourceIndex: Int,
        overwrite: Bool
    ) {
        if overwrite {
            destination[destinationIndex..<(destinationIndex + 4)] = source[sourceIndex..<(sourceIndex + 4)]
            return
        }
        let sourceAlpha = Int(source[sourceIndex + 3])
        if sourceAlpha == 0 { return }
        if sourceAlpha == 255 || destination[destinationIndex + 3] == 0 {
            destination[destinationIndex..<(destinationIndex + 4)] = source[sourceIndex..<(sourceIndex + 4)]
            return
        }
        let destinationAlpha = Int(destination[destinationIndex + 3])
        let inverseSourceAlpha = 255 - sourceAlpha
        let outputAlphaNumerator = sourceAlpha * 255 + destinationAlpha * inverseSourceAlpha
        let outputAlpha = (outputAlphaNumerator + 127) / 255
        for component in 0..<3 {
            let numerator = Int(source[sourceIndex + component]) * sourceAlpha * 255 +
                Int(destination[destinationIndex + component]) * destinationAlpha * inverseSourceAlpha
            destination[destinationIndex + component] = UInt8(
                min(255, (numerator + outputAlphaNumerator / 2) / outputAlphaNumerator))
        }
        destination[destinationIndex + 3] = UInt8(min(255, outputAlpha))
    }

    private func kittyRectanglesOverlap(
        x1: Int, y1: Int, x2: Int, y2: Int, width: Int, height: Int
    ) -> Bool {
        x1 < x2 + width && x2 < x1 + width && y1 < y2 + height && y2 < y1 + height
    }

    /// Advances active-screen animations using a monotonic timestamp.
    ///
    /// Tests can pass synthetic timestamps. The return value is the next
    /// monotonic deadline, or `nil` when no animation needs a timer.
    @discardableResult
    public func kittyGraphicsAdvanceAnimations(
        monotonicNanoseconds now: UInt64
    ) -> UInt64? {
        kittyGraphicsState.activeIsAlternate = isCurrentBufferAlternate
        let store = kittyGraphicsState.active
        var nextDeadline: UInt64?
        var changed = false
        for imageId in Array(store.imagesById.keys) {
            guard var image = store.imagesById[imageId],
                  var animation = image.animation,
                  animation.playbackState != .stopped,
                  animation.frames.count > 1,
                  store.placementsByKey.values.contains(where: { $0.imageId == imageId }),
                  animation.frames.contains(where: { $0.gapMilliseconds > 0 }),
                  animation.maxLoops == 0 || animation.currentLoop < animation.maxLoops else {
                continue
            }
            var imageChanged = false
            if animation.frameShownAtNanoseconds == nil {
                animation.frameShownAtNanoseconds = now
            } else if let shown = animation.frameShownAtNanoseconds, now < shown {
                // A deterministic clock can restart at a lower epoch. Re-anchor
                // without advancing, as Ghostty does after a clock restart.
                animation.frameShownAtNanoseconds = now
            }

            let shown = animation.frameShownAtNanoseconds ?? now
            let gap = UInt64(animation.frames[animation.currentIndex].gapMilliseconds) * 1_000_000
            var deadline = shown &+ gap
            if now >= deadline {
                var index = animation.currentIndex
                var canAdvance = true
                while true {
                    let candidate = (index + 1) % animation.frames.count
                    if candidate == 0 {
                        if animation.playbackState == .runningWait {
                            canAdvance = false
                            break
                        }
                        animation.currentLoop &+= 1
                        if animation.maxLoops > 0 && animation.currentLoop >= animation.maxLoops {
                            canAdvance = false
                            break
                        }
                    }
                    index = candidate
                    if animation.frames[index].gapMilliseconds > 0 { break }
                }
                if canAdvance {
                    animation.currentIndex = index
                    animation.frameShownAtNanoseconds = now
                    deadline = now &+ UInt64(animation.frames[index].gapMilliseconds) * 1_000_000
                    changed = true
                    imageChanged = true
                }
            }
            if deadline > now {
                nextDeadline = min(nextDeadline ?? deadline, deadline)
            }
            if imageChanged {
                image.contentGeneration = nextKittyGeneration()
            }
            image.animation = animation
            store.imagesById[imageId] = image
        }
        if changed {
            updateFullScreen()
        }
        return nextDeadline
    }

    private func scheduleKittyAnimationTimer() {
        kittyAnimationTimerSerial &+= 1
        let serial = kittyAnimationTimerSerial
        let now = DispatchTime.now().uptimeNanoseconds
        guard let deadline = kittyGraphicsAdvanceAnimations(monotonicNanoseconds: now) else { return }
        let workItem = DispatchWorkItem {
            self.terminalLock.withLock {
                guard self.kittyAnimationTimerSerial == serial else { return }
                _ = self.kittyGraphicsAdvanceAnimations(
                    monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
                self.scheduleKittyAnimationTimer()
            }
        }
        IOTimerQueue.shared.asyncAfter(
            deadline: .init(uptimeNanoseconds: deadline),
            execute: workItem)
    }

    /// Returns immutable Kitty graphics state for the active screen.
    ///
    /// Call this method while holding the terminal's existing lock. The
    /// returned value does not refer to mutable terminal storage.
    public func kittyGraphicsRenderSnapshot() -> KittyGraphicsRenderSnapshot {
        kittyGraphicsState.activeIsAlternate = isCurrentBufferAlternate
        let store = kittyGraphicsState.active
        var images: [UInt32: KittyGraphicsRenderImage] = [:]
        images.reserveCapacity(store.imagesById.count)

        for (imageId, image) in store.imagesById {
            let root: (bytes: [UInt8], width: Int, height: Int)
            switch image.payload {
            case .rgba(let bytes, let width, let height):
                root = (bytes, width, height)
            }
            let decoded: (bytes: [UInt8], width: Int, height: Int)
            if let animation = image.animation,
               animation.currentIndex >= 0,
               animation.currentIndex < animation.frames.count {
                decoded = (animation.frames[animation.currentIndex].rgba, root.width, root.height)
            } else {
                decoded = root
            }
            images[imageId] = KittyGraphicsRenderImage(
                imageId: imageId,
                imageNumber: image.imageNumber,
                width: decoded.width,
                height: decoded.height,
                rgba: Data(decoded.bytes),
                contentGeneration: image.contentGeneration)
        }

        let positions: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        var resolved: [KittyPlacementKey: (row: Int, col: Int)] = [:]
        var placements: [KittyGraphicsRenderPlacement] = []
        placements.reserveCapacity(store.placementsByKey.count)
        for (key, record) in store.placementsByKey {
            guard let image = images[record.imageId] else { continue }
            var visiting = Set<KittyPlacementKey>()
            guard let position = resolveKittyPlacementPosition(
                for: key,
                positions: positions,
                resolved: &resolved,
                visiting: &visiting) else { continue }

            let sourceX = max(0, min(record.sourceX, image.width))
            let sourceY = max(0, min(record.sourceY, image.height))
            let availableWidth = image.width - sourceX
            let availableHeight = image.height - sourceY
            let sourceWidth = max(0, min(record.sourceWidth > 0 ? record.sourceWidth : availableWidth, availableWidth))
            let sourceHeight = max(0, min(record.sourceHeight > 0 ? record.sourceHeight : availableHeight, availableHeight))
            guard sourceWidth > 0, sourceHeight > 0 else { continue }

            let placement = KittyGraphicsRenderPlacement(
                token: record.token,
                placementId: record.clientPlacementId,
                imageId: record.imageId,
                visibleSource: KittyGraphicsPixelRect(
                    x: sourceX, y: sourceY,
                    width: sourceWidth, height: sourceHeight),
                geometry: KittyGraphicsCellGeometry(
                    column: position.col,
                    row: position.row - buffer.yDisp,
                    columns: max(1, record.cols),
                    rows: max(1, record.rows)),
                pixelOffsetX: record.pixelOffsetX,
                pixelOffsetY: record.pixelOffsetY,
                zIndex: Int32(clamping: record.zIndex),
                isVirtual: record.isVirtual,
                insertionOrder: record.insertionOrder)
            placements.append(placement)
        }
        placements.sort {
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.insertionOrder < $1.insertionOrder
        }
        return KittyGraphicsRenderSnapshot(
            storageGeneration: store.generation,
            imagesById: images,
            placements: placements)
    }

    private func decompressZlib(_ data: Data) -> Data? {
#if canImport(Compression)
        // Apple's COMPRESSION_ZLIB decodes the raw DEFLATE member. Validate
        // and remove the RFC 1950 wrapper here, then verify its Adler-32.
        guard data.count >= 6 else { return nil }
        let cmf = data[data.startIndex]
        let flg = data[data.index(after: data.startIndex)]
        guard cmf & 0x0f == 8,
              cmf >> 4 <= 7,
              (Int(cmf) << 8 | Int(flg)) % 31 == 0,
              flg & 0x20 == 0 else { return nil }
        let checksumStart = data.index(data.endIndex, offsetBy: -4)
        let expectedChecksum = data[checksumStart..<data.endIndex].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        let deflateStart = data.index(data.startIndex, offsetBy: 2)
        let deflate = data[deflateStart..<checksumStart]
        guard !deflate.isEmpty else { return nil }

        var capacity = min(
            Terminal.kittyMaxImageBytes,
            max(64 * 1024, deflate.count * 2))
        while capacity > 0 {
            var output = [UInt8](repeating: 0, count: capacity)
            let outputCapacity = output.count
            let produced = deflate.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        outputCapacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        deflate.count,
                        nil,
                        COMPRESSION_ZLIB)
                }
            }
            guard produced > 0 else { return nil }
            if produced < capacity || capacity == Terminal.kittyMaxImageBytes {
                output.removeSubrange(produced..<output.count)
                guard kittyAdler32(output) == expectedChecksum else { return nil }
                return Data(output)
            }
            capacity = min(Terminal.kittyMaxImageBytes, capacity * 2)
        }
        return nil
#else
        #if canImport(LZ77)
        var inflator = LZ77.Inflator(format: .zlib)
        do {
            guard try inflator.push(Array(data)[...]) == nil else { return nil }
            let output = inflator.pull()
            guard output.count <= Terminal.kittyMaxImageBytes else { return nil }
            return Data(output)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
#endif
    }

    private func kittyAdler32(_ bytes: [UInt8]) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return (b << 16) | a
    }
}
