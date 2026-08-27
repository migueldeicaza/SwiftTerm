# ``Terminal``

The core terminal emulation engine.

## Overview

`Terminal` is the main class that implements VT100/Xterm terminal emulation. It
manages the terminal buffer, processes escape sequences, tracks cursor state, and
notifies its ``TerminalDelegate`` of events.

`Terminal` is UI-agnostic — it can be used with the bundled AppKit and UIKit views,
with a headless backend, or with a custom renderer. All input flows through the
``feed(buffer:)`` family of methods, and output is delivered through the delegate's
``TerminalDelegate/send(source:data:)`` callback.

Use ``terminalLock`` to serialize direct access from different threads. The
bundled views and ``HeadlessTerminal`` manage this lock for their operations.
When you use a `Terminal` directly, hold the lock while you feed, query, or
change terminal state.

## Topics

### Creating a Terminal

- ``init(delegate:options:)``

### Synchronizing Access

- ``terminalLock``

### Configuration

- ``options``
- ``cols``
- ``rows``
- ``applicationCursor``
- ``bracketedPasteMode``
- ``silentLog``
- ``foregroundColor``
- ``backgroundColor``
- ``cursorColor``
- ``currentAttribute``
- ``mouseMode``

### Feeding Input

- ``feed(byteArray:)``
- ``feed(text:)``
- ``feed(buffer:)``
- ``parse(buffer:)``

### Sending Responses

- ``sendResponse(text:)``
- ``sendResponse(_:)``

### Buffer Access

- ``buffer``
- ``BufferKind``
- ``isCurrentBufferAlternate``
- ``getBufferAsData(kind:encoding:)``
- ``getText(start:end:)``
- ``getCharData(col:row:)``
- ``getLine(row:)``
- ``getScrollInvariantLine(row:)``
- ``getCharacter(col:row:)``
- ``getCharacter(for:)``

### Resize and Layout

- ``resize(cols:rows:)``
- ``getDims()``
- ``changeScrollback(_:)``
- ``changeHistorySize(_:)``

### Terminal State

- ``setup(isReset:)``
- ``softReset()``
- ``resetToInitialState()``
- ``resetNormalBuffer()``
- ``hostCurrentDirectory``
- ``hostCurrentDocument``

### Bidirectional Text

- ``currentBidiState``
- ``bidiArrowKeySwap``
- ``bidiSupportEnabled``
- ``bidiAutodetectDirection``
- ``bidiRTLPreference``
- ``bidiBoxMirroring``

### Cursor

- ``getCursorLocation()``
- ``setCursorStyle(_:)``
- ``showCursor()``
- ``hideCursor()``

### Scrolling

- ``scroll(isWrapped:)``
- ``emitLineFeed()``
- ``getTopVisibleRow()``

### Display Updates

- ``refresh(startRow:endRow:)``
- ``updateFullScreen()``
- ``getUpdateRange()``
- ``getScrollInvariantUpdateRange()``
- ``clearUpdateRange()``

### Mouse Events

- ``MouseMode``
- ``encodeButton(button:release:shift:meta:control:)``
- ``sendEvent(buttonFlags:x:y:)``
- ``sendEvent(buttonFlags:x:y:pixelX:pixelY:)``
- ``sendMotion(buttonFlags:x:y:pixelX:pixelY:)``

### Titles

- ``setTitle(text:)``
- ``setIconTitle(text:)``

### Focus

- ``setTerminalFocus(_:)``

### Colors

- ``ansi256PaletteStrategy``
- ``installPalette(colors:)``

### CharData Factories

- ``makeCharData(attribute:code:size:)``
- ``makeCharData(attribute:char:size:)``
- ``makeCharData(attribute:scalar:size:)``
- ``updateCharData(_:char:size:)``
- ``updateCharData(_:code:size:)``
- ``makePayload(value:)``

### Housekeeping

- ``garbageCollectPayload()``

### Parser Extension

- ``registerOscHandler(code:handler:)``

### Kitty Graphics

- ``kittyGraphicsRenderSnapshot()``
- ``kittyGraphicsAdvanceAnimations(monotonicNanoseconds:)``

### Environment

- ``getEnvironmentVariables(termName:trueColor:)``

### Progress Reporting

- ``ProgressReport``
- ``ProgressReportState``

### Window Manipulation

- ``WindowManipulationCommand``

### Image Sizing

- ``ImageSizeRequest``
