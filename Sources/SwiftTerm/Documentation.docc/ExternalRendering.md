# Drawing a Terminal That Runs Elsewhere

Draw a terminal whose emulator runs in another process or on another machine,
with the renderer that `TerminalView` uses.

## Overview

`TerminalView` owns a ``Terminal``: it parses the output, keeps the buffer and
draws it. Sometimes the terminal runs somewhere else. For example, a helper
process keeps the sessions alive while the app restarts, or a server runs the
terminal and the device shows it. The device then has only the visible rows
and the cursor, not a ``Terminal``.

`TerminalRenderView` draws that state. It uses the same Core Graphics and Metal
renderers as `TerminalView`, so text, colors, wide characters, bidirectional
text, selection, links and images look the same. The view does no terminal
emulation and handles no input.

The parts are:

- ``TerminalRowStore`` makes ``BufferLine`` values from the data that the
  host receives.
- ``TerminalExternalFrame`` holds the state of one frame: the grid size, the
  top line, the cursor, the palette, the selection and the images.
- ``TerminalExternalFrameSource`` gives a frame and its lines to the view.
- `TerminalRenderView` (an `NSView` on macOS, a `UIView` on iOS and visionOS)
  draws the frames.
- On macOS, ``TerminalKeyboardRouter`` turns key events into the bytes that
  `TerminalView` sends, for a host view that adopts ``TerminalKeyboardHost``.

> Note: These types are not available in `Embedded` builds. For a host that
> owns a ``Terminal`` and draws it with its own renderer, see
> <doc:PortableHosting>.

## Build the rows

A ``TerminalRowStore`` makes lines and sets their cells. All the lines of one
store share its style and grapheme tables:

```swift
let store = TerminalRowStore()
let line = store.makeLine(columns: 80)
let red = Attribute(foreground: .ansi256(code: 1), background: .defaultColor, style: [.bold])
store.setCell(line, column: 0, text: "A", width: 1, attribute: red)
store.setCell(line, column: 1, text: "漢", width: 2, attribute: .empty)
store.setCell(line, column: 2, text: nil, width: 0, attribute: .empty)
store.setLineState(line, isWrapped: false)
```

The `width` of a cell is 1 for a narrow character, 2 for the first cell of a
wide character, and 0 for the cell after a wide character. A `nil` or empty
`text` is a cell that was never written. Use
``TerminalRowStore/setLineState(_:isWrapped:renderMode:bidiState:)`` to set the
soft-wrap flag, the double-width or double-height mode and the bidi state of
a line.

You can change a line after the view drew it, or put a new line in its place.
The view compares each visible row with the row of the last frame and draws
again only the rows that changed.

The store is not thread-safe. Use the store and its lines under one lock, or
on one thread.

The style and grapheme tables only grow. When
``TerminalRowStore/isNearCapacity`` is true, make a new store, make the lines
that you keep again, and give the new store to the next frame. A cell whose
style does not fit draws with the default style.

## Supply the frames

Adopt ``TerminalExternalFrameSource``. The view calls
``TerminalExternalFrameSource/withFrame(_:)`` on the main thread, one time for
each frame that it draws. Call `body` one time with the frame, the store and a
function that returns the line for a line number:

```swift
@MainActor
final class RemoteSource: TerminalExternalFrameSource {
    let lock = NSLock()
    var store = TerminalRowStore()
    var lines: [Int: BufferLine] = [:]
    var frame = TerminalExternalFrame(
        columns: 80, rows: 24, topLine: 0,
        cursorLine: 0, cursorColumn: 0, cursorVisible: true,
        cursorStyle: .blinkBlock, isAlternateBuffer: false,
        palette: TerminalExternalFrame.makePalette())

    func withFrame(_ body: (TerminalExternalFrame, TerminalRowStore, (Int) -> BufferLine?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(frame, store) { self.lines[$0] }
    }
}
```

Obey these rules:

- Hold the lock that protects the store and its lines while `body` runs.
- Do not wait for the network in `withFrame`. The view calls it on the main
  thread. Receive the data before, and only read it in `withFrame`.
- Use one line numbering for ``TerminalExternalFrame/topLine``, the cursor and
  the selection. Any increasing numbering is correct, for example absolute
  line numbers that never repeat.
- Return `nil` for a line that you do not have. The view draws it blank.

The view also asks for lines above and below the visible rows. Bidi layout
needs the full soft-wrapped paragraph of each visible row. Return `nil` for
the lines that you do not have: the paragraph then starts or ends at the last
line that you have.

Make the palette with
``TerminalExternalFrame/makePalette(ansiColors:strategy:foreground:background:)``.
It makes the 256 colors from the 16 ANSI colors, with the same defaults as a
``Terminal`` made with ``TerminalOptions/default``. Use the same theme as the
terminal that sends the rows.

## Show the view

Make the view, give it the source, and call `requestRedraw()` when the source
has new data:

```swift
let view = TerminalRenderView(frame: bounds, font: font)
view.frameSource = source        // The view keeps a weak reference.
view.onGridSizeChange = { columns, rows in
    connection.resize(columns: columns, rows: rows)
}

// When new rows arrive, on any thread:
view.requestRedraw()
```

The view asks the source for the frame on its next display-link tick. More
calls to `requestRedraw()` before that tick make one frame only.

The view keeps a weak reference to the source. Keep the source alive. When the
source is `nil` or released, the view shows only the background color.

`onGridSizeChange` tells you when the number of columns and rows that fit in
the view changes. Send the new size to the terminal, and send frames of the
new size when the terminal resizes.

Set `hasFocus` when the view gets or loses the keyboard focus. The caret is
filled and blinks only when `hasFocus` is true. Call `resetCaretBlink()` when
the user types, so that the caret stays visible.

The view has the appearance properties of `TerminalView`, for example `font`,
`lineSpacing`, `nativeForegroundColor`, `nativeBackgroundColor`, `caretColor`,
`minimumContrastRatio` and `bidiHostPolicy`. Call `setUseMetal(_:)` to draw
with the Metal renderer. If the device has no Metal support, the method
throws ``MetalError`` and the view continues with Core Graphics.

### Hit testing

The view gives the geometry for selection, links and the mouse:

- `cellSize`, `gridSize` and `gridSize(for:)` give the size of a cell and of
  the grid.
- `cell(at:)` gives the cell under a point, and `rect(column:row:width:)` gives
  the rectangle of a run of cells. Row 0 is the top row.
- `logicalColumn(forVisualColumn:row:)` and
  `visualColumn(forLogicalColumn:row:)` convert columns on rows that bidi
  reorders. Use the logical column to select text or to send a mouse event.
- `baseDirection(row:)` gives the direction of the paragraph of a row.

The view does not select text and does not scroll. Show the selection with
``TerminalExternalFrame/selection``, and show scrollback with a different
``TerminalExternalFrame/topLine``.

### Progress reports

`showProgress(_:duration:)` shows an OSC 9;4 progress report as a bar at the
top of the view, as `TerminalView` does. The bar goes away on a `.remove`
report, or `duration` seconds after the last report. If you show a report that
came before, give the time that is left as the duration.

On the terminal side, use
``Terminal/observeOscEvents(codes:_:)`` with `codes: [9]` to get these reports.
The terminal copies the payload only for the codes that you observe, so large
payloads of other codes, for example images, stay cheap.

## Show images

Put the inline images (Sixel and iTerm2) of each line in
``TerminalExternalFrame/images``, by line number. Each
``TerminalExternalImage`` is one slice of an image on one line: the view draws
it at its column, from the top of the row, at its size in points.

Keep the same ``TerminalExternalImage`` object while the slice does not
change. The renderers keep their textures by object identity, so a new object
for the same slice makes the renderer load the texture again.

If the terminal side adds images with
``Terminal/insertRasterImage(_:cellWidth:cellHeight:width:height:preserveAspectRatio:)``,
use ``Terminal/rasterImageSlices(atRow:)`` to get the slices of a line. Hold
``Terminal/terminalLock`` while you read them.

For Kitty graphics, set ``TerminalExternalFrame/kitty`` to the value of
``Terminal/kittyGraphicsRenderSnapshot()``, with the placement rows relative to
``TerminalExternalFrame/topLine``. The view does not draw a placement whose
image is not in ``KittyGraphicsRenderSnapshot/imagesById``.

## Send keys on macOS

The keyboard behavior of `TerminalView` is in ``TerminalKeyboardRouter``. Use
the same router in your host view, so that a key gets to the program as the
same bytes as in `TerminalView`. This includes the Kitty keyboard protocol,
input methods, Option as Meta and the arrow swap of right-to-left paragraphs.

Adopt ``TerminalKeyboardHost`` in your view, make a router, and call it from
the event methods of the view:

```swift
final class RemoteTerminalView: TerminalRenderView, TerminalKeyboardHost {
    lazy var router = TerminalKeyboardRouter(host: self)
    var keyboardModes = TerminalKeyboardModes()
    var optionAsMetaKey = true
    var backspaceSendsControlH = false
    var shouldSendCommandKeyToTerminal: ((NSEvent) -> Bool)?
    var swapsHorizontalArrowKeys: Bool { false }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { router.keyDown(event) }
    override func keyUp(with event: NSEvent) { router.keyUp(event) }
    override func flagsChanged(with event: NSEvent) {
        router.flagsChanged(event)
        super.flagsChanged(with: event)
    }

    func keyboardRouterKeyDown(_ event: NSEvent) { resetCaretBlink() }
    func keyboardRouter(send event: TerminalKeyEvent, bytes: [UInt8]) { connection.send(key: event, bytes: bytes) }
    func keyboardRouter(send bytes: [UInt8]) { connection.send(bytes) }
    func keyboardRouter(sendText text: String) { connection.send(text: text) }
    func keyboardRouterScrollPage(up: Bool) { connection.scrollPage(up: up) }
}
```

For input methods, adopt `NSTextInputClient` and call
``TerminalKeyboardRouter/insertText(_:)``,
``TerminalKeyboardRouter/doCommand(_:)`` and
``TerminalKeyboardRouter/markedTextChanged(composing:)`` from it. Call
``TerminalKeyboardRouter/performKeyEquivalent(_:)`` from
`performKeyEquivalent(with:)`, ``TerminalKeyboardRouter/focusLost()`` when the
view resigns first responder, and
``TerminalKeyboardRouter/textWillBePasted()`` before a paste.

### Keep the modes current

The router encodes each key with ``TerminalKeyboardHost/keyboardModes``. Read
``Terminal/hostInputModes`` on the terminal side, send it with the frames, and
make the modes with ``TerminalKeyboardModes/init(hostInputModes:)``.

The modes can change after the router encodes a key and before the key gets to
the terminal. For this reason, ``TerminalKeyboardHost/keyboardRouter(send:bytes:)``
gives the key as a ``TerminalKeyEvent`` with the bytes. On the terminal side:

- If the modes did not change, send the bytes to the program.
- If the modes changed and ``TerminalKeyEvent/isText`` is true, give
  ``TerminalKeyEvent/text`` to ``Terminal/sendHostText(_:)``.
- If the modes changed, give the fields of the event to
  ``Terminal/sendHostKey(key:code:modifiers:eventType:text:shiftedKey:baseLayoutKey:composing:backspaceSendsControlH:)``.
  ``TerminalKeyEvent/hostKey`` gives the `key` and `code` values. The terminal
  then encodes the key with its modes at that time.

Set ``TerminalKeyboardHost/swapsHorizontalArrowKeys`` to true when the program
set DECSET 1243 and the paragraph of the cursor is drawn right to left.
``Terminal/hostInputModes`` does not include DECSET 1243: send
``Terminal/bidiArrowKeySwap`` with the frames too. Use `baseDirection(row:)` of
the view, with the screen row of the cursor, for the direction.

There is no keyboard router for iOS and visionOS. On these platforms, send the
text and the keys of your `UIKeyInput` adoption with
``Terminal/sendHostText(_:)`` and ``Terminal/sendHostKey(key:code:modifiers:eventType:text:shiftedKey:baseLayoutKey:composing:backspaceSendsControlH:)``
on the terminal side.

## Topics

### Rows

- ``TerminalRowStore``
- ``BufferLine``
- ``Attribute/init(foreground:background:style:underlineStyle:underlineColor:)``

### Frames

- ``TerminalExternalFrameSource``
- ``TerminalExternalFrame``
- ``TerminalExternalSelection``
- ``TerminalExternalImage``

### Keyboard Input on macOS

- ``TerminalKeyboardRouter``
- ``TerminalKeyboardHost``
- ``TerminalKeyboardModes``
- ``TerminalKeyEvent``

### Terminal Side

- ``Terminal/hostInputModes``
- ``Terminal/sendHostKey(key:code:modifiers:eventType:text:shiftedKey:baseLayoutKey:composing:backspaceSendsControlH:)``
- ``Terminal/sendHostText(_:)``
- ``Terminal/rasterImageSlices(atRow:)``
- ``Terminal/kittyGraphicsRenderSnapshot()``
- ``Terminal/observeOscEvents(codes:_:)``
