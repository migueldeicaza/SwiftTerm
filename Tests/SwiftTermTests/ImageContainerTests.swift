#if !SWIFTTERM_EMBEDDED
import Testing

@testable import SwiftTerm

/// The format and the frame count of an image file, read before ImageIO
/// opens the file.
struct ImageContainerTests {
    private func scan(_ bytes: [UInt8], maxFrames: Int = 100,
                      maxHeifItems: Int = ImageLimits.maxHeifItems) -> ImageContainer? {
        bytes.withUnsafeBytes { ImageContainer($0, maxFrames: maxFrames, maxHeifItems: maxHeifItems) }
    }

    private func u16(_ value: Int, littleEndian: Bool = false) -> [UInt8] {
        let bytes = [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        return littleEndian ? bytes.reversed() : bytes
    }

    private func u32(_ value: Int, littleEndian: Bool = false) -> [UInt8] {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return littleEndian ? bytes.reversed() : bytes
    }

    private func u64(_ value: Int, littleEndian: Bool = false) -> [UInt8] {
        let bytes = [56, 48, 40, 32, 24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return littleEndian ? bytes.reversed() : bytes
    }

    @Test func singleFrameFormats() {
        #expect(scan([0xFF, 0xD8, 0xFF, 0xE0])?.format == .jpeg)
        #expect(scan([0xFF, 0xD8, 0xFF, 0xE0])?.frames == 1)
        #expect(scan(Array("BM".utf8) + [0, 0])?.format == .bmp)
    }

    @Test func rejectsOtherData() {
        #expect(scan([]) == nil)
        #expect(scan(Array("not an image".utf8)) == nil)
        #expect(scan(Array("%PDF-1.4".utf8)) == nil)
        #expect(scan(Array("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)) == nil)
        // Netpbm. ImageIO can read it, but it is not a supported format.
        #expect(scan(Array("P1\n1 1\n1\n".utf8)) == nil)
    }

    // MARK: - PNG

    private func chunk(_ type: String, _ data: [UInt8] = []) -> [UInt8] {
        u32(data.count) + Array(type.utf8) + data + [0, 0, 0, 0]
    }

    private func png(width: Int = 1, height: Int = 1, depth: UInt8 = 8, colorType: UInt8 = 6,
                     extra: [UInt8] = []) -> [UInt8] {
        ImageContainer.pngSignature + chunk("IHDR", u32(width) + u32(height) + [depth, colorType, 0, 0, 0])
            + extra + chunk("IDAT", [0]) + chunk("IEND")
    }

    @Test func pngCountsTheAnimationFrames() {
        #expect(scan(png())?.format == .png)
        #expect(scan(png())?.frames == 1)
        #expect(scan(png(extra: chunk("acTL", u32(5) + u32(0))))?.frames == 5)
        #expect(scan(png(extra: chunk("acTL", u32(100) + u32(0))))?.frames == 100)
        #expect(scan(png(extra: chunk("acTL", u32(101) + u32(0)))) == nil)
        // A zero frame count is not correct. ImageIO shows the default image.
        #expect(scan(png(extra: chunk("acTL", u32(0) + u32(0))))?.frames == 1)
    }

    @Test func pngHeaderGivesTheSizeAndTheSampleLayout() throws {
        let rgba16 = try #require(png(width: 300, height: 200, depth: 16).withUnsafeBytes { ImageContainer.pngHeader($0) })
        #expect(rgba16.width == 300 && rgba16.height == 200 && rgba16.bytesPerPixel == 8)
        let gray = try #require(png(depth: 1, colorType: 0).withUnsafeBytes { ImageContainer.pngHeader($0) })
        #expect(gray.bytesPerPixel == 4)
        // A palette cannot have 16-bit samples.
        #expect(png(depth: 16, colorType: 3).withUnsafeBytes { ImageContainer.pngHeader($0) } == nil)
        #expect(Array(png().prefix(24)).withUnsafeBytes { ImageContainer.pngHeader($0) } == nil)
    }

    // MARK: - GIF

    private func gif(frames: Int, trailer: Bool = true) -> [UInt8] {
        // 1 × 1, with a global color table of two colors.
        var bytes = Array("GIF89a".utf8) + [1, 0, 1, 0, 0x80, 0, 0] + [0, 0, 0, 255, 255, 255]
        for _ in 0..<frames {
            bytes += [0x21, 0xF9, 4, 0, 10, 0, 0, 0]
            // An image descriptor with a local color table, then the image data.
            bytes += [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x80, 0, 0, 0, 255, 255, 255]
            bytes += [2, 2, 0x44, 0x01, 0]
        }
        return trailer ? bytes + [0x3B] : bytes
    }

    @Test func gifCountsTheFrames() {
        #expect(scan(gif(frames: 1))?.format == .gif)
        #expect(scan(gif(frames: 1))?.frames == 1)
        #expect(scan(gif(frames: 100))?.frames == 100)
        #expect(scan(gif(frames: 101)) == nil)
        #expect(scan(gif(frames: 0)) == nil)
    }

    @Test func gifStopsAtTheTrailerOrTheEnd() {
        // ImageIO ignores the frames after the trailer.
        #expect(scan(gif(frames: 1) + gif(frames: 500).dropFirst(19))?.frames == 1)
        #expect(scan(gif(frames: 2, trailer: false))?.frames == 2)
        #expect(scan(Array(gif(frames: 2).dropLast(3)))?.frames == 2)
    }

    @Test func gifStopsAtAnUnknownByte() {
        // ImageIO ignores the frames after a byte that is not a block.
        // InlineImageTests.imageIOStopsAtAnUnknownGIFByte checks this.
        for junk: [UInt8] in [[0x99], [0x00], [0x0D, 0x0A]] {
            #expect(scan(gif(frames: 2, trailer: false) + junk + gif(frames: 500).dropFirst(19))?.frames == 2)
        }
        #expect(scan(gif(frames: 0, trailer: false) + [0x99]) == nil)
    }

    // MARK: - TIFF

    /// Makes a chain of directories with one entry each. `next` gives the
    /// offset of the next directory for each index, or nil for the default.
    private func tiff(directories: Int, littleEndian: Bool = true, bigTIFF: Bool = false,
                      next: (Int) -> Int? = { _ in nil }) -> [UInt8] {
        let order = Array((littleEndian ? "II" : "MM").utf8)
        var bytes: [UInt8]
        let directorySize: Int
        if bigTIFF {
            bytes = order + u16(43, littleEndian: littleEndian) + u16(8, littleEndian: littleEndian)
                + u16(0, littleEndian: littleEndian) + u64(16, littleEndian: littleEndian)
            directorySize = 8 + 20 + 8
        } else {
            bytes = order + u16(42, littleEndian: littleEndian) + u32(8, littleEndian: littleEndian)
            directorySize = 2 + 12 + 4
        }
        let first = bytes.count
        for index in 0..<directories {
            let following = next(index) ?? (index == directories - 1 ? 0 : first + (index + 1) * directorySize)
            if bigTIFF {
                bytes += u64(1, littleEndian: littleEndian)
                bytes += u16(256, littleEndian: littleEndian) + u16(3, littleEndian: littleEndian)
                    + u64(1, littleEndian: littleEndian) + u64(1, littleEndian: littleEndian)
                bytes += u64(following, littleEndian: littleEndian)
            } else {
                bytes += u16(1, littleEndian: littleEndian)
                bytes += u16(256, littleEndian: littleEndian) + u16(3, littleEndian: littleEndian)
                    + u32(1, littleEndian: littleEndian) + u32(1, littleEndian: littleEndian)
                bytes += u32(following, littleEndian: littleEndian)
            }
        }
        return bytes
    }

    @Test func tiffCountsTheDirectories() {
        #expect(scan(tiff(directories: 1))?.format == .tiff)
        #expect(scan(tiff(directories: 5))?.frames == 5)
        #expect(scan(tiff(directories: 5, littleEndian: false))?.frames == 5)
        #expect(scan(tiff(directories: 5, bigTIFF: true))?.frames == 5)
        #expect(scan(tiff(directories: 5, littleEndian: false, bigTIFF: true))?.frames == 5)
        #expect(scan(tiff(directories: 100))?.frames == 100)
        #expect(scan(tiff(directories: 101)) == nil)
    }

    @Test func tiffRejectsALoop() {
        #expect(scan(tiff(directories: 3, next: { $0 == 2 ? 8 : nil })) == nil)
        #expect(scan(tiff(directories: 1, next: { _ in 8 })) == nil)
    }

    @Test func tiffStopsAtADirectoryPastTheEnd() {
        #expect(scan(tiff(directories: 2, next: { $0 == 1 ? 1_000_000 : nil }))?.frames == 2)
        #expect(scan(tiff(directories: 2, next: { $0 == 1 ? Int.max : nil }))?.frames == 2)
        // The first directory is past the end: there is no frame.
        #expect(scan(Array("II".utf8) + u16(42, littleEndian: true) + u32(1_000, littleEndian: true)) == nil)
        #expect(scan(Array("II".utf8) + u16(44, littleEndian: true) + u32(8, littleEndian: true)) == nil)
    }

    // MARK: - WebP

    private func riffChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        Array(type.utf8) + u32(data.count, littleEndian: true) + data + (data.count % 2 == 1 ? [0] : [])
    }

    private func webp(_ chunks: [UInt8]) -> [UInt8] {
        Array("RIFF".utf8) + u32(chunks.count + 4, littleEndian: true) + Array("WEBP".utf8) + chunks
    }

    @Test func webpCountsTheAnimationFrames() {
        #expect(scan(webp(riffChunk("VP8L", [0x2F, 0, 0, 0, 0])))?.format == .webp)
        #expect(scan(webp(riffChunk("VP8L", [0x2F, 0, 0, 0, 0])))?.frames == 1)
        let header = riffChunk("VP8X", [2] + [UInt8](repeating: 0, count: 9)) + riffChunk("ANIM", [0, 0, 0, 0, 0, 0])
        // The odd size makes a padding byte after each frame.
        let frame = riffChunk("ANMF", [UInt8](repeating: 0, count: 17))
        #expect(scan(webp(header + Array([[UInt8]](repeating: frame, count: 3).joined())))?.frames == 3)
        #expect(scan(webp(header + Array([[UInt8]](repeating: frame, count: 101).joined()))) == nil)
    }

    // MARK: - HEIF

    private func box(_ type: String, _ content: [UInt8]) -> [UInt8] {
        u32(8 + content.count) + Array(type.utf8) + content
    }

    private func fullBox(_ type: String, version: UInt8 = 0, _ content: [UInt8]) -> [UInt8] {
        box(type, [version, 0, 0, 0] + content)
    }

    private let ftyp: [UInt8] = [0, 0, 0, 16] + Array("ftypheic".utf8) + [0, 0, 0, 0]

    private func items(_ count: Int, version: UInt8 = 0) -> [UInt8] {
        fullBox("meta", [UInt8](box("hdlr", [0])) + fullBox("iinf", version: version,
                                                             version == 0 ? u16(count) : u32(count)))
    }

    private func track(samples: Int, compact: Bool = false) -> [UInt8] {
        let sizes = compact ? fullBox("stz2", [0, 0, 0, 16] + u32(samples)) : fullBox("stsz", u32(0) + u32(samples))
        return box("trak", box("mdia", box("minf", box("stbl", sizes))))
    }

    @Test func heifCountsTheItems() {
        #expect(scan(ftyp + items(1))?.format == .heif)
        #expect(scan(ftyp + items(3))?.frames == 3)
        #expect(scan(ftyp + items(100, version: 1))?.frames == 100)
        #expect(scan(ftyp + items(70_000, version: 1)) == nil)
        #expect(scan(ftyp + items(70_000, version: 1), maxFrames: 100_000, maxHeifItems: 100_000)?.frames == 70_000)
        #expect(scan(ftyp) == nil)
    }

    @Test func heifHasASmallerLimitForTheItems() {
        let limit = ImageLimits.maxHeifItems
        #expect(scan(ftyp + items(limit), maxFrames: 10_000)?.frames == limit)
        #expect(scan(ftyp + items(limit + 1), maxFrames: 10_000) == nil)
        // The limit applies to the items of all the meta boxes.
        #expect(scan(ftyp + items(limit / 2 + 1) + items(limit / 2), maxFrames: 10_000) == nil)
        // The samples of a track are not items.
        #expect(scan(ftyp + items(1) + box("moov", track(samples: limit * 2)), maxFrames: 10_000)?.frames == limit * 2 + 1)
    }

    @Test func heifCountsTheSamplesOfEachTrack() {
        #expect(scan(ftyp + items(1) + box("moov", track(samples: 7)))?.frames == 8)
        #expect(scan(ftyp + items(1) + box("moov", track(samples: 7, compact: true) + track(samples: 2)))?.frames == 10)
        #expect(scan(ftyp + items(1) + box("moov", track(samples: 100))) == nil)
        // A sample box outside the track path is not counted.
        #expect(scan(ftyp + items(1) + box("moov", fullBox("stsz", u32(0) + u32(500))))?.frames == 1)
    }

    private func fragment(samples: Int) -> [UInt8] {
        box("moof", fullBox("mfhd", u32(1)) + box("traf", fullBox("tfhd", u32(1)) + fullBox("trun", u32(samples))))
    }

    @Test func heifCountsTheSamplesOfEachFragment() {
        #expect(scan(ftyp + items(1) + box("moov", track(samples: 0)) + fragment(samples: 30)
                     + fragment(samples: 40))?.frames == 71)
        #expect(scan(ftyp + items(1) + box("moov", track(samples: 0)) + fragment(samples: 100)) == nil)
        // A trun box outside a traf box is not counted.
        #expect(scan(ftyp + items(1) + box("moof", fullBox("trun", u32(500))))?.frames == 1)
    }

    @Test func heifReadsLargeAndOpenSizes() {
        // A size of 1 puts a 64-bit size after the type.
        let meta = items(4)
        let large = u32(1) + Array("meta".utf8) + u64(16 + meta.count - 8) + Array(meta.dropFirst(8))
        #expect(scan(ftyp + large)?.frames == 4)
        // A size of 0 continues to the end of the file.
        #expect(scan(ftyp + u32(0) + Array(items(5).dropFirst(4)))?.frames == 5)
        // A box that is shorter than its header stops the walk.
        #expect(scan(ftyp + u32(4) + Array("meta".utf8) + items(5)) == nil)
    }
}
#endif
