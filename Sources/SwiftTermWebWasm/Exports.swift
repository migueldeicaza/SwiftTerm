import SwiftTerm

#if !arch(wasm32)
@main enum NativeFacadeTestMain { static func main() { nativeSnapshotMain() } }
#endif

#if arch(wasm32)
@_expose(wasm, "swiftterm_wasm_abi_version")
#endif
public func wasmABIVersion() -> UInt32 { 1 }

#if arch(wasm32)
@_expose(wasm, "swiftterm_wasm_capabilities")
#endif
public func wasmCapabilities() -> UInt32 {
    #if SWIFTTERM_WEB_EMBEDDED
    return 2 | 4 | 8 | 16 | 32 | 128 | 256 | 8192
    #else
    return 1 | 4 | 8 | 16 | 32 | 128 | 256 | 512 | 1024 | 2048 | 4096 | 8192
    #endif
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_wasm_layout_size")
#endif
public func wasmLayoutSize(_ layout: UInt32) -> UInt32 {
    switch layout {
    case 1: return 104
    case 2: return 16
    case 3: return 32
    case 4: return 16
    default: return 0
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_wasm_alloc")
#endif
public func wasmAlloc(_ count: UInt32) -> UInt32 {
    let runtime = WasmRuntime.shared
    let pointer = runtime.memory.allocate(count)
    if pointer == 0 && count != 0 { _ = runtime.fail(ABI.outOfMemory, "The host allocation limit was reached.") }
    return pointer
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_wasm_free")
#endif
public func wasmFree(_ pointer: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    let status = runtime.memory.release(pointer)
    if status < 0 { return runtime.fail(status, "The pointer does not identify a live host allocation.") }
    return status
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_wasm_last_error_size")
#endif
public func wasmLastErrorSize(_ terminal: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    if terminal == 0 { return Int32(runtime.error.count) }
    return runtime.withTerminal(terminal) { Int32($0.error.count) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_wasm_last_error_copy")
#endif
public func wasmLastErrorCopy(_ terminal: UInt32, _ dst: UInt32, _ capacity: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    if terminal == 0 { return runtime.memory.copy(runtime.error[...], to: dst, capacity: capacity) }
    return runtime.withTerminal(terminal) { runtime.memory.copy($0.error[...], to: dst, capacity: capacity) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_create")
#endif
public func terminalCreate(_ cols: UInt32, _ rows: UInt32, _ scrollback: UInt32) -> UInt32 {
    let runtime = WasmRuntime.shared
    guard ABI.dimensions(cols, rows), scrollback <= 100000 else {
        _ = runtime.fail(ABI.invalidArgument, "The terminal dimensions or scrollback exceed the limit.")
        return 0
    }
    let entry = TerminalEntry(cols: cols, rows: rows, scrollback: scrollback)
    let handle = runtime.handles.insert(entry)
    if handle == 0 { _ = runtime.fail(ABI.outOfMemory, "The terminal handle limit was reached.") }
    return handle
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_destroy")
#endif
public func terminalDestroy(_ terminal: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    return runtime.withTerminal(terminal) { entry in
        // Cancel pending host work before removal.
        #if !SWIFTTERM_EMBEDDED
        entry.host.clipboard.reset()
        entry.host.graphics.reset()
        #if os(WASI)
        entry.terminal.cancelHostEvents()
        #endif
        #endif
        #if SWIFTTERM_EMBEDDED
        entry.terminal.close()
        #endif
        return runtime.handles.remove(terminal) ? ABI.ok : ABI.invalidHandle
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_reset")
#endif
public func terminalReset(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal, allowQueueRecovery: true) { entry in
        #if !SWIFTTERM_EMBEDDED
        entry.host.clipboard.reset()
        entry.host.graphics.reset()
        #if os(WASI)
        entry.terminal.cancelHostEvents()
        #endif
        #endif
        entry.host.queueFailure = false
        entry.terminal.resetToInitialState()
        entry.host.forceFull = true
        return ABI.ok
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_resize")
#endif
public func terminalResize(_ terminal: UInt32, _ cols: UInt32, _ rows: UInt32, _ width: UInt32, _ height: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard ABI.dimensions(cols, rows), width <= 65535, height <= 65535 else {
            return entry.fail(ABI.invalidArgument, "The grid or pixel dimensions exceed the limit.")
        }
        if width != 0 { entry.host.cellWidth = Int(width) }
        if height != 0 { entry.host.cellHeight = Int(height) }
        entry.terminal.resize(cols: Int(cols), rows: Int(rows))
        if width != 0 && height != 0 { entry.terminal.updatePixelGeometry(cellWidth: Int(width), cellHeight: Int(height)) }
        entry.host.forceFull = true
        return ABI.ok
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_set_focus")
#endif
public func terminalSetFocus(_ terminal: UInt32, _ focused: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard focused <= 1 else { return entry.fail(ABI.invalidArgument, "Focus must be zero or one.") }
        if entry.host.focused != (focused != 0) { entry.host.forceFull = true }
        entry.host.focused = focused != 0
        entry.terminal.setTerminalFocus(focused != 0)
        return ABI.ok
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_set_visibility")
#endif
public func terminalSetVisibility(_ terminal: UInt32, _ visibility: UInt32) -> Int32 {
    WasmRuntime.shared.mutate(terminal) { entry in
        guard visibility == 1 || visibility == 2 else {
            return entry.fail(ABI.invalidArgument, "Visibility must be one or two.")
        }
        entry.terminal.setTerminalVisibility(visibility == 1 ? .potentiallyVisible : .notVisible)
        return ABI.ok
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_write")
#endif
public func terminalWrite(_ terminal: UInt32, _ src: UInt32, _ length: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    return runtime.mutate(terminal) { entry in
        guard length <= UInt32(ABI.maximumWrite) else { return entry.fail(ABI.invalidArgument, "The write exceeds 16 MiB.") }
        guard !entry.host.queueFailure else { return entry.fail(ABI.outOfMemory, "Drain the queues and reset after queue overflow.") }
        guard let bytes = runtime.memory.read(src, length) else { return entry.fail(ABI.outOfBounds, "The input buffer is outside a host allocation.") }
        entry.terminal.feed(buffer: bytes[...])
        #if os(WASI) && !SWIFTTERM_EMBEDDED
        if entry.terminal.takeHostEventOverflow() { entry.host.queueFailure = true }
        #endif
        if entry.host.queueFailure {
            // Feed changed state even if a delegate could not enqueue a reply.
            entry.changed()
            return entry.fail(ABI.outOfMemory, "Queue overflow stopped delivery. Input can be partially applied. Drain and reset; do not retry the write.")
        }
        return ABI.ok
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_output_size")
#endif
public func terminalOutputSize(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { Int32($0.host.output.count) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_output_copy")
#endif
public func terminalOutputCopy(_ terminal: UInt32, _ dst: UInt32, _ capacity: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    return runtime.withTerminal(terminal) { runtime.copy($0, $0.host.output.bytes, dst, capacity) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_output_consume")
#endif
public func terminalOutputConsume(_ terminal: UInt32, _ count: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { entry in
        guard count <= UInt32(entry.host.output.count) else { return entry.fail(ABI.invalidArgument, "The output consume count exceeds the queue size.") }
        _ = entry.host.output.consume(Int(count))
        return ABI.ok
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_event_size")
#endif
public func terminalEventSize(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { Int32($0.host.events.first.count) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_event_copy")
#endif
public func terminalEventCopy(_ terminal: UInt32, _ dst: UInt32, _ capacity: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    return runtime.withTerminal(terminal) { runtime.copy($0, $0.host.events.first[...], dst, capacity) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_terminal_event_consume")
#endif
public func terminalEventConsume(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { entry in entry.host.events.consume(); return ABI.ok }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_render_update")
#endif
public func renderUpdate(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { entry in
        let pollStatus = entry.poll()
        if pollStatus < 0 { return pollStatus }
        if entry.snapshotGeneration == entry.revision { return entry.snapshotDirty }
        let source = entry.terminal.makeRenderSnapshot(scope: entry.host.forceFull ? .full : .dirty)
        guard SnapshotEncoder.encode(source, generation: entry.revision, focused: entry.host.focused, into: &entry.snapshot) else {
            return entry.fail(ABI.outOfMemory, "The snapshot exceeds its size or grapheme limit.")
        }
        entry.snapshotGeneration = entry.revision
        entry.snapshotDirty = Int32(source.dirtyKind.rawValue)
        entry.host.forceFull = false
        return entry.snapshotDirty
    }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_render_snapshot_size")
#endif
public func renderSnapshotSize(_ terminal: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { Int32($0.snapshot.count) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_render_snapshot_copy")
#endif
public func renderSnapshotCopy(_ terminal: UInt32, _ dst: UInt32, _ capacity: UInt32) -> Int32 {
    let runtime = WasmRuntime.shared
    return runtime.withTerminal(terminal) { runtime.copy($0, $0.snapshot[...], dst, capacity) }
}

#if arch(wasm32)
@_expose(wasm, "swiftterm_render_clean")
#endif
public func renderClean(_ terminal: UInt32, _ low: UInt32, _ high: UInt32) -> Int32 {
    WasmRuntime.shared.withTerminal(terminal) { entry in
        let generation = UInt64(low) | UInt64(high) << 32
        guard generation != 0 && generation == entry.snapshotGeneration && generation == entry.revision else {
            return entry.fail(ABI.staleGeneration, "The snapshot generation does not match the current state.")
        }
        entry.terminal.clearUpdateRange()
        entry.snapshotDirty = 0
        SnapshotEncoder.clean(&entry.snapshot)
        return ABI.ok
    }
}
