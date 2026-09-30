import SwiftTerm

/// Stable status values for ABI version 1.
enum ABI {
    static let ok: Int32 = 0
    static let invalidHandle: Int32 = -1
    static let invalidArgument: Int32 = -2
    static let outOfBounds: Int32 = -3
    static let bufferTooSmall: Int32 = -4
    static let outOfMemory: Int32 = -5
    static let busy: Int32 = -6
    static let staleGeneration: Int32 = -7
    static let unsupported: Int32 = -8
    static let internalError: Int32 = -9
    static let maximumWrite = 16 * 1024 * 1024
    static let maximumQueue = 8 * 1024 * 1024
    static let maximumControl = 1024 * 1024
    static let maximumSnapshot = 256 * 1024 * 1024

    static func dimensions(_ cols: UInt32, _ rows: UInt32) -> Bool {
        (2...1024).contains(cols) && (1...1024).contains(rows)
    }
    static func cursor(_ style: CursorStyle) -> (shape: UInt8, blink: UInt8) {
        switch style {
        case .blinkBlock: return (0, 1)
        case .steadyBlock: return (0, 0)
        case .blinkBar: return (1, 1)
        case .steadyBar: return (1, 0)
        case .blinkUnderline: return (2, 1)
        case .steadyUnderline: return (2, 0)
        }
    }
    static func color(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> UInt32 {
        func byte(_ value: UInt16) -> UInt32 { (UInt32(value) * 255 + 32767) / 65535 }
        return byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | 255
    }
    static func color(_ value: Color) -> UInt32 { color(value.red, value.green, value.blue) }
}

/// Explicit byte stores avoid native alignment and structure-layout assumptions.
extension Array where Element == UInt8 {
    mutating func put16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    mutating func put32(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 { self[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }
    mutating func append32(_ value: UInt32) {
        for byte in 0..<4 { append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
    }
}
