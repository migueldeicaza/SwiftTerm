import SwiftTerm

/// Delegate callbacks only store bytes and values. They never call JavaScript.
final class WasmTerminalHost: TerminalDelegate {
    let clipboard = WasmClipboardState()
    var output = ByteQueue()
    var events = HostEventQueue()
    var queueFailure = false
    var forceFull = true
    var focused = true
    var cellWidth = 0
    var cellHeight = 0
    var cursorStyle: CursorStyle = .blinkBlock
    var cursorVisible = true
    let graphics = WasmGraphicsState()
    var synchronizedOutputDeadline: UInt64?

    func event(_ type: UInt16, _ payload: [UInt8] = []) {
        if !events.append(type: type, payload: payload) { queueFailure = true }
    }
    func words(_ type: UInt16, _ values: [UInt32]) {
        var payload: [UInt8] = []
        for value in values { payload.append32(value) }
        event(type, payload)
    }
    func text(_ type: UInt16, _ value: String) {
        guard value.utf8.count <= ABI.maximumControl else { queueFailure = true; return }
        event(type, Array(value.utf8))
    }
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        if !output.append(data) { queueFailure = true }
    }
    func bell(source: Terminal) { event(1) }
    func setTerminalTitle(source: Terminal, title: String) { text(2, title) }
    func setTerminalIconTitle(source: Terminal, title: String) { text(3, title) }
    func hostCurrentDirectoryUpdated(source: Terminal) { text(4, source.hostCurrentDirectory ?? "") }
    func hostCurrentDocumentUpdated(source: Terminal) { text(13, source.hostCurrentDocument ?? "") }
    func notify(source: Terminal, title: String, body: String) {
        // This is a request event. The host must opt in before it shows a notification.
        let titleLength = title.utf8.count
        let bodyLength = body.utf8.count
        guard titleLength <= ABI.maximumControl, bodyLength <= ABI.maximumControl - titleLength else {
            queueFailure = true; return
        }
        var payload: [UInt8] = []
        payload.append32(UInt32(titleLength))
        payload.append32(UInt32(bodyLength))
        payload.append(contentsOf: title.utf8)
        payload.append(contentsOf: body.utf8)
        event(5, payload)
    }
    func clipboardCopy(source: Terminal, content: TerminalData) {
        // Store a request only. This cannot change a host clipboard.
        guard content.count <= ABI.maximumControl else { queueFailure = true; return }
        event(6, Array(content))
    }
    func clipboardRead(source: Terminal) -> TerminalData? { nil }
    func isProcessTrusted(source: Terminal) -> Bool { false }
    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
        cellWidth > 0 && cellHeight > 0 ? (cellWidth, cellHeight) : nil
    }
    func sizeChanged(source: Terminal) {
        forceFull = true
        words(7, [UInt32(source.cols), UInt32(source.rows)])
    }
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        switch command {
        case .resizeTerminal(let cols, let rows):
            if cols >= 2 && cols <= 1024 && rows >= 1 && rows <= 1024 {
                words(7, [UInt32(cols), UInt32(rows)])
            }
        default: break
        }
        return nil
    }
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        cursorStyle = newStyle
        let value = ABI.cursor(newStyle)
        event(8, [value.shape, value.blink, cursorVisible ? 1 : 0, 0])
    }
    func showCursor(source: Terminal) { cursorVisible = true }
    func hideCursor(source: Terminal) { cursorVisible = false }
    func bufferActivated(source: Terminal) { forceFull = true }
    func colorChanged(source: Terminal, idx: Int?) {
        forceFull = true
        let rgba = idx.flatMap { source.paletteColor(index: $0) }.map { SnapshotEncoder.color($0) } ?? UInt32.max
        words(9, [idx == nil ? 4 : 3, idx.map { UInt32(clamping: $0) } ?? UInt32.max, rgba])
    }
    func setForegroundColor(source: Terminal, color: Color) {
        source.foregroundColor = color
        forceFull = true
        words(9, [0, UInt32.max, ABI.color(color)])
    }
    func setBackgroundColor(source: Terminal, color: Color) {
        source.backgroundColor = color
        forceFull = true
        words(9, [1, UInt32.max, ABI.color(color)])
    }
    func setCursorColor(source: Terminal, color: Color?) {
        source.cursorColor = color
        forceFull = true
        words(9, [2, UInt32.max, color.map { ABI.color($0) } ?? UInt32.max])
    }
    func getColors(source: Terminal) -> (foreground: Color, background: Color) {
        (source.foregroundColor, source.backgroundColor)
    }
    func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        words(10, [UInt32(report.state.rawValue), report.progress.map { UInt32($0) } ?? UInt32.max])
    }
    func synchronizedOutputChanged(source: Terminal, active: Bool) {
        if !active { synchronizedOutputDeadline = nil }
        words(11, [active ? 1 : 0])
    }
    func scheduleSynchronizedOutputTimeout(source: Terminal, afterMilliseconds: UInt32) {
        synchronizedOutputDeadline = monotonicMilliseconds() + UInt64(afterMilliseconds)
    }
    func mouseModeChanged(source: Terminal) {
        let value: UInt32
        switch source.mouseMode {
        case .off: value = 0
        case .x10: value = 1
        case .vt200: value = 2
        case .buttonEventTracking: value = 3
        case .anyEvent: value = 4
        }
        words(14, [value])
    }
}
