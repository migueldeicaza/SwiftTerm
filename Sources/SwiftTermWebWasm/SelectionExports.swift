import SwiftTerm

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_scroll")
#endif
public func terminalScroll(_ terminal: UInt32, _ value: Int32, _ absolute: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard absolute <= 1 else { return entry.fail(ABI.invalidArgument, "The absolute flag must be zero or one.") }
        entry.terminal.scrollViewport(Int(value), absolute: absolute != 0)
        entry.host.forceFull = true
        return ABI.ok
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_selection")
#endif
public func terminalSelection(_ terminal: UInt32, _ action: UInt32, _ column: UInt32,
                              _ row: UInt32, _ mode: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard action <= 3, mode <= 3, column <= UInt32(Int32.max), row <= UInt32(Int32.max),
              entry.terminal.updateSelection(entry.selection, action: action,
                  column: Int(column), row: Int(row), mode: mode) else {
            return entry.fail(ABI.invalidArgument, "The selection action, mode, or cell is not valid.")
        }
        return ABI.ok
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_selection_state_size")
#endif
public func terminalSelectionStateSize(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { entry in
        let state = entry.terminal.selectionState(entry.selection)
        if state != entry.lastSelectionState {
            guard entry.selectionRevision < UInt64.max else {
                return entry.fail(ABI.internalError, "The selection revision is exhausted.")
            }
            entry.selectionRevision += 1
            entry.lastSelectionState = state
        }
        let length = 32 + state.spans.count * 12
        guard length <= ABI.maximumSnapshot else {
            return entry.fail(ABI.outOfMemory, "The selection snapshot exceeds the limit.")
        }
        var bytes = [UInt8](repeating: 0, count: length)
        bytes.put32(1, at: 0)
        bytes.put32(UInt32(truncatingIfNeeded: entry.selectionRevision), at: 4)
        bytes.put32(UInt32(truncatingIfNeeded: entry.selectionRevision >> 32), at: 8)
        bytes.put32(UInt32(state.viewport.topRow), at: 12)
        bytes.put32(UInt32(state.viewport.maximumTopRow), at: 16)
        bytes.put32((state.active ? 1 : 0) | (state.viewport.isAlternateScreen ? 2 : 0), at: 20)
        bytes.put32(UInt32(state.spans.count), at: 24)
        for (index, span) in state.spans.enumerated() {
            let offset = 32 + index * 12
            bytes.put32(UInt32(span.row), at: offset)
            bytes.put32(UInt32(span.startColumn), at: offset + 4)
            bytes.put32(UInt32(span.endColumn), at: offset + 8)
        }
        entry.selectionSnapshot = bytes
        return Int32(length)
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_selection_state_copy")
#endif
public func terminalSelectionStateCopy(_ terminal: UInt32, _ dst: UInt32, _ capacity: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    return runtime.withTerminal(terminal) { runtime.copy($0, $0.selectionSnapshot[...], dst, capacity) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_selection_text_size")
#endif
public func terminalSelectionTextSize(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { entry in
        let text = entry.terminal.selectionText(entry.selection)
        guard text.utf8.count <= ABI.maximumSnapshot else {
            return entry.fail(ABI.outOfMemory, "The selection text exceeds the limit.")
        }
        entry.selectionTextSnapshot = Array(text.utf8)
        return Int32(entry.selectionTextSnapshot.count)
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_selection_text_copy")
#endif
public func terminalSelectionTextCopy(_ terminal: UInt32, _ dst: UInt32, _ capacity: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    return runtime.withTerminal(terminal) { runtime.copy($0, $0.selectionTextSnapshot[...], dst, capacity) }
}
