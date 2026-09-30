#if !SWIFTTERM_EMBEDDED
import Foundation
public typealias TerminalTemporaryDirectory = URL
#else
public typealias TerminalTemporaryDirectory = String
#endif

func terminalStringUTF8(_ bytes: ArraySlice<UInt8>) -> String? {
#if SWIFTTERM_EMBEDDED
    var decoder = UTF8()
    var iterator = bytes.makeIterator()
    while true {
        switch decoder.decode(&iterator) {
        case .scalarValue: continue
        case .emptyInput: return String(decoding: bytes, as: UTF8.self)
        case .error: return nil
        }
    }
#else
    return String(bytes: bytes, encoding: .utf8)
#endif
}

func terminalStringASCII(_ bytes: ArraySlice<UInt8>) -> String? {
#if SWIFTTERM_EMBEDDED
    guard !bytes.contains(where: { $0 > 0x7f }) else { return nil }
    return String(decoding: bytes, as: UTF8.self)
#else
    return String(bytes: bytes, encoding: .ascii)
#endif
}

func terminalReplacingNulls(_ text: String) -> String {
#if SWIFTTERM_EMBEDDED
    return String(text.map { $0 == "\u{0}" ? " " : $0 })
#else
    return text.replacingOccurrences(of: "\u{0}", with: " ")
#endif
}

func terminalBase64Decode(_ bytes: ArraySlice<UInt8>) -> TerminalData? {
#if SWIFTTERM_EMBEDDED
    var result: [UInt8] = []
    var accumulator: UInt32 = 0
    var bitCount = 0
    for byte in bytes {
        let value: UInt8
        switch byte {
        case 65...90: value = byte - 65
        case 97...122: value = byte - 97 + 26
        case 48...57: value = byte - 48 + 52
        case 43: value = 62
        case 47: value = 63
        case 61: return result
        case 9, 10, 13, 32: continue
        default: return nil
        }
        accumulator = (accumulator << 6) | UInt32(value)
        bitCount += 6
        if bitCount >= 8 {
            bitCount -= 8
            result.append(UInt8((accumulator >> UInt32(bitCount)) & 0xff))
            if bitCount == 0 { accumulator = 0 }
        }
    }
    return result
#else
    return Data(base64Encoded: Data(bytes))
#endif
}

func terminalBase64Encode(_ data: TerminalData) -> String {
#if SWIFTTERM_EMBEDDED
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    var result: [UInt8] = []
    var index = 0
    while index < data.count {
        let remaining = data.count - index
        let first = UInt32(data[index])
        let second = remaining > 1 ? UInt32(data[index + 1]) : 0
        let third = remaining > 2 ? UInt32(data[index + 2]) : 0
        let value = (first << 16) | (second << 8) | third
        result.append(alphabet[Int((value >> 18) & 0x3f)])
        result.append(alphabet[Int((value >> 12) & 0x3f)])
        result.append(remaining > 1 ? alphabet[Int((value >> 6) & 0x3f)] : 61)
        result.append(remaining > 2 ? alphabet[Int(value & 0x3f)] : 61)
        index += 3
    }
    return String(decoding: result, as: UTF8.self)
#else
    return data.base64EncodedString()
#endif
}

#if SWIFTTERM_EMBEDDED
enum SwiftTermBuildInfo {
    static let tag = ""
    static let branch = "embedded"
    static let version = ""
}

/// Embedded clients serialize terminal access themselves.
public final class TerminalLock {
    public init() {}
    public func withLock<T>(_ body: () throws -> T) rethrows -> T { try body() }
    public func preconditionLocked(file: StaticString = #fileID, line: UInt = #line) {}
    var isLockedByCurrentThread: Bool { true }
}

struct KittyPlacementContext {}
final class KittyGraphicsState { var activeIsAlternate = false }

enum SwiftTermTerminfo { static let xtgettcapReplies: [String: String] = [:] }

extension Terminal {
    func handleKittyGraphics(_ data: ArraySlice<UInt8>) {}
    func clearAllKittyImages() {}
    func clearKittyImages(in buffer: Buffer, isAlternateBuffer: Bool) {
        for line in buffer.lines.getArray() { line?.images = nil }
    }
    func updateKittyRelativePlacementsForCurrentBuffer() {}
    func kittyGraphicsDidActivateScreen() {}
    func scrollKittyPlacementsInMargins(top: Int, bottom: Int, left: Int, right: Int, delta: Int) {}
    func trimKittyPlacementRows() {}
}
#endif
