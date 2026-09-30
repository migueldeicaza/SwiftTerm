import SwiftTerm

final class WasmGraphicsState {
    var packet: [UInt8] = []
    #if !SWIFTTERM_EMBEDDED
    struct ImageInfo: Equatable {
        var id: UInt64; var generation: UInt64; var width: Int; var height: Int
    }
    struct Image {
        var info: ImageInfo
        var rgba: [UInt8]
    }
    struct Placement: Equatable {
        var image: UInt64
        var source: [Float]
        var destination: [Float]
        var z: Int32
        var flags: UInt32
        var token: UInt64
        var order: UInt64
    }
    var images: [ImageInfo] = []
    var placements: [Placement] = []
    var acknowledged: [UInt64: ImageInfo] = [:]
    var needsUpdate = true
    var generation: UInt64 = 0
    var acknowledgedGeneration: UInt64 = 0
    var inlineImages: [TerminalRasterImage] = []
    var inlineBytes = 0
    var nextInlineID: UInt32 = 0

    func insert(_ source: Terminal, bytes: [UInt8], width: Int, height: Int, cellWidth: Int, cellHeight: Int,
                widthRequest: ImageSizeRequest, heightRequest: ImageSizeRequest, preserveAspectRatio: Bool) {
        guard nextInlineID < UInt32.max else { return }
        nextInlineID += 1
        guard let image = TerminalRasterImage(id: nextInlineID, width: width, height: height, rgba: bytes) else { return }
        while (inlineBytes + bytes.count > 64 * 1024 * 1024 || inlineImages.count >= 4096), !inlineImages.isEmpty {
            let old = inlineImages.removeFirst()
            inlineBytes -= old.rgba.count
            old.discardPixels()
        }
        inlineImages.append(image); inlineBytes += bytes.count
        source.insertRasterImage(image, cellWidth: cellWidth, cellHeight: cellHeight,
                                 width: widthRequest, height: heightRequest, preserveAspectRatio: preserveAspectRatio)
    }

    func update(_ entry: TerminalEntry) -> Int32 {
        let terminal = entry.terminal
        let cw = Float(max(1, entry.host.cellWidth)), ch = Float(max(1, entry.host.cellHeight))
        let (kitty, inline, placeholders) = terminal.terminalLock.withLock {
            let kitty = terminal.kittyGraphicsRenderSnapshot()
            return (kitty, terminal.rasterImagePlacements(),
                    terminal.visibleKittyPlaceholderPlacements(snapshot: kitty,
                        cellWidth: max(1, entry.host.cellWidth), cellHeight: max(1, entry.host.cellHeight)))
        }
        var sourceImages: [UInt64: Image] = [:]
        var nextPlacements: [Placement] = []
        for item in kitty.placements where !item.isVirtual {
            guard let image = kitty.imagesById[item.imageId] else { continue }
            let id = UInt64(image.imageId)
            sourceImages[id] = Image(info: ImageInfo(id: id, generation: image.contentGeneration,
                                                    width: image.width, height: image.height), rgba: image.rgba)
            nextPlacements.append(Placement(
                image: id,
                source: [Float(item.visibleSource.x), Float(item.visibleSource.y), Float(item.visibleSource.width), Float(item.visibleSource.height)],
                destination: [Float(item.geometry.column) * cw + Float(item.pixelOffsetX),
                              Float(item.geometry.row) * ch + Float(item.pixelOffsetY),
                              max(0, Float(item.geometry.columns) * cw - Float(item.pixelOffsetX)), max(0, Float(item.geometry.rows) * ch - Float(item.pixelOffsetY))],
                z: item.zIndex, flags: item.isVirtual ? 1 : 0, token: item.token, order: item.insertionOrder
            ))
        }
        for item in placeholders {
            guard let image = kitty.imagesById[item.imageId] else { continue }
            let id = UInt64(image.imageId)
            sourceImages[id] = Image(info: ImageInfo(id: id, generation: image.contentGeneration,
                                                    width: image.width, height: image.height), rgba: image.rgba)
            nextPlacements.append(Placement(
                image: id,
                source: [Float(item.source.x), Float(item.source.y), Float(item.source.width), Float(item.source.height)],
                destination: [Float(item.destination.x), Float(item.destination.y), Float(item.destination.width), Float(item.destination.height)],
                z: 0, flags: 1, token: item.token, order: item.insertionOrder
            ))
        }
        for (index, item) in inline.enumerated() {
            let image = item.image
            let id = UInt64(image.id) | (UInt64(1) << 32)
            sourceImages[id] = Image(info: ImageInfo(id: id, generation: 1, width: image.width, height: image.height), rgba: image.rgba)
            nextPlacements.append(Placement(
                image: id, source: [0, Float(item.sourceY), Float(image.width), Float(item.sourceHeight)],
                destination: [Float(item.column) * cw, Float(item.row) * ch, Float(item.width), Float(item.height)],
                z: 0, flags: 2, token: UInt64(index), order: UInt64(index)
            ))
        }
        let sortedImages = sourceImages.values.sorted { $0.info.id < $1.info.id }
        let nextImages = sortedImages.map(\.info)
        if !needsUpdate && nextImages == images && nextPlacements == placements && generation != 0 {
            return generation == acknowledgedGeneration ? 0 : 1
        }
        guard sortedImages.count <= 65536, nextPlacements.count <= 262144, generation < UInt64.max else {
            return entry.fail(ABI.outOfMemory, "The graphics snapshot exceeds its record limit.")
        }
        let placementOffset = 32 + sortedImages.count * 32
        var total = placementOffset + nextPlacements.count * 64
        for image in sortedImages where acknowledged[image.info.id] != image.info {
            guard image.rgba.count <= ABI.maximumSnapshot - total else {
                return entry.fail(ABI.outOfMemory, "The graphics snapshot exceeds 256 MiB.")
            }
            total += image.rgba.count
        }
        generation += 1
        var bytes = [UInt8](repeating: 0, count: total)
        bytes.put32(0x58475453, at: 0) // STGX
        bytes.put16(1, at: 4); bytes.put16(32, at: 6)
        bytes.put64(generation, at: 8)
        bytes.put32(UInt32(sortedImages.count), at: 16)
        bytes.put32(UInt32(nextPlacements.count), at: 20)
        bytes.put32(32, at: 24); bytes.put32(UInt32(placementOffset), at: 28)
        var offset = placementOffset + nextPlacements.count * 64
        for (index, image) in sortedImages.enumerated() {
            let at = 32 + index * 32
            bytes.put64(image.info.id, at: at); bytes.put64(image.info.generation, at: at + 8)
            bytes.put32(UInt32(image.info.width), at: at + 16); bytes.put32(UInt32(image.info.height), at: at + 20)
            let changed = acknowledged[image.info.id] != image.info
            bytes.put32(UInt32(offset), at: at + 24)
            bytes.put32(changed ? UInt32(image.rgba.count) : 0, at: at + 28)
            if changed {
                bytes.replaceSubrange(offset..<(offset + image.rgba.count), with: image.rgba)
                offset += image.rgba.count
            }
        }
        for (index, item) in nextPlacements.enumerated() {
            let at = placementOffset + index * 64
            bytes.put64(item.image, at: at)
            for (part, value) in (item.source + item.destination).enumerated() {
                bytes.put32(value.bitPattern, at: at + 8 + part * 4)
            }
            bytes.put32(UInt32(bitPattern: item.z), at: at + 40)
            bytes.put32(item.flags, at: at + 44)
            bytes.put64(item.token, at: at + 48); bytes.put64(item.order, at: at + 56)
        }
        packet = bytes; images = nextImages; placements = nextPlacements; needsUpdate = false
        return 1
    }

    func reset() {
        needsUpdate = true
        for image in inlineImages { image.discardPixels() }
        inlineImages.removeAll(); inlineBytes = 0
        // Keep the generation and IDs monotonic across reset.
        images.removeAll(); placements.removeAll(); acknowledged.removeAll()
        packet.removeAll(); acknowledgedGeneration = 0
        if generation < UInt64.max { generation += 1 }
    }

    func clean(low: UInt32, high: UInt32) -> Int32 {
        guard (UInt64(low) | UInt64(high) << 32) == generation else { return ABI.staleGeneration }
        acknowledged = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        acknowledgedGeneration = generation
        packet = []
        return ABI.ok
    }
    #endif
}

extension Array where Element == UInt8 {
    mutating func put64(_ value: UInt64, at offset: Int) {
        put32(UInt32(truncatingIfNeeded: value), at: offset)
        put32(UInt32(truncatingIfNeeded: value >> 32), at: offset + 4)
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_graphics_update")
#endif
public func graphicsUpdate(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { entry in
        #if !SWIFTTERM_EMBEDDED
        return entry.host.graphics.update(entry)
        #else
        return ABI.unsupported
        #endif
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_graphics_snapshot_size")
#endif
public func graphicsSnapshotSize(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { Int32($0.host.graphics.packet.count) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_graphics_snapshot_copy")
#endif
public func graphicsSnapshotCopy(_ terminal: UInt32, _ destination: UInt32, _ capacity: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    return runtime.withTerminal(terminal) { runtime.copy($0, $0.host.graphics.packet[...], destination, capacity) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_graphics_clean")
#endif
public func graphicsClean(_ terminal: UInt32, _ low: UInt32, _ high: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { entry in
        #if !SWIFTTERM_EMBEDDED
        return entry.host.graphics.clean(low: low, high: high)
        #else
        return ABI.unsupported
        #endif
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_poll")
#endif
public func terminalPoll(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { $0.poll() }
}

extension TerminalEntry {
    func poll() -> Int32 {
        var updated = false
        #if !SWIFTTERM_EMBEDDED
        host.clipboard.expire()
        #if os(WASI)
        let synchronizedBeforePoll = terminal.synchronizedOutputActive
        updated = terminal.pollHostEvents()
        if synchronizedBeforePoll && !terminal.synchronizedOutputActive { host.event(12) }
        if terminal.takeHostEventOverflow() { host.queueFailure = true }
        #endif
        #endif
        if let deadline = host.synchronizedOutputDeadline, monotonicMilliseconds() >= deadline {
            host.synchronizedOutputDeadline = nil
            terminal.expireSynchronizedOutput()
            host.event(12)
            updated = true
        }
        if updated {
            guard canMutate() else { return fail(ABI.internalError, "The state revision is exhausted.") }
            changed()
        }
        if host.queueFailure { return fail(ABI.outOfMemory, "The host event queue overflowed. Reset the terminal.") }
        return updated ? 1 : 0
    }
}

extension WasmTerminalHost {
    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        #if !SWIFTTERM_EMBEDDED
        graphics.insert(source, bytes: bytes, width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight,
                        widthRequest: width > source.cols * cellWidth ? .percent(100) : .auto,
                        heightRequest: .auto, preserveAspectRatio: true)
        forceFull = true
        #endif
    }
    func createImage(source: Terminal, data: TerminalData, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool) {
        #if !SWIFTTERM_EMBEDDED
        guard let decoded = source.decodeTerminalImage(data) else { return }
        graphics.insert(source, bytes: decoded.bytes, width: decoded.width, height: decoded.height,
                        cellWidth: cellWidth, cellHeight: cellHeight,
                        widthRequest: width, heightRequest: height, preserveAspectRatio: preserveAspectRatio)
        forceFull = true
        #endif
    }
}
