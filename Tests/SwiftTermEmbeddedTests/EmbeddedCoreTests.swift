import Testing
@testable import SwiftTerm

private final class EmbeddedTerminalDelegate: TerminalDelegate {
    var sentBytes: [UInt8] = []
    var copiedBytes: [UInt8] = []
    var clipboardBytes: [UInt8]?
    var timeoutMilliseconds: UInt32?
    func send(source: Terminal, data: ArraySlice<UInt8>) { sentBytes.append(contentsOf: data) }
    func clipboardCopy(source: Terminal, content: TerminalData) { copiedBytes = content }
    func clipboardRead(source: Terminal) -> TerminalData? { clipboardBytes }
    func scheduleSynchronizedOutputTimeout(source: Terminal, afterMilliseconds: UInt32) { timeoutMilliseconds = afterMilliseconds }
}

@Test func embeddedCoreParsesTextAndCursorMovement() {
    let delegate = EmbeddedTerminalDelegate()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 8, rows: 2, scrollback: 0))
    defer { terminal.close() }
    terminal.feed(text: "hello\u{1b}[2;1Hworld")
    #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == "hello\nworld\n")
}

@Test(arguments: ["界x", "😀x", "e\u{301}x", "👩🏽‍💻x"])
func embeddedBufferExportPreservesCharacters(_ text: String) {
    let delegate = EmbeddedTerminalDelegate()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 12, rows: 1, scrollback: 0))
    defer { terminal.close() }
    terminal.feed(text: text)

    #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == text + "\n")
}

@Test func embeddedBufferExportConvertsEmptyCellsToSpaces() {
    let delegate = EmbeddedTerminalDelegate()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 12, rows: 1, scrollback: 0))
    defer { terminal.close() }
    terminal.feed(text: "\u{1b}[10Gx")

    #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == "         x\n")
}

@Test func embeddedBufferExportPreservesSpacesAndRows() {
    let delegate = EmbeddedTerminalDelegate()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 4, rows: 3, scrollback: 0))
    defer { terminal.close() }
    terminal.feed(text: " a  bc\r\n")

    #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == " a  \nbc\n\n")
}

@Test func embeddedBufferExportSelectsBuffersAndIncludesScrollback() {
    let delegate = EmbeddedTerminalDelegate()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 12, rows: 2, scrollback: 5))
    defer { terminal.close() }
    terminal.feed(text: "界x\r\nline\r\n\u{1b}[10Gx")
    let normalText = "界x\nline\n         x\n"
    #expect(terminal.normalBuffer.yBase > 0)
    #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == normalText)

    terminal.feed(text: "\u{1b}[?1049h\u{1b}[Halt 界")
    let altText = "alt 界\n\n"
    #expect(String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self) == normalText)
    #expect(String(decoding: terminal.getBufferAsData(kind: .alt), as: UTF8.self) == altText)
    #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == altText)

    terminal.feed(text: "\u{1b}[?1049l")
    #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == normalText)
}

@Test func embeddedCoreHandlesClipboardBase64() {
    let delegate = EmbeddedTerminalDelegate()
    delegate.clipboardBytes = [0, 1, 2, 253, 254, 255]
    let terminal = Terminal(delegate: delegate)
    defer { terminal.close() }
    terminal.feed(text: "\u{1b}]52;c;?\u{1b}\\")
    #expect(String(decoding: delegate.sentBytes, as: UTF8.self) == "\u{1b}]52;c;AAEC/f7/\u{1b}\\")
    terminal.feed(text: "\u{1b}]52;c;AAEC/f7/\u{1b}\\")
    #expect(delegate.copiedBytes == [0, 1, 2, 253, 254, 255])
}

@Test func embeddedCoreRequestsSynchronizedOutputTimeout() {
    let delegate = EmbeddedTerminalDelegate()
    let terminal = Terminal(delegate: delegate)
    defer { terminal.close() }
    terminal.feed(text: "\u{1b}[?2026h")
    #expect(delegate.timeoutMilliseconds == 1_000)
    #expect(terminal.synchronizedOutputActive)
    terminal.expireSynchronizedOutput()
    #expect(!terminal.synchronizedOutputActive)
}

@Test func embeddedCorePreservesGraphemeScalars() {
    let delegate = EmbeddedTerminalDelegate()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 8, rows: 2, scrollback: 0))
    defer { terminal.close() }
    let text = "\u{0915}\u{094d}\u{0915}"
    terminal.feed(text: text)
    #expect(terminal.getCharData(col: 0, row: 0)?.getText() == text)
}

@Test func embeddedCoreScrollsRegionAndResets() {
    let delegate = EmbeddedTerminalDelegate()
    let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 8, rows: 3, scrollback: 0))
    defer { terminal.close() }
    terminal.feed(text: "top\r\nmiddle\r\nbottom\u{1b}[2;3r\u{1b}[3;1H\n")
    #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == "top\nbottom\n\n")
    terminal.feed(text: "\u{1b}c")
    #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self) == "\n\n\n")
}

@Test func embeddedCoreDoesNotAdvertiseKittyClipboardTransport() {
    let delegate = EmbeddedTerminalDelegate()
    let terminal = Terminal(delegate: delegate)
    defer { terminal.close() }
    terminal.feed(text: "\u{1b}[?5522h\u{1b}[?5522$p")
    #expect(!terminal.kittyPasteEventsEnabled)
    #expect(String(decoding: delegate.sentBytes, as: UTF8.self) == "\u{1b}[?5522;0$y")
}
