//
//  ByteRunScanner.swift
//  SwiftTerm
//

/// Finds byte boundaries in terminal input without allocating or copying data.
internal enum ByteRunScanner {
    private typealias ByteVector = SIMD16<UInt8>

    private static let vectorWidth = ByteVector.scalarCount
    private static let space = ByteVector(repeating: 0x20)
    private static let nonASCII = ByteVector(repeating: 0x80)

    /// Returns the first index whose byte is below 0x20.
    /// Returns `bytes.endIndex` when all remaining bytes are 0x20 or higher.
    @inline(__always)
    static func firstC0Byte(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        precondition(start >= bytes.startIndex && start <= bytes.endIndex)
#if compiler(>=6.4)
        let baseIndex = bytes.startIndex
        let offset = firstC0Byte(in: bytes.span, from: start - baseIndex)
        return baseIndex + offset
#else
        return legacyFirstC0Byte(in: bytes, from: start)
#endif
    }

    /// Returns the first index whose byte is below 0x20.
    /// Returns `bytes.count` when all remaining bytes are 0x20 or higher.
    @inline(__always)
    static func firstC0Byte(in bytes: Span<UInt8>, from start: Int) -> Int {
        precondition(start >= 0 && start <= bytes.count)
        guard start < bytes.count else { return bytes.count }

        var index = start

#if compiler(>=6.4)
        let rawBytes = bytes.bytes
        while index <= bytes.count - vectorWidth {
            let vector = rawBytes.load(
                fromByteOffset: index, as: ByteVector.self)
            let matches = vector .< space
            if any(matches) {
                for lane in 0..<vectorWidth where vector[lane] < 0x20 {
                    return index + lane
                }
            }
            index += vectorWidth
        }
#endif

        while index < bytes.count {
            if bytes[index] < 0x20 {
                return index
            }
            index += 1
        }
        return bytes.count
    }

    /// Returns the first index whose byte is 0x80 or higher.
    /// Returns `bytes.endIndex` when all remaining bytes are ASCII.
    @inline(__always)
    static func firstNonASCIIByte(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        precondition(start >= bytes.startIndex && start <= bytes.endIndex)
#if compiler(>=6.4)
        let baseIndex = bytes.startIndex
        let offset = firstNonASCIIByte(in: bytes.span, from: start - baseIndex)
        return baseIndex + offset
#else
        return legacyFirstNonASCIIByte(in: bytes, from: start)
#endif
    }

    /// Returns the first index whose byte is 0x80 or higher.
    /// Returns `bytes.count` when all remaining bytes are ASCII.
    @inline(__always)
    static func firstNonASCIIByte(in bytes: Span<UInt8>, from start: Int) -> Int {
        precondition(start >= 0 && start <= bytes.count)
        guard start < bytes.count else { return bytes.count }

        var index = start

#if compiler(>=6.4)
        let rawBytes = bytes.bytes
        while index <= bytes.count - vectorWidth {
            let vector = rawBytes.load(
                fromByteOffset: index, as: ByteVector.self)
            let matches = vector .>= nonASCII
            if any(matches) {
                for lane in 0..<vectorWidth where vector[lane] >= 0x80 {
                    return index + lane
                }
            }
            index += vectorWidth
        }
#endif

        while index < bytes.count {
            if bytes[index] >= 0x80 {
                return index
            }
            index += 1
        }
        return bytes.count
    }

    /// Returns the first index whose byte is below 0x20 or equals `value`.
    /// Returns `bytes.count` when no such byte remains.
    ///
    /// The OSC payload path needs both boundaries, so one pass finds them
    /// together rather than scanning the run twice.
    @inline(__always)
    static func firstC0OrByte(
        _ value: UInt8, in bytes: Span<UInt8>, from start: Int
    ) -> Int {
        precondition(start >= 0 && start <= bytes.count)
        guard start < bytes.count else { return bytes.count }

        var index = start

#if compiler(>=6.4)
        let target = ByteVector(repeating: value)
        let rawBytes = bytes.bytes
        while index <= bytes.count - vectorWidth {
            let vector = rawBytes.load(
                fromByteOffset: index, as: ByteVector.self)
            let matches = (vector .< space) .| (vector .== target)
            if any(matches) {
                for lane in 0..<vectorWidth
                where vector[lane] < 0x20 || vector[lane] == value {
                    return index + lane
                }
            }
            index += vectorWidth
        }
#endif

        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x20 || byte == value {
                return index
            }
            index += 1
        }
        return bytes.count
    }

    @inline(__always)
    private static func legacyFirstC0Byte(
        in bytes: ArraySlice<UInt8>, from start: Int
    ) -> Int {
        guard start < bytes.endIndex else { return bytes.endIndex }

        let baseIndex = bytes.startIndex
        return bytes.withUnsafeBufferPointer { buffer in
            let baseAddress = buffer.baseAddress!
            var offset = start - baseIndex

            while offset <= buffer.count - vectorWidth {
                let vector = UnsafeRawPointer(baseAddress.advanced(by: offset))
                    .loadUnaligned(as: ByteVector.self)
                let matches = vector .< space
                if any(matches) {
                    for lane in 0..<vectorWidth where vector[lane] < 0x20 {
                        return baseIndex + offset + lane
                    }
                }
                offset += vectorWidth
            }

            while offset < buffer.count {
                if buffer[offset] < 0x20 {
                    return baseIndex + offset
                }
                offset += 1
            }
            return bytes.endIndex
        }
    }

    @inline(__always)
    private static func legacyFirstNonASCIIByte(
        in bytes: ArraySlice<UInt8>, from start: Int
    ) -> Int {
        guard start < bytes.endIndex else { return bytes.endIndex }

        let baseIndex = bytes.startIndex
        return bytes.withUnsafeBufferPointer { buffer in
            let baseAddress = buffer.baseAddress!
            var offset = start - baseIndex

            while offset <= buffer.count - vectorWidth {
                let vector = UnsafeRawPointer(baseAddress.advanced(by: offset))
                    .loadUnaligned(as: ByteVector.self)
                let matches = vector .>= nonASCII
                if any(matches) {
                    for lane in 0..<vectorWidth where vector[lane] >= 0x80 {
                        return baseIndex + offset + lane
                    }
                }
                offset += vectorWidth
            }

            while offset < buffer.count {
                if buffer[offset] >= 0x80 {
                    return baseIndex + offset
                }
                offset += 1
            }
            return bytes.endIndex
        }
    }

}

extension Span where Element == UInt8 {
    /// Makes an owned copy without exposing unsafe storage.
    @inline(__always)
    func copiedBytes() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        for index in indices {
            result.append(self[index])
        }
        return result
    }
}
