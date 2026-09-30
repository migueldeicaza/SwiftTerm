import SwiftTerm

final class TerminalEntry {
    let host: WasmTerminalHost
    let terminal: Terminal
    let selection: SelectionService
    var selectionRevision: UInt64 = 1
    var selectionSnapshot: [UInt8] = []
    var selectionTextSnapshot: [UInt8] = []
    var lastSelectionState: TerminalSelectionState?
    var busy = false
    var revision: UInt64 = 1
    var snapshotGeneration: UInt64 = 0
    var snapshot: [UInt8] = []
    var snapshotDirty: Int32 = 0
    var error: [UInt8] = []
    init(cols: UInt32, rows: UInt32, scrollback: UInt32) {
        let host = WasmTerminalHost()
        self.host = host
        var options = TerminalOptions(cols: Int(cols), rows: Int(rows), scrollback: Int(scrollback))
        options.ansi256PaletteStrategy = .xterm
        options.maximumOscBytes = ABI.maximumControl
        #if SWIFTTERM_EMBEDDED
        options.enableSixelReported = false
        #else
        options.enableSixelReported = true
        options.kittyGraphics.storageLimitBytesPerScreen = 64 * 1024 * 1024
        options.kittyClipboardPolicy = .all
        // https://iterm2.com/feature-reporting/: renderer and input features.
        options.featureReport = "T3LrSc7UTs3BFGsSySx"
        #endif
        terminal = Terminal(delegate: host, options: options)
        terminal.silentLog = true
        selection = SelectionService(terminal: terminal, exclusiveEnd: true)
    }
    func feedPreservingSelection(_ bytes: ArraySlice<UInt8>) {
        terminal.feedPreservingSelection(bytes, selection: selection)
    }
    func clearSelection() {
        _ = terminal.updateSelection(selection, action: 2)
    }
    func fail(_ code: Int32, _ message: String) -> Int32 {
        error = Array(message.utf8)
        return code
    }
    func canMutate() -> Bool { revision < UInt64.max }
    func changed() { revision += 1 }
    deinit {
        #if SWIFTTERM_EMBEDDED
        terminal.close()
        #endif
    }
}

/// Upper 16 bits are a generation. Lower 16 bits are a slot plus one.
/// A slot is retired at generation 65535; stale handles can never become valid.
final class HandleRegistry {
    private struct Slot {
        var generation: UInt32 = 1
        var entry: TerminalEntry?
    }
    private var slots: [Slot] = []
    func insert(_ entry: TerminalEntry) -> UInt32 {
        for index in slots.indices where slots[index].entry == nil && slots[index].generation <= 65535 {
            slots[index].entry = entry
            return slots[index].generation << 16 | UInt32(index + 1)
        }
        guard slots.count < 65535 else { return 0 }
        slots.append(Slot(entry: entry))
        return 1 << 16 | UInt32(slots.count)
    }
    func get(_ handle: UInt32) -> TerminalEntry? {
        let slot = handle & 65535
        guard slot != 0 else { return nil }
        let index = Int(slot - 1)
        guard index < slots.count, slots[index].generation == handle >> 16 else { return nil }
        return slots[index].entry
    }
    func remove(_ handle: UInt32) -> Bool {
        guard get(handle) != nil else { return false }
        let index = Int((handle & 65535) - 1)
        slots[index].entry = nil
        slots[index].generation += 1
        return true
    }
}

final class WasmRuntime {
    nonisolated(unsafe) static let shared = WasmRuntime()
    let memory = HostMemory()
    let handles = HandleRegistry()
    var error: [UInt8] = []
    func fail(_ code: Int32, _ message: String) -> Int32 { error = Array(message.utf8); return code }

    func withTerminal(_ handle: UInt32, _ body: (TerminalEntry) -> Int32) -> Int32 {
        guard let entry = handles.get(handle) else { return fail(ABI.invalidHandle, "The terminal handle is not valid.") }
        guard !entry.busy else { return ABI.busy }
        entry.busy = true
        defer { entry.busy = false }
        return body(entry)
    }
    func mutate(_ handle: UInt32, allowQueueRecovery: Bool = false, _ body: (TerminalEntry) -> Int32) -> Int32 {
        withTerminal(handle) { entry in
            guard entry.canMutate() else { return entry.fail(ABI.internalError, "The state revision is exhausted.") }
            guard allowQueueRecovery || !entry.host.queueFailure else {
                return entry.fail(ABI.outOfMemory, "Drain the queues and reset after queue overflow.")
            }
            let status = body(entry)
            if status >= 0 {
                entry.changed()
                if entry.host.queueFailure {
                    return entry.fail(ABI.outOfMemory, "Queue overflow stopped delivery. Drain and reset; do not retry the operation.")
                }
            }
            return status
        }
    }
    func copy(_ entry: TerminalEntry, _ bytes: ArraySlice<UInt8>, _ dst: UInt32, _ capacity: UInt32) -> Int32 {
        let status = memory.copy(bytes, to: dst, capacity: capacity)
        if status < 0 { return entry.fail(status, "The destination buffer is not valid or is too small.") }
        return status
    }
}
