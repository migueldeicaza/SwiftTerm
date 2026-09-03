/// Control-byte sets used to sanitize text before a paste reaches the PTY.
public enum TerminalPasteControls {
    /// Xterm's fixed `disallowedPasteControls` entries.
    public static let fixedDisallowedBytes: Set<UInt8> = [
        0x00, // NUL
        0x04, // EOT
        0x05, // ENQ
        0x08, // BS
        0x1b, // ESC
        0x7f, // DEL
    ]

    /// Conventional terminal-driver special bytes used when the host cannot
    /// read the active PTY settings.
    public static let approximateTerminalControlBytes: Set<UInt8> = [
        0x03, // VINTR
        0x0f, // VDISCARD
        0x11, // VSTART
        0x12, // VREPRINT
        0x13, // VSTOP
        0x15, // VKILL
        0x16, // VLNEXT
        0x17, // VWERASE
        0x1a, // VSUSP
        0x1c, // VQUIT
    ]
}

enum TerminalPaste {
    enum EncodingResult: Equatable, Sendable {
        case encoded([UInt8])
        case unsafePayload
    }

    private static let bracketedSuffix = EscapeSequences.bracketedPasteEnd
    static func encode(
        _ text: String,
        bracketed: Bool,
        terminalControlBytes: Set<UInt8> = TerminalPasteControls.approximateTerminalControlBytes,
        allowUnsafe: Bool = false
    ) -> EncodingResult {
        encode(
            Array(text.utf8),
            bracketed: bracketed,
            terminalControlBytes: terminalControlBytes,
            allowUnsafe: allowUnsafe)
    }

    static func encode(
        _ bytes: [UInt8],
        bracketed: Bool,
        terminalControlBytes: Set<UInt8> = TerminalPasteControls.approximateTerminalControlBytes,
        allowUnsafe: Bool = false
    ) -> EncodingResult {
        if !allowUnsafe && isUnsafe(bytes, bracketed: bracketed) {
            return .unsafePayload
        }

        var result: [UInt8] = []
        result.reserveCapacity(bytes.count + (bracketed ? 12 : 0))
        if bracketed {
            result.append(contentsOf: EscapeSequences.bracketedPasteStart)
        }
        for byte in bytes {
            if TerminalPasteControls.fixedDisallowedBytes.contains(byte)
                || terminalControlBytes.contains(byte)
            {
                result.append(0x20)
            } else if !bracketed && byte == 0x0a {
                result.append(0x0d)
            } else {
                result.append(byte)
            }
        }
        if bracketed {
            result.append(contentsOf: EscapeSequences.bracketedPasteEnd)
        }
        return .encoded(result)
    }

    private static func isUnsafe(_ bytes: [UInt8], bracketed: Bool) -> Bool {
        if !bracketed && bytes.contains(0x0a) {
            return true
        }
        guard bytes.count >= bracketedSuffix.count else {
            return false
        }
        for start in 0...(bytes.count - bracketedSuffix.count) {
            let end = start + bracketedSuffix.count
            if bytes[start..<end].elementsEqual(bracketedSuffix) {
                return true
            }
        }
        return false
    }
}
