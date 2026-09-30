# Web keyboard, mouse, and selection implementation

Implemented on 11 September 2026. This record replaces the plan first written
after commit `fb1084e`. The input APIs, shared browser controller, sample
integration, and selection overlay are implemented. Browser and live-shell
validation are tracked separately below.

## Completed scope

| Area | Result |
| --- | --- |
| Keyboard | Stable unshifted key identity, shifted and base-layout alternates, press/release ownership, and committed text |
| Browser input | One reusable `TerminalInputController` for each canvas and textarea |
| Mouse | Semantic WASM input, exact X10 press behavior, and released-button identity in SGR |
| Selection | One core service per terminal, exclusive visible spans, Unicode text, and local copy |
| Scrollback | Public viewport state, clamped scroll operations, wheel routing, and selection autoscroll |
| Focus | The input controller owns terminal focus and visibility |

Both Full and Embedded use this path:

```text
DOM event → input controller → Swift input service → output queue
Output queue → ShellClient.pump → WebSocket → PTY
```

The controller chooses browser shortcuts, local selection, or terminal input.
The Swift core encodes terminal sequences. The sample owns transport and remote
clipboard-request UI. Local copy is separate from OSC 52 and Kitty clipboard
requests.

## Keyboard and focus

[Web/src/keyboard.ts](../Web/src/keyboard.ts) records each key press and its
route. Releases retain the key identity used for the press. Browser shortcuts
and composition keys do not produce unmatched terminal releases. Key
normalization keeps shifted and base-layout alternates separate from text.

`sendKeyResult()` returns `text`, `sent`, or `ignored`. Only `text` needs browser
text fallback. The compatible `sendKey()` boolean remains false only for text
fallback. `sendText()` submits committed text through the core. Kitty flags 24
and 31 encode a text-only event with key zero. Paste keeps its separate core
policy and framing.

The optional Keyboard Map API and observed unmodified keys supply layout data.
The host can supply an explicit `layout` map. A physical key code alone cannot
identify the active layout. Printable AltGraph and macOS Option composition
remain text input unless the host enables `optionAsMeta`.

[Web/src/input.ts](../Web/src/input.ts) owns the textarea, composition state,
pressed keys, pointer state, and DOM listeners. It reports terminal focus only
while the textarea has focus in the active, visible document. Focus on another
page control clears terminal focus. Blur and disposal end active gestures and
clear composition and key state. Visibility remains separate from focus.

## Mouse, wheel, and viewport

`sendMouse()` accepts action, button, modifiers, cell coordinates, and pixel
coordinates. Both coordinate systems are zero-based and viewport-relative.
Pixels use logical screen dimensions, without device-pixel scaling. The core
converts coordinates for the active protocol. X10 sends presses only. SGR and
pixel SGR retain the released button.

The controller converts CSS coordinates using logical cell metrics and the row
width multiplier. It keeps the selected route for a complete pointer gesture.
Shift starts local selection unless the application requests Shift capture.
Local selection sends no mouse packets. Pointer capture keeps release handling
active outside the canvas. Motion suppression uses cells for cell protocols
and pixels for pixel SGR.

Wheel input accepts pixel, line, and page units. It keeps fractional movement
and resets it when the route changes. It uses application mouse tracking,
alternate-screen cursor keys under mode 1007, or normal scrollback.

`scrollViewport(lines)` moves by signed lines; positive values scroll down.
`scrollViewportTo(topRow)` uses a buffer row. Both clamp to valid bounds and
update user-scrolling state. `viewportState()` returns top row, maximum top
row, and the alternate-screen flag.

## Selection and copy

[TerminalViewport.swift](../Sources/SwiftTerm/Portable/TerminalViewport.swift)
exposes portable viewport and selection operations. Each WASM entry owns a
`SelectionService`. Calls hold the terminal lock. Feed-owner checks compare
selected cells once per feed batch. There is no new per-byte parser work.
The Embedded terminal close lifecycle remains in place.

`selectionBegin()` supports character, word, row, and Shift-extension modes.
`selectionExtend()`, `selectionClear()`, and `selectionAll()` complete the API.
Pointer coordinates identify visible cells. Character selection includes the
anchor and target cells. Wide-cell continuations select complete characters.
Core text extraction preserves combining characters and emoji and joins soft
wraps. Select all and copied text include scrollback.

`selectionState()` supplies copied visible spans and a separate generation.
Span ends are exclusive. The renderer draws selection as an overlay without
changing cached cell records. A selection change requests a frame even when
terminal cells are clean. `selectionText()` copies core-selected text, including
selected rows outside the viewport.

Selection follows valid text during scrolling. Expired or changed selected
content clears the range. Resize, reset, and a buffer switch clear it. Dragging
outside the view starts bounded autoscroll. Release, cancellation, lost capture,
disconnect, or disposal ends the gesture. The browser `copy` event supplies
plain text only when a local selection exists.

## Public integration and ABI

The sample and standalone Web example use `TerminalInputController`. The host
supplies `geometry()`, transport gating through `canInput()`, output handling
through `onInput()`, and overlay updates through `onSelection()`. Optional
`onPaste()` and `shortcut()` callbacks supply host policy. Call `refresh()` after
PTY output, resize, or transport-pressure changes. Dispose the controller
before its terminal.

ABI version 1 keeps its existing record layouts. Capability 64 supplies mouse
input and pointer state; 16384 supplies committed text; 32768 supplies selection
and viewport operations. New exports have strict loader and build checks. The
worker adapter supplies matching engine operations.

Selection state uses a 32-byte little-endian header and 12-byte visible spans.
The header contains version, revision, viewport bounds, flags, and span count.
Each span contains row, start column, and exclusive end column. State and text
size calls refresh separate owned buffers. Copy calls preserve those buffers
until the next size call. See [Docs/wasm.md](wasm.md) for field offsets and export
arguments, and [Web/README.md](../Web/README.md) for API and controller examples.

## Validation status

| Check | Status |
| --- | --- |
| Native text encoder: flags 0, 1, 2, 3, 8, 10, 24, 31 | Passed |
| Native X10, SGR release, motion, and pointer state | Passed |
| Portable selection and existing selection regression suites | Passed |
| Native WASM facade and selection buffers | Passed |
| Full and Embedded interaction tests | All 20 passed; complete Web suite: 96 passed |
| Browser focus, pointer, wheel, geometry, and composition events | Chromium and WebKit passed on both builds; Firefox could not complete startup in this environment |
| Live shell, raw Kitty input probe, and Midnight Commander mouse input | Passed on Full and Embedded |
| Native IME and dead-key input | Manual checks remain necessary |

The interaction tests check exact text and mouse bytes; invalid arguments;
last-cell and one-cell ranges; wide, combining, and emoji cells; soft wraps;
word, row, and Shift selection; visible spans; copied history; viewport bounds;
content changes; resize; buffer switches; history eviction; and stable buffers.
They run with `node --test Tests/WebWasmTests/interaction.test.mjs`.

The live Chromium test checks shell typing, Control-C, exact Kitty Shift+A
press and release bytes, Midnight Commander menu clicks, and right-button
dragging. It passes against both runtime variants. The sample's 23 server
tests and 11 client tests also pass. Firefox needs a run on a host where its
test browser can start.

Keep manual checks for dead acute plus e, multi-character Japanese composition,
cancel, Enter commit, and duplicate input. Synthetic browser events cannot
verify native IME candidate windows or every OS event sequence. Input latency,
pointer cost, and frame throughput are measured separately from correctness.

### Input measurements

Headless Chromium 140 on an Apple M3 Ultra, DPR 2, 11 September 2026.
Each action uses 2,000 warmup samples and three rounds of 10,000 samples.
The clock step is approximately 5 µs.

| Action | Full mean / p95 | Embedded mean / p95 |
| --- | --- | --- |
| Key press and release pair | 21.6 / 25 µs | 20.2 / 25 µs |
| Hover pointer move | 6.8 / 10 µs | 6.3 / 10 µs |

These measurements include DOM dispatch, the controller, WASM encoding,
output copy and consume, and selection refresh. They exclude event creation,
canvas drawing, transport, and PTY response. Some maximum samples reached
4–5 ms. There is no earlier controller baseline or regression threshold.
Run `npm --prefix Web run benchmark` for separate frame throughput checks.

## Deferred work

- Rectangular selection.
- Exact selection preservation across resize reflow. This needs an anchor map.
- Word selection across wrapped rows.
- Screen-reader terminal output.
