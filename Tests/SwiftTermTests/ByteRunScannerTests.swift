import Testing
@testable import SwiftTerm

final class ByteRunScannerTests {
    @Test func scannersMatchScalarSearchesForAllShortLengthsAndStarts() {
        for length in 0...65 {
            var storage = Array(repeating: UInt8(0x41), count: length + 11)
            let lowerBound = 5
            let upperBound = lowerBound + length

            if length > 2 {
                storage[lowerBound + length / 3] = 0x1f
                storage[lowerBound + (length * 2) / 3] = 0x80
            }
            let bytes = storage[lowerBound..<upperBound]

            for start in lowerBound...upperBound {
                #expect(ByteRunScanner.firstC0Byte(in: bytes, from: start) ==
                        scalarFirstC0Byte(in: bytes, from: start))
                #expect(ByteRunScanner.firstNonASCIIByte(in: bytes, from: start) ==
                        scalarFirstNonASCIIByte(in: bytes, from: start))
            }
        }
    }

    @Test func scannersFindMatchesInEveryVectorLane() {
        let lowerBound = 3
        for matchOffset in 0..<64 {
            var storage = Array(repeating: UInt8(0x41), count: 70)
            storage[lowerBound + matchOffset] = 0x1f
            let bytes = storage[lowerBound..<(lowerBound + 64)]
            #expect(ByteRunScanner.firstC0Byte(in: bytes, from: bytes.startIndex) ==
                    bytes.startIndex + matchOffset)

            storage[lowerBound + matchOffset] = 0x80
            let nonASCIIBytes = storage[lowerBound..<(lowerBound + 64)]
            #expect(ByteRunScanner.firstNonASCIIByte(
                in: nonASCIIBytes,
                from: nonASCIIBytes.startIndex) == nonASCIIBytes.startIndex + matchOffset)

        }
    }

    @Test func scannersMatchScalarSearchesForRandomInput() {
        var generator = DeterministicByteGenerator(state: 0x5357_4946_5454_4552)

        for iteration in 0..<1_000 {
            let prefixCount = iteration % 8
            let length = (iteration * 73) % 258
            var storage = Array(repeating: UInt8(0), count: prefixCount + length + 3)
            for index in storage.indices {
                storage[index] = generator.next()
            }

            let bytes = storage[prefixCount..<(prefixCount + length)]
            let start = bytes.startIndex + (length == 0 ? 0 : iteration % (length + 1))
            #expect(ByteRunScanner.firstC0Byte(in: bytes, from: start) ==
                    scalarFirstC0Byte(in: bytes, from: start))
            #expect(ByteRunScanner.firstNonASCIIByte(in: bytes, from: start) ==
                    scalarFirstNonASCIIByte(in: bytes, from: start))
        }
    }

    private func scalarFirstC0Byte(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        for index in start..<bytes.endIndex where bytes[index] < 0x20 {
            return index
        }
        return bytes.endIndex
    }

    private func scalarFirstNonASCIIByte(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        for index in start..<bytes.endIndex where bytes[index] >= 0x80 {
            return index
        }
        return bytes.endIndex
    }

}

private struct DeterministicByteGenerator {
    var state: UInt64

    mutating func next() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 32)
    }
}
