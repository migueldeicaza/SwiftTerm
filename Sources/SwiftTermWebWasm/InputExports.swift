import SwiftTerm
#if !SWIFTTERM_EMBEDDED
import Foundation
#endif

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_input_modes")
#endif
public func terminalInputModes(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { Int32($0.terminal.hostInputModes) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_pointer_modes")
#endif
public func terminalPointerModes(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { Int32($0.terminal.hostPointerModes) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_text")
#endif
public func terminalText(_ terminal: UInt32, _ pointer: UInt32, _ length: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard length <= 64 * 1024 else { return ABI.invalidArgument }
        guard let bytes = WasmRuntime.shared.memory.read(pointer, length) else { return ABI.outOfBounds }
        let text = String(decoding: bytes, as: UTF8.self)
        guard Array(text.utf8) == bytes else { return ABI.invalidArgument }
        return entry.terminal.sendHostText(text) ? 1 : 0
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_mouse")
#endif
public func terminalMouse(_ terminal: UInt32, _ action: UInt32, _ button: UInt32,
                          _ modifiers: UInt32, _ col: UInt32, _ row: UInt32,
                          _ pixelX: UInt32, _ pixelY: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard let action = TerminalMouseAction(rawValue: action),
              let buttonKind = TerminalMouseButton(rawValue: button), modifiers <= 15,
              col < UInt32(entry.terminal.cols), row < UInt32(entry.terminal.rows)
        else { return ABI.invalidArgument }
        switch action {
        case .press, .release: guard button < 3 else { return ABI.invalidArgument }
        case .move: guard button <= 3 else { return ABI.invalidArgument }
        case .wheel: guard button >= 4 else { return ABI.invalidArgument }
        }
        // Use UInt64 before multiplication. Conversion to Int is safe on wasm32
        // only after the logical screen and signed integer bounds are checked.
        let width = entry.host.cellWidth > 0
            ? UInt64(entry.host.cellWidth) * UInt64(entry.terminal.cols) : 65536
        let height = entry.host.cellHeight > 0
            ? UInt64(entry.host.cellHeight) * UInt64(entry.terminal.rows) : 65536
        guard UInt64(pixelX) < width, UInt64(pixelY) < height,
              pixelX < UInt32(Int32.max), pixelY < UInt32(Int32.max)
        else { return ABI.invalidArgument }
        return entry.terminal.sendHostMouse(action: action, button: buttonKind,
            modifiers: modifiers, col: Int(col), row: Int(row),
            pixelX: Int(pixelX), pixelY: Int(pixelY)) ? 1 : 0
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_key")
#endif
public func terminalKey(_ terminal: UInt32, _ pointer: UInt32, _ length: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard length >= 28, length <= 4096 else { return ABI.invalidArgument }
        guard let bytes = WasmRuntime.shared.memory.read(pointer, length) else { return ABI.outOfBounds }
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        let modifiers = word(0), type = word(4), a = Int(word(8)), b = Int(word(12)), c = Int(word(16))
        guard modifiers <= 255, (1...3).contains(type), a <= 128, b <= 128, c <= 2048,
              a + b + c == bytes.count - 28 else { return ABI.invalidArgument }
        let key = String(decoding: bytes[28..<28+a], as: UTF8.self)
        let code = String(decoding: bytes[28+a..<28+a+b], as: UTF8.self)
        let text = c == 0 ? nil : String(decoding: bytes[(28+a+b)...], as: UTF8.self)
        guard Array(key.utf8) == Array(bytes[28..<28+a]), Array(code.utf8) == Array(bytes[28+a..<28+a+b]),
              text == nil || Array(text!.utf8) == Array(bytes[(28+a+b)...]) else { return ABI.invalidArgument }
        let shifted = word(20), base = word(24)
        guard (shifted == 0 || UnicodeScalar(shifted) != nil), (base == 0 || UnicodeScalar(base) != nil) else { return ABI.invalidArgument }
        return Int32(entry.terminal.sendHostKey(key: key, code: code, modifiers: modifiers,
            eventType: type, text: text, shiftedKey: shifted, baseLayoutKey: base))
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_paste")
#endif
public func terminalPaste(_ terminal: UInt32, _ pointer: UInt32, _ length: UInt32, _ flags: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard length <= 512 * 1024, flags <= 3 else { return ABI.invalidArgument }
        guard let bytes = WasmRuntime.shared.memory.read(pointer, length) else { return ABI.outOfBounds }
        let text = String(decoding: bytes, as: UTF8.self)
        guard Array(text.utf8) == bytes else { return ABI.invalidArgument }
        #if !SWIFTTERM_EMBEDDED
        let data = Data(bytes)
        let snapshot: TerminalClipboardSnapshot? = flags & 1 == 0 ? nil : TerminalClipboardSnapshot(
            location: .standard, mimeTypes: ["text/plain"], read: { mime, completion in
                completion(mime == "text/plain" ? .data(data) : .unavailable); return true
            })
        switch entry.terminal.paste(TerminalPasteRequest(snapshot: snapshot, text: text), allowUnsafe: flags & 2 != 0) {
        case .textSent: return 0
        case .eventSent: return 1
        case .rejected: return entry.fail(ABI.invalidArgument, "This paste needs explicit approval. It contains newlines or a paste terminator.")
        case .failed: return ABI.unsupported
        }
        #else
        return entry.terminal.sendHostTextPaste(text, allowUnsafe: flags & 2 != 0) ? 0
            : entry.fail(ABI.invalidArgument, "This paste needs explicit approval. It contains newlines or a paste terminator.")
        #endif
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_clipboard_configure")
#endif
public func terminalClipboardConfigure(_ terminal: UInt32, _ capabilities: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard capabilities <= 3 else { return ABI.invalidArgument }
        #if !SWIFTTERM_EMBEDDED
        entry.host.clipboard.capabilities = UInt8(capabilities)
        entry.host.clipboard.reset()
        entry.terminal.refreshKittyClipboardCapabilities()
        return ABI.ok
        #else
        return capabilities == 0 ? ABI.ok : ABI.unsupported
        #endif
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_clipboard_complete")
#endif
public func terminalClipboardComplete(_ terminal: UInt32, _ id: UInt32, _ status: UInt32, _ pointer: UInt32, _ length: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard status <= 6, length <= 512 * 1024 else { return ABI.invalidArgument }
        guard let bytes = WasmRuntime.shared.memory.read(pointer, length) else { return ABI.outOfBounds }
        #if !SWIFTTERM_EMBEDDED
        return entry.host.clipboard.finish(id, status: status, bytes: bytes) ? ABI.ok
            : entry.fail(ABI.invalidArgument, "The clipboard request expired or was already completed.")
        #else
        return ABI.unsupported
        #endif
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_clipboard_reset")
#endif
public func terminalClipboardReset(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in entry.host.clipboard.reset(); return ABI.ok }
}
