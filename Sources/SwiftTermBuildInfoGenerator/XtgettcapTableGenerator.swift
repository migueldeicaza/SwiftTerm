import Foundation

/// Turns the checked-in terminfo entry into the static XTGETTCAP reply table.
///
/// XTGETTCAP requests carry hex-encoded capability names, so both the lookup
/// key and the complete reply can be built here. The terminal then only has to
/// uppercase the request key and read the table.
enum XtgettcapTableGenerator {
    /// Capabilities that are query-able but are not terminfo capabilities.
    ///
    /// `Co` is deliberately absent: it is the termcap spelling of the terminfo
    /// `colors` capability, so it is derived from the entry rather than written
    /// down a second time, which would let the two values disagree.
    ///
    /// `TN` is deliberately absent: only the host knows the terminal name, so
    /// the terminal answers that key from `TerminalOptions.termName`.
    private static let extraCapabilities: [(name: String, value: String)] = [
        ("RGB", "8")
    ]

    static func sourceFile(capabilities: [TerminfoCapability]) throws -> String {
        var entries: [(key: String, reply: String)] = []
        var keys: Set<String> = []

        for capability in capabilities {
            let value = try valueBytes(of: capability.value)
            try append(name: capability.name, value: value, to: &entries, keys: &keys)
            if capability.name == "colors" {
                // `Co` is the termcap name for `colors`, and requesters use both.
                try append(name: "Co", value: value, to: &entries, keys: &keys)
            }
        }
        for extra in extraCapabilities {
            try append(name: extra.name, value: Array(extra.value.utf8),
                       to: &entries, keys: &keys)
        }
        // Sorting keeps the generated file stable for the same input.
        entries.sort { $0.key < $1.key }

        var lines: [String] = []
        for entry in entries {
            lines.append("        \(swiftLiteral(entry.key)), \(swiftLiteral(entry.reply)),")
        }

        return """
        // This file is generated from `swifterm-terminfo`. Do not edit it.

        /// The terminfo data that SwiftTerm reports over XTGETTCAP.
        enum SwiftTermTerminfo {
            /// Complete XTGETTCAP replies, keyed by the uppercase hex-encoded
            /// capability name.
            ///
            /// Each value is a whole 7-bit reply, `ESC P 1 + r <key> ESC \\` for a
            /// Boolean capability and `ESC P 1 + r <key> = <value> ESC \\` for a
            /// capability that has a value. Values are hex-encoded with uppercase
            /// digits, so a reply is always safe to send unchanged.
            ///
            /// The table has no `TN` entry. Only the host knows the terminal name.
            static let xtgettcapReplies: [String: String] = {
                var replies = [String: String](minimumCapacity: \(entries.count))
                var index = 0
                while index + 1 < flatEntries.count {
                    replies[flatEntries[index]] = flatEntries[index + 1]
                    index += 2
                }
                return replies
            }()

            /// Alternating keys and replies.
            ///
            /// A flat array of string literals stays cheap for the type checker,
            /// which a dictionary literal of this size does not.
            private static let flatEntries: [String] = [
        \(lines.joined(separator: "\n"))
            ]
        }

        """
    }

    private static func append(
        name: String,
        value: [UInt8],
        to entries: inout [(key: String, reply: String)],
        keys: inout Set<String>
    ) throws {
        let key = hexEncoded(Array(name.utf8))
        guard keys.insert(key).inserted else {
            throw TerminfoSourceError.duplicateCapability(name)
        }
        // An empty value is reported the same way as a Boolean capability,
        // which is what xterm and Ghostty do.
        let body = value.isEmpty ? key : "\(key)=\(hexEncoded(value))"
        entries.append((key: key, reply: "\u{1b}P1+r\(body)\u{1b}\\"))
    }

    private static func valueBytes(of value: TerminfoCapability.Value) throws -> [UInt8] {
        switch value {
        case .boolean:
            return []
        case .numeric(let number):
            return Array(String(number).utf8)
        case .string(let text):
            // A string that holds a parameter expression is reported as
            // terminfo source text, because the requester has to run the
            // expression itself. A string without parameters is reported as the
            // bytes that the terminal sends. This split matches xterm, Kitty,
            // and Ghostty.
            if text.contains("%") {
                return normalizedSourceBytes(of: text)
            }
            return terminalBytes(of: text)
        }
    }

    /// Source text with only the spelling differences removed.
    ///
    /// `infocmp` writes a colon as `\:` so that the entry stays convertible to
    /// termcap, where a colon separates fields. A colon needs no escape in a
    /// terminfo string, and Ghostty reports the plain colon, so the escape is
    /// removed here.
    private static func normalizedSourceBytes(of text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                result.append(bytes[index])
                index += 1
                continue
            }
            if bytes[index + 1] == UInt8(ascii: ":") {
                result.append(UInt8(ascii: ":"))
            } else {
                result.append(bytes[index])
                result.append(bytes[index + 1])
            }
            index += 2
        }
        return result
    }

    /// The bytes that a parameterless string capability sends to the terminal.
    private static func terminalBytes(of text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "^"), index + 1 < bytes.count {
                let next = bytes[index + 1]
                result.append(next == UInt8(ascii: "?") ? 0x7f : next & 0x1f)
                index += 2
                continue
            }
            guard byte == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                result.append(byte)
                index += 1
                continue
            }

            let next = bytes[index + 1]
            if next >= UInt8(ascii: "0") && next <= UInt8(ascii: "7") {
                var value = 0
                var digits = 0
                var scan = index + 1
                while scan < bytes.count, digits < 3,
                      bytes[scan] >= UInt8(ascii: "0"), bytes[scan] <= UInt8(ascii: "7") {
                    value = value * 8 + Int(bytes[scan] - UInt8(ascii: "0"))
                    scan += 1
                    digits += 1
                }
                result.append(UInt8(value & 0xff))
                index = scan
                continue
            }

            switch next {
            case UInt8(ascii: "E"), UInt8(ascii: "e"):
                result.append(0x1b)
            case UInt8(ascii: "a"):
                result.append(0x07)
            case UInt8(ascii: "b"):
                result.append(0x08)
            case UInt8(ascii: "f"):
                result.append(0x0c)
            case UInt8(ascii: "l"), UInt8(ascii: "n"):
                result.append(0x0a)
            case UInt8(ascii: "r"):
                result.append(0x0d)
            case UInt8(ascii: "s"):
                result.append(0x20)
            case UInt8(ascii: "t"):
                result.append(0x09)
            default:
                // `\\`, `\^`, `\,`, `\:`, and any other escaped punctuation.
                result.append(next)
            }
            index += 2
        }
        return result
    }

    private static func hexEncoded(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// A Swift string literal for text that only holds hex digits, the reply
    /// framing, and the punctuation of that framing.
    private static func swiftLiteral(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\u{1b}":
                result += "\\u{1b}"
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
