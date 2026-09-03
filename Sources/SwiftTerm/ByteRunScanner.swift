//
//  ByteRunScanner.swift
//  SwiftTerm
//

/// Finds byte boundaries in terminal input without allocating or copying data.
internal enum ByteRunScanner {
    private typealias ByteVector = SIMD16<UInt8>

    private static let vectorWidth = ByteVector.scalarCount
    /// Bytes checked one at a time before the first vector load. Short runs
    /// dominate interactive output, and the parser scans to the next C0 byte
    /// from every print position; a vector costs more than a few byte loads.
    private static let scalarPrefix = 8
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
        let prefixEnd = min(index + scalarPrefix, bytes.count)
        while index < prefixEnd {
            if bytes[index] < 0x20 {
                return index
            }
            index += 1
        }

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
#else
        // Swift 6.3 has no checked `RawSpan.load`. Short runs, which dominate
        // interactive output, stay in the scalar loop below; a full vector
        // moves to the out-of-line helper so this function stays inlinable.
        if bytes.count - index >= vectorWidth {
            index = vectorScanC0(in: bytes, from: index)
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
        let prefixEnd = min(index + scalarPrefix, bytes.count)
        while index < prefixEnd {
            if bytes[index] >= 0x80 {
                return index
            }
            index += 1
        }

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
#else
        // See `vectorScanC0`: the Swift 6.3 vector loop lives out of line.
        if bytes.count - index >= vectorWidth {
            index = vectorScanNonASCII(in: bytes, from: index)
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
        let prefixEnd = min(index + scalarPrefix, bytes.count)
        while index < prefixEnd {
            if bytes[index] < 0x20 || bytes[index] == value {
                return index
            }
            index += 1
        }

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
#else
        // See `vectorScanC0`: the Swift 6.3 vector loop lives out of line.
        if bytes.count - index >= vectorWidth {
            index = vectorScanC0OrByte(value, in: bytes, from: index)
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

#if !compiler(>=6.4)
    /// Scans whole vectors from the borrowed buffer. Returns the first index
    /// that still needs a scalar check: a matching byte or the start of the
    /// short tail. The loop bound keeps every load inside the span.
    @inline(never)
    private static func vectorScanC0(in bytes: Span<UInt8>, from start: Int) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            let base = UnsafeRawPointer(buffer.baseAddress!)
            var index = start
            while index <= buffer.count - vectorWidth {
                let vector = base.loadUnaligned(
                    fromByteOffset: index, as: ByteVector.self)
                if any(vector .< space) {
                    for lane in 0..<vectorWidth where vector[lane] < 0x20 {
                        return index + lane
                    }
                }
                index += vectorWidth
            }
            return index
        }
    }

    @inline(never)
    private static func vectorScanNonASCII(in bytes: Span<UInt8>, from start: Int) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            let base = UnsafeRawPointer(buffer.baseAddress!)
            var index = start
            while index <= buffer.count - vectorWidth {
                let vector = base.loadUnaligned(
                    fromByteOffset: index, as: ByteVector.self)
                if any(vector .>= nonASCII) {
                    for lane in 0..<vectorWidth where vector[lane] >= 0x80 {
                        return index + lane
                    }
                }
                index += vectorWidth
            }
            return index
        }
    }

    @inline(never)
    private static func vectorScanC0OrByte(
        _ value: UInt8, in bytes: Span<UInt8>, from start: Int
    ) -> Int {
        let target = ByteVector(repeating: value)
        return bytes.withUnsafeBufferPointer { buffer in
            let base = UnsafeRawPointer(buffer.baseAddress!)
            var index = start
            while index <= buffer.count - vectorWidth {
                let vector = base.loadUnaligned(
                    fromByteOffset: index, as: ByteVector.self)
                if any((vector .< space) .| (vector .== target)) {
                    for lane in 0..<vectorWidth
                    where vector[lane] < 0x20 || vector[lane] == value {
                        return index + lane
                    }
                }
                index += vectorWidth
            }
            return index
        }
    }
#endif

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
