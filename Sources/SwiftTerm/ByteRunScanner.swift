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

    /// Returns the first index whose byte is 0x80 or higher.
    /// Returns `bytes.endIndex` when all remaining bytes are ASCII.
    @inline(__always)
    static func firstNonASCIIByte(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        precondition(start >= bytes.startIndex && start <= bytes.endIndex)
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
