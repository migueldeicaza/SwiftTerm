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
        let baseIndex = bytes.startIndex
        let offset = firstC0Byte(in: bytes.span, from: start - baseIndex)
        return baseIndex + offset
    }

    /// Returns the first index whose byte is below 0x20.
    /// Returns `bytes.count` when all remaining bytes are 0x20 or higher.
    @inline(__always)
    static func firstC0Byte(in bytes: Span<UInt8>, from start: Int) -> Int {
        precondition(start >= 0 && start <= bytes.count)
        guard start < bytes.count else { return bytes.count }

        let rawBytes = bytes.bytes
        var index = start

        while index <= bytes.count - vectorWidth {
#if compiler(>=6.4)
            let vector = rawBytes.load(
                fromByteOffset: index, as: ByteVector.self)
#else
            let vector = unsafe rawBytes.unsafeLoadUnaligned(
                fromUncheckedByteOffset: index, as: ByteVector.self)
#endif
            let matches = vector .< space
            if any(matches) {
                for lane in 0..<vectorWidth where vector[lane] < 0x20 {
                    return index + lane
                }
            }
            index += vectorWidth
        }

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
        let baseIndex = bytes.startIndex
        let offset = firstNonASCIIByte(in: bytes.span, from: start - baseIndex)
        return baseIndex + offset
    }

    /// Returns the first index whose byte is 0x80 or higher.
    /// Returns `bytes.count` when all remaining bytes are ASCII.
    @inline(__always)
    static func firstNonASCIIByte(in bytes: Span<UInt8>, from start: Int) -> Int {
        precondition(start >= 0 && start <= bytes.count)
        guard start < bytes.count else { return bytes.count }

        let rawBytes = bytes.bytes
        var index = start

        while index <= bytes.count - vectorWidth {
#if compiler(>=6.4)
            let vector = rawBytes.load(
                fromByteOffset: index, as: ByteVector.self)
#else
            let vector = unsafe rawBytes.unsafeLoadUnaligned(
                fromUncheckedByteOffset: index, as: ByteVector.self)
#endif
            let matches = vector .>= nonASCII
            if any(matches) {
                for lane in 0..<vectorWidth where vector[lane] >= 0x80 {
                    return index + lane
                }
            }
            index += vectorWidth
        }

        while index < bytes.count {
            if bytes[index] >= 0x80 {
                return index
            }
            index += 1
        }
        return bytes.count
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
