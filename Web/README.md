# SwiftTerm WASM

This package supplies a terminal engine. The host supplies the renderer and PTY transport. The package has no runtime dependencies.

Run `npm ci` in this directory. Build the WASM artifacts with the commands in [Docs/wasm.md](../Docs/wasm.md). Each artifact build also builds the TypeScript package.

```js
import { loadSwiftTerm } from '@swiftterm/wasm';

const module = await loadSwiftTerm({ wasmURL: '/swiftterm-full.wasm' });
const terminal = module.createTerminal({ cols: 80, rows: 24 });
terminal.write(new Uint8Array([72, 105])); // Process output goes into the terminal.
const frame = terminal.snapshot();
// Draw frame.rowData with your renderer.
terminal.markFrameRendered(frame.generation); // Only after a successful draw.
terminal.dispose();
```

One module can own many terminals. Each terminal method is synchronous. The wrapper rejects a reentrant call. After `dispose()`, only another `dispose()` call is valid.

In Node, pass bytes instead of a URL:

```js
import { readFile } from 'node:fs/promises';
const module = await loadSwiftTerm({ wasm: await readFile('./swiftterm-full.wasm') });
```

`write()` accepts process output, as UTF-8 bytes or a string. It does not encode keyboard input. To return terminal replies to a PTY, call `readOutput()`. This copies the queue without removing bytes. Call `consumeOutput(bytes.length)` only after the transport accepts those bytes. Do not consume them if the send fails.

`drainEvents()` copies and removes queued host events. For retry control, use `peekEvent()` and `consumeEvent()`. A notification or clipboard event is a request. This package does not show notifications or change the clipboard. The host must opt in. Clipboard services are disabled until the host calls `configureClipboard()`. Trust-based operations remain denied. Thus, untrusted OSC 6 and OSC 7 input does not emit current-document or current-directory events.

Snapshots own copied values. No snapshot contains WASM memory views. A full frame includes all rows. A partial frame includes only the rows to draw. Included rows are authoritative. A clean frame has no rows. The scroll-invariant range uses absolute buffer row coordinates; the normal dirty range uses visible row coordinates.

When `snapshot.synchronizedOutput` is true, defer drawing and do not mark the frame clean. Keep requesting snapshots on animation frames. These calls let the reactor service the synchronization timeout even when no more input arrives. Draw and mark the pending frame clean after synchronized output ends or times out.

Colors are resolved `0xRRGGBBAA` integers. Do not invert them again when the inverse style bit is set. Width is supplied by the engine. A wide-cell tail has width zero and empty text. `SwiftTermError.code` identifies status errors, stale frames, disposed terminals, and invalid records.

A failed write can have applied part of the input before a queue limit was reached. Do not retry that write. Drain accepted queue data and reset the terminal to recover from the latched queue error. The ABI limits each write to 16 MiB, each output or event queue to 8 MiB, and each snapshot to 256 MiB.

Serve the repository root and open `Web/example/index.html` for the Canvas example. Add `?variant=embedded` to select Embedded. Canvas text metrics, shaping, font fallback, BiDi, ligatures, and emoji can differ from the native renderer. The example has a local data stream; it does not start a shell. The renderer scales for device pixels and owns cursor blink timing.

`example/worker.ts` shows a module worker with serialized messages. Send `init`, then `write`, `snapshot`, and `clean` messages. Pass the snapshot generation back with `clean` only after the main thread draws the frame. Send `output` and then `consumeOutput` after a successful transport send. Each response includes the request `id`. Dispose the terminal before you terminate the worker.

Run `npm test` for decoder, wrapper, ABI, and corpus tests. Set `REQUIRE_WASM=1` to fail when an artifact is missing. Set `SWIFTTERM_NATIVE_SNAPSHOT` to the native reference executable for three-way corpus checks. `npm run test:browser` runs Chromium, Firefox, and WebKit; install them first with `npx playwright install`. Use `BROWSERS=chromium` to select one browser. `PLAYWRIGHT_MODULE_PATH` can select a local Playwright installation.

`npm run benchmark` reports frame time, snapshot byte size, host-buffer allocation calls, WASM memory growth, and JavaScript heap change. The allocation count excludes internal Swift allocations. Heap change is not an allocation count. Use `BENCHMARK_OUTPUT=/path/results.json` to save the results. These measurements have no regression threshold yet.

## Keyboard, pointer, and selection input

Full and Embedded support the same input and selection APIs. Input bytes use the core encoder and enter the output queue. Send them to the PTY with `readOutput()` and `consumeOutput()`.

- `sendKeyResult(event)` returns `text`, `sent`, or `ignored`. For `text`, let the browser supply committed text. For `sent`, the core queued the key. For `ignored`, no text fallback is needed. The older `sendKey(event)` returns false only for `text`.
- `sendText(text)` submits committed text, including an IME result. It uses the current Kitty keyboard modes. It does not add paste markers. Each call is limited to 64 KiB of UTF-8.
- `paste(text, options)` uses the core paste policy and current paste modes. A rejected multiline paste needs a separate user action before `allowUnsafe: true`; do not set this flag by default. A paste queues the complete batch, including bracket markers or Kitty paste packets.
- `inputState()` includes keyboard modes, `mouseMode`, `mouseProtocol`, `mouseShiftCapture`, `alternateScroll`, and `alternateScreen`. `inputModes()` remains available for keyboard and paste state.

For direct key calls, use the unshifted character as `key`. Supply committed text separately in `text`, and alternate scalar values in `shiftedKey` and `baseLayoutKey`. Keep the same key identity for its release. A physical `code` alone does not identify the active keyboard layout. The controller below does this work for browser events.

`sendMouse(event)` takes an action (`press`, `release`, `move`, or `wheel`), a button, modifiers, and cell and pixel coordinates. It returns true when the core sends the event. All coordinates are zero-based and relative to the viewport. `pixelX` and `pixelY` use logical pixels, before device-pixel scaling. Supply the logical cell size through `resize(cols, rows, cellWidth, cellHeight)`. Mouse modifier bits are Shift=1, Alt=2, Control=4, and Super=8; the encoder ignores Super.

| Button | Meaning |
| --- | --- |
| 0, 1, 2 | Left, middle, right |
| 3 | No pressed button, for motion |
| 4, 5 | Wheel up, down |
| 6, 7 | Wheel left, right |

X10 reports presses only. SGR and pixel SGR retain the released button. `sendMouse` uses the active tracking mode; the host decides whether a gesture is local selection or application mouse input.

`selectionBegin(col, row, mode)` starts a range at a visible cell. Modes are `character`, `word`, `row`, and `extend` for Shift extension. Character ranges include the anchor and target cells. A wide-cell continuation selects the complete character. Use `selectionExtend(col, row)`, `selectionClear()`, and `selectionAll()` for the remaining operations. `selectionAll()` includes scrollback.

`selectionState()` returns an owned snapshot with a separate `generation`, `active`, viewport state, and visible `spans`. Each span has `row`, `startCol`, and `endCol`; `endCol` is excluded. Draw these spans as a selection overlay. A selection change can need a draw even when the cell snapshot is clean. `selectionText()` uses core text extraction. It includes selected history outside the viewport and joins soft wraps.

`scrollViewport(lines)` uses positive values to scroll down. `scrollViewportTo(topRow)` uses a buffer row. Both clamp to the history bounds. `viewportState()` returns `topRow`, `maximumTopRow`, and `alternateScreen`. Selection follows valid content during scrolling. Expired or changed selected content clears the selection. Resize, buffer switch, and reset also clear it. Rectangular selection, exact selection preservation across reflow, and words across wrapped rows remain deferred.

## Reusable browser controller

Use one `TerminalInputController` for each terminal canvas and textarea. It owns keyboard, composition, pointer capture, wheel, copy, paste, and focus listeners. The sample and Canvas example use this controller.

```js
import { TerminalInputController } from '@swiftterm/wasm';

const input = new TerminalInputController(terminal, canvas, textarea, {
  geometry: () => renderer.inputGeometry,
  canInput: () => transportReady,
  onInput: () => { pumpPTYOutput(); renderer.requestFrame(); },
  onSelection: state => renderer.setSelection(state),
  onError: error => showInputError(error),
});
renderer.onDraw = () => input.refresh();
// The host supplies transportReady, pumpPTYOutput, and showInputError.
// After PTY output, resize, or a transport-pressure change:
input.refresh();
// Before the host destroys the terminal:
input.dispose();
```

`geometry()` supplies `cols`, `rows`, `cellWidth`, and `cellHeight` in logical pixels. Supply current grid dimensions after resize, including before the next draw. Optional `rowScale(row)` supplies the width multiplier for doubled rows. Optional `cursor` places the IME candidate window near the cursor. The Canvas renderer's `onDraw` callback updates that position after each frame. The controller accounts for the canvas CSS rectangle; do not multiply coordinates by device-pixel ratio.

`canInput()` gates terminal input while the transport cannot accept it. `onInput()` lets the host drain output and request a frame. `onSelection(state)` updates the overlay. `onPaste(text, event)` can replace default paste handling with host approval UI. Call `refresh()` when output, geometry, or transport pressure changes. Dispose the controller before the terminal on disconnect or replacement.

The controller reports terminal focus only while its textarea has focus in the active, visible document. A button in the same page does not count as terminal focus. Visibility remains separate. Blur clears pressed-key and composition state and ends pointer gestures.

The default shortcut policy keeps browser copy, paste, navigation, and zoom shortcuts. `shortcut(event)` replaces that policy: return true to keep the press and its release outside the terminal. Call exported `defaultKeyboardShortcut(event)` when adding host shortcuts to the defaults. Command+A and Control+Shift+A select all terminal content. `layout` can supply unshifted characters indexed by `KeyboardEvent.code`. The optional browser Keyboard Map API and observed keys improve layout information. `optionAsMeta` makes printable macOS Option combinations act as terminal Alt input.

Shift starts local selection while mouse tracking is active, unless the application requests Shift capture. Double-click selects a word; triple-click selects a row. Dragging outside the canvas scrolls selection at a bounded rate. Copy uses the browser `copy` event and core selection text. This is separate from remote OSC 52 and Kitty clipboard requests. Wheel input uses mouse tracking, alternate-screen cursor keys under mode 1007, or normal scrollback.

Automated tests cover composition event sequences. They do not replace manual checks with a native IME, including Japanese composition and dead keys.


Full supports the asynchronous clipboard extension. Call `configureClipboard(3)` only when the host can serve standard clipboard reads and atomic writes. The browser sample advertises this service when its Clipboard APIs are available. This does not access clipboard data. The **Disable clipboard** button revokes the service for the current connection. Event `clipboardRequest` has a request ID and an operation. Supply its result through `completeClipboard()`. Status values are in `ClipboardStatus`. List completions carry a UTF-8 JSON array of MIME names; read completions carry raw representation bytes; permission and write completions carry no data. A request expires after 30 seconds, and reset or disposal cancels it. Call `poll()` at regular intervals to service protocol completions and deadlines even when no PTY output arrives.

The local shell sample supports `text/plain` and `image/png` clipboard items when the browser supports them. It checks every representation before one atomic write. Other formats fail with `ENOSYS`; primary selection is not offered. Actual clipboard reads and writes need a visible action. Browser activation rules can require an extra format-read or write action. The captured clipboard is reused for follow-up reads for at most 30 seconds. OSC 52 writes have a separate copy action. OSC 52 reads preserve the requested selector. Notifications remain requests and are not shown automatically. Embedded supplies key and text-paste encoding but does not implement the Kitty clipboard protocol.

A worker has no Clipboard API. Relay its clipboard request events to the window, complete the browser operation there, and return the result with the worker `completeClipboard` message. The worker also accepts `inputModes`, `inputState`, `key`, `text`, `mouse`, `scroll`, `scrollTo`, `selectionBegin`, `selectionExtend`, `selectionClear`, `selectionAll`, `selectionState`, `selectionText`, `paste`, `poll`, `configureClipboard`, and `resetClipboard` messages. DOM input stays in the window; worker messages serialize engine operations.
