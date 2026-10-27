//
//  ImageContainer.swift
//
// Reads the container format and the frame count of an image file, before
// ImageIO opens the file.
//
#if !SWIFTTERM_EMBEDDED

/// The container format of an image file, and the number of frames in it.
///
/// This reads only the structure of the file, not the pixels. ImageIO reads
/// every frame of some formats before it returns the first frame. On macOS
/// 27, a 48 MB TIFF file with 244,000 pages takes 10.6 s, and the time grows
/// with the square of the page count. A GIF file with 2.2 million frames
/// takes 3.5 s, and a HEIC file with 16,000 items takes 1 s. For this reason,
/// the image paths count the frames here, and reject a file before ImageIO
/// opens it. A HEIF item costs more than a frame of the other formats, so
/// HEIF files also have a smaller limit for the items.
///
/// Only the formats in ``Format`` are accepted. They are the usual formats for
/// photos, screenshots and animations. The other ImageIO formats (camera raw
/// files, OpenEXR, DICOM, Photoshop and more) are rejected, because their
/// decoders are large and their cost is not known.
struct ImageContainer: Equatable {
    enum Format: Equatable {
        case png
        case jpeg
        case gif
        case tiff
        case webp
        case bmp
        /// HEIF and the formats that use its structure: HEIC, AVIF, and their
        /// image sequences.
        case heif
    }

    static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    let format: Format
    /// The number of frames, pages or items in the file. For HEIF, this is
    /// the number of items and the number of samples in the tracks.
    let frames: Int

    /// Reads the format and the frame count.
    ///
    /// Returns nil if the format is not supported, if the structure is not
    /// correct, if the file has more than `maxFrames` frames, or if a HEIF
    /// file has more than `maxHeifItems` items.
    init?(_ bytes: UnsafeRawBufferPointer, maxFrames: Int, maxHeifItems: Int = ImageLimits.maxHeifItems) {
        let reader = Reader(bytes: bytes, littleEndian: false)
        let frames: Int?
        if reader.matches(0, Self.pngSignature) {
            format = .png
            frames = Self.pngFrames(reader)
        } else if reader.matches(0, [0xFF, 0xD8, 0xFF]) {
            format = .jpeg
            frames = 1
        } else if reader.matches(0, Array("GIF87a".utf8)) || reader.matches(0, Array("GIF89a".utf8)) {
            format = .gif
            frames = Self.gifFrames(reader, maxFrames: maxFrames)
        } else if reader.matches(0, Array("II".utf8)) || reader.matches(0, Array("MM".utf8)) {
            format = .tiff
            frames = Self.tiffFrames(Reader(bytes: bytes, littleEndian: reader.matches(0, Array("II".utf8))),
                                     maxFrames: maxFrames)
        } else if reader.matches(0, Array("RIFF".utf8)) && reader.matches(8, Array("WEBP".utf8)) {
            format = .webp
            frames = Self.webpFrames(Reader(bytes: bytes, littleEndian: true), maxFrames: maxFrames)
        } else if reader.matches(0, Array("BM".utf8)) {
            format = .bmp
            frames = 1
        } else if reader.matches(4, Array("ftyp".utf8)) {
            format = .heif
            frames = Self.heifFrames(reader, maxFrames: maxFrames, maxItems: maxHeifItems)
        } else {
            return nil
        }
        guard let frames, frames >= 1, frames <= maxFrames else {
            return nil
        }
        self.frames = frames
    }

    /// Reads the size and the sample layout from the header (IHDR) of a PNG
    /// file. Returns nil if the header is not correct.
    ///
    /// The bytes for each pixel are for the larger of the PNG samples and the
    /// RGBA8 output. This is not the peak memory of the decoder.
    static func pngHeader(_ bytes: UnsafeRawBufferPointer) -> (width: Int, height: Int, bytesPerPixel: Int)? {
        let reader = Reader(bytes: bytes, littleEndian: false)
        guard bytes.count >= 33, reader.matches(0, pngSignature),
              reader.matches(8, [0, 0, 0, 13, 73, 72, 68, 82]),
              let width = reader.uint(16, 4), let height = reader.uint(20, 4),
              let depth = reader.u8(24), let colorType = reader.u8(25) else {
            return nil
        }
        let channels: Int
        switch (colorType, depth) {
        case (0, 1), (0, 2), (0, 4), (0, 8), (0, 16): channels = 1
        case (2, 8), (2, 16): channels = 3
        case (3, 1), (3, 2), (3, 4), (3, 8): channels = 1
        case (4, 8), (4, 16): channels = 2
        case (6, 8), (6, 16): channels = 4
        default: return nil
        }
        return (width, height, bytesPerPixel(samples: channels, depth: depth))
    }

    /// Returns the bytes for each pixel of a decoded image: the larger of the
    /// samples and RGBA8.
    ///
    /// - Parameters:
    ///   - samples: the number of samples in one pixel.
    ///   - depth: the number of bits in one sample.
    static func bytesPerPixel(samples: Int, depth: Int) -> Int {
        max(4, (samples * depth + 7) / 8)
    }

    // MARK: - Frame counts

    /// An APNG file gives its frame count in the acTL chunk, before the image
    /// data. A PNG file without acTL has one frame.
    private static func pngFrames(_ reader: Reader) -> Int? {
        var offset = pngSignature.count
        while let length = reader.uint(offset, 4), let type = reader.uint(offset + 4, 4) {
            if type == fourCC("acTL") {
                return reader.uint(offset + 8, 4).map { max(1, $0) }
            }
            if type == fourCC("IDAT") {
                break
            }
            guard let next = ImageLimits.sum(offset, 12, length) else {
                break
            }
            offset = next
        }
        return 1
    }

    /// Counts the image descriptors. ImageIO stops at the trailer and at an
    /// unknown byte, also when more frames follow that byte. This count stops
    /// at the same places.
    private static func gifFrames(_ reader: Reader, maxFrames: Int) -> Int? {
        guard let packed = reader.u8(10) else {
            return nil
        }
        var offset = 13
        if packed & 0x80 != 0 {
            offset += 3 << ((packed & 7) + 1)
        }
        // Returns false if the file ends before the last sub-block.
        func skipSubBlocks() -> Bool {
            while let size = reader.u8(offset) {
                offset += 1
                if size == 0 {
                    return true
                }
                offset += size
            }
            return false
        }
        var frames = 0
        blocks: while let introducer = reader.u8(offset) {
            switch introducer {
            case 0x2C:
                frames += 1
                guard frames <= maxFrames else {
                    return nil
                }
                guard let local = reader.u8(offset + 9) else {
                    break blocks
                }
                offset += 10
                if local & 0x80 != 0 {
                    offset += 3 << ((local & 7) + 1)
                }
                // The minimum code size of the image data.
                offset += 1
                guard skipSubBlocks() else {
                    break blocks
                }
            case 0x21:
                offset += 2
                guard skipSubBlocks() else {
                    break blocks
                }
            default:
                // The trailer (0x3B), or a byte that is not a block.
                break blocks
            }
        }
        return frames
    }

    /// Follows the chain of image file directories (IFD). ImageIO cannot read
    /// a directory past the end of the file, so the count stops there. A
    /// chain with a loop is rejected.
    private static func tiffFrames(_ reader: Reader, maxFrames: Int) -> Int? {
        let isBigTIFF: Bool
        var offset: Int
        switch reader.uint(2, 2) {
        case 42:
            isBigTIFF = false
            guard let first = reader.uint(4, 4) else {
                return nil
            }
            offset = first
        case 43:
            // BigTIFF: 8-byte offsets.
            guard reader.uint(4, 2) == 8, reader.uint(6, 2) == 0, let first = reader.uint(8, 8) else {
                return nil
            }
            isBigTIFF = true
            offset = first
        default:
            return nil
        }
        let countSize = isBigTIFF ? 8 : 2
        let entrySize = isBigTIFF ? 20 : 12
        let offsetSize = isBigTIFF ? 8 : 4
        var visited = Set<Int>()
        var frames = 0
        while offset != 0 {
            guard visited.insert(offset).inserted else {
                return nil
            }
            guard let entries = reader.uint(offset, countSize) else {
                break
            }
            frames += 1
            guard frames <= maxFrames else {
                return nil
            }
            guard let entriesSize = ImageLimits.product(entries, entrySize),
                  let nextOffset = ImageLimits.sum(offset, countSize, entriesSize),
                  let next = reader.uint(nextOffset, offsetSize) else {
                break
            }
            offset = next
        }
        return frames
    }

    /// Counts the animation frames (ANMF chunks). A WebP file without ANMF
    /// chunks has one frame.
    private static func webpFrames(_ reader: Reader, maxFrames: Int) -> Int? {
        var offset = 12
        var frames = 0
        while let size = reader.uint(offset + 4, 4), let type = reader.uint(offset, 4) {
            // `type` is little endian here. Compare with the reversed name.
            if type == fourCC("FMNA") {
                frames += 1
                guard frames <= maxFrames else {
                    return nil
                }
            }
            // A chunk with an odd size has one byte of padding.
            guard let next = ImageLimits.sum(offset, 8, size, size & 1) else {
                break
            }
            offset = next
        }
        return max(1, frames)
    }

    /// Counts the items (iinf) and the samples of each track. ImageIO reads
    /// all of them when it opens the file.
    ///
    /// A track gives its samples in the sample table (stsz or stz2). A
    /// fragmented track gives more samples in each fragment (trun). This
    /// count includes both.
    private static func heifFrames(_ reader: Reader, maxFrames: Int, maxItems: Int) -> Int? {
        var frames = 0
        var items = 0
        var isOverLimit = false
        // Returns false when a count is more than its limit.
        func count(_ value: Int?, isItems: Bool = false) -> Bool {
            let value = value ?? 0
            let (sum, overflow) = frames.addingReportingOverflow(value)
            guard !overflow else {
                isOverLimit = true
                return false
            }
            frames = sum
            if isItems {
                // `frames` includes `items`, so this sum does not overflow.
                items += value
            }
            isOverLimit = frames > maxFrames || items > maxItems
            return !isOverLimit
        }
        // Counts the samples in the boxes at the end of `path`. `offsets`
        // gives the position of the sample count in each type of box, after
        // the version and the flags.
        func countSamples(_ payload: Range<Int>, path: ArraySlice<Int>, offsets: [Int: Int]) -> Bool {
            forEachBox(reader, payload) { type, payload in
                if let next = path.first {
                    return type != next || countSamples(payload, path: path.dropFirst(), offsets: offsets)
                }
                guard let offset = offsets[type] else {
                    return true
                }
                return count(reader.uint(payload.lowerBound + 4 + offset, 4))
            }
            return !isOverLimit
        }
        forEachBox(reader, 0..<reader.bytes.count) { type, payload in
            if type == fourCC("meta") {
                // meta is a full box: the version and the flags come first.
                forEachBox(reader, (payload.lowerBound + 4)..<max(payload.lowerBound + 4, payload.upperBound)) { type, payload in
                    guard type == fourCC("iinf"), let version = reader.u8(payload.lowerBound) else {
                        return true
                    }
                    return count(reader.uint(payload.lowerBound + 4, version == 0 ? 2 : 4), isItems: true)
                }
            } else if type == fourCC("moov") {
                // stsz has the sample size, and stz2 has the field size. Then
                // both have the sample count.
                _ = countSamples(payload, path: [fourCC("trak"), fourCC("mdia"), fourCC("minf"), fourCC("stbl")],
                                 offsets: [fourCC("stsz"): 4, fourCC("stz2"): 4])
            } else if type == fourCC("moof") {
                // trun starts with the sample count.
                _ = countSamples(payload, path: [fourCC("traf")], offsets: [fourCC("trun"): 0])
            }
            return !isOverLimit
        }
        return isOverLimit ? nil : frames
    }

    /// Calls `body` for each ISO base media box in `range`, with the box type
    /// and the range of the box content. Stops when `body` returns false, or
    /// when a box header is not correct. A box that continues past the end of
    /// `range` ends at the end of `range`.
    private static func forEachBox(_ reader: Reader, _ range: Range<Int>,
                                   _ body: (_ type: Int, _ payload: Range<Int>) -> Bool) {
        var offset = range.lowerBound
        while range.upperBound - offset >= 8,
              let size32 = reader.uint(offset, 4), let type = reader.uint(offset + 4, 4) {
            var headerSize = 8
            var size = size32
            if size32 == 1 {
                guard let largeSize = reader.uint(offset + 8, 8) else {
                    return
                }
                headerSize = 16
                size = largeSize
            } else if size32 == 0 {
                size = range.upperBound - offset
            }
            guard size >= headerSize, headerSize <= range.upperBound - offset else {
                return
            }
            let end = size > range.upperBound - offset ? range.upperBound : offset + size
            guard body(type, (offset + headerSize)..<end) else {
                return
            }
            offset = end
        }
    }

    /// Returns the four ASCII characters as a big endian number.
    private static func fourCC(_ name: StaticString) -> Int {
        name.withUTF8Buffer { $0.reduce(0) { $0 << 8 | Int($1) } }
    }

    /// Reads numbers from the file. Each read returns nil if it is past the end.
    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        let littleEndian: Bool

        func u8(_ offset: Int) -> Int? {
            guard offset >= 0, offset < bytes.count else {
                return nil
            }
            return Int(bytes[offset])
        }

        /// Reads an unsigned number of `size` bytes. Returns nil if the number
        /// is past the end, or if it is larger than `Int.max`.
        func uint(_ offset: Int, _ size: Int) -> Int? {
            guard offset >= 0, size <= bytes.count, offset <= bytes.count - size else {
                return nil
            }
            var value: UInt64 = 0
            for index in 0..<size {
                let byte = bytes[littleEndian ? offset + size - 1 - index : offset + index]
                value = value << 8 | UInt64(byte)
            }
            return Int(exactly: value)
        }

        func matches(_ offset: Int, _ signature: [UInt8]) -> Bool {
            guard offset >= 0, signature.count <= bytes.count, offset <= bytes.count - signature.count else {
                return false
            }
            return signature.indices.allSatisfy { bytes[offset + $0] == signature[$0] }
        }
    }
}
#endif
