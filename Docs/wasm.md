# WebAssembly

SwiftTerm supplies a terminal engine for browsers, workers, and Node.js. The
host supplies the renderer and PTY transport. The reactor has no DOM, shell,
network, or filesystem access. Full builds decode image data in WASM.

The browser package uses a WASI reactor with ABI version 1. It has no `_start`
entry point. The TypeScript loader supplies the required WASI imports and calls
`_initialize` once. Full and Embedded use the same binary format and API.

- **Full** selects the `Wasm` trait. It includes
  Foundation, PNG decoding, Kitty graphics, Sixel, and Kitty Clipboard.
- **Embedded** selects the `Embedded` trait alone. It uses the portable core with
  Embedded Swift language restrictions. Graphics and Kitty Clipboard are
  unavailable. Key modes, committed text, mouse input, selection, scrollback,
  and bracketed paste are supported by both builds.

## Build

Use the exact compiler and SDK pair in
[`scripts/wasm-toolchain.env`](../scripts/wasm-toolchain.env):
`swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-14-a`, Swift revision
`424cae54c1a10da`. Install its WASM artifact bundle. It contains the SDK IDs
`swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-14-a_wasm` and
`swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-14-a_wasm-embedded`.
Use the [Swift installation page](https://www.swift.org/install/macos/) and
[WASM SDK guide](https://www.swift.org/documentation/articles/wasm-getting-started.html)
for installation steps. Do not mix an Xcode compiler with a snapshot SDK.

Install Node.js 22 or later, then run:

```sh
npm ci --prefix Web
scripts/build-wasm.sh full --browser --release
scripts/build-wasm.sh embedded --browser --release
```

On macOS, the script finds the pinned toolchain in
`~/Library/Developer/Toolchains`. On other hosts it checks `swift` on `PATH`.
Set `SWIFTTERM_SWIFT` to an explicit compiler path when needed. Set
`SWIFTTERM_SWIFT_SDKS_PATH` if the SDK bundles are outside
`~/.swiftpm/swift-sdks`.

The build checks the compiler revision, compiles an export probe, links a
reactor, and checks the observed import and export tables against the checked-in
allowlists. It uses the SDK Clang resource path and links the Embedded Unicode
tables. Release builds remove debug and name sections. There is no
`--export-all` setting.

The output in `Web/dist` includes both `.wasm` artifacts, the ESM package,
TypeScript declarations, and per-artifact size reports for raw, gzip, and Brotli
bytes (Brotli quality 5). Build both variants before packaging this directory. Size reports are
measurements; there is no size regression gate yet.

The command-style core smoke target remains separate:

```sh
scripts/build-wasm.sh full --smoke --release --run
scripts/build-wasm.sh embedded --smoke --release --run
```

`SWIFTTERM_WASM=1` adds only the smoke product to the manifest.
`SWIFTTERM_WEB_WASM=1` adds the browser reactor. The traits select the core source path;
`SWIFTTERM_WEB_FULL` is no longer used. `Wasm` alone selects Full even when
that environment variable is absent. The two variants are separate: do not combine
`Wasm` and `Embedded`. Existing manual `--traits Embedded,Wasm` commands must
change to `--traits Embedded --disable-default-traits`; the build script interface is unchanged.
The default `PortableGraphics` trait supplies PNG and zlib dependencies for native
Linux and Windows. `Wasm` enables it explicitly. `Embedded` builds must omit it;
the script disables default traits for this variant. Consumers of the native package do not acquire these executable
targets or their linker settings.

The library uses source guards because SwiftPM source exclusions cannot depend
on traits. The same library target serves native, Full, and Embedded consumers.

## Use the engine

```ts
import { loadSwiftTerm } from './dist/index.js';

const module = await loadSwiftTerm({ wasmURL: './dist/swiftterm-full.wasm' });
const terminal = module.createTerminal({ cols: 80, rows: 24, scrollback: 10000 });
terminal.write('Hello, terminal!\r\n');
const frame = terminal.snapshot();
// Draw frame.rowData with the host renderer.
terminal.markFrameRendered(frame.generation);
terminal.dispose();
```

`write` passes **process output into the terminal**. It accepts a `Uint8Array`
or a UTF-8 string. Terminal reply bytes flow in the other direction. Send the
result of `readOutput()` to the PTY. Call `consumeOutput(byteCount)` only
after the transport accepts the bytes. Copy and consumption are separate
operations, so a host can retry a failed send.

Use `snapshot()` after input or host state changes. A partial snapshot contains
complete dirty rows. A full snapshot contains the visible grid. A clean
snapshot has no rows. The renderer must draw all included rows. Colors are
already resolved for inverse and global reverse-video modes.

Call `markFrameRendered(generation)` only after the draw succeeds. If input
arrives between the snapshot and this call, the old generation is rejected.
This prevents a delayed draw from clearing new damage. Copied snapshots remain
valid after later terminal operations.

While `snapshot.synchronizedOutput` is true, defer drawing and frame
acknowledgement. Continue requesting snapshots so the engine can apply its
timeout after one second. The Canvas example does this in its animation loop.
Calls for a terminal must be serialized. The wrapper rejects recursive entry. Dispose is idempotent. Other calls after
dispose throw a typed error.

The native `Terminal.makeRenderSnapshot(scope:)` API copies state under one
terminal lock. It preserves graphemes, cell width state, semantic content,
attributes, palette values, row modes, and cursor state. It does not expose
internal cell storage. Scroll-invariant damage uses buffer row coordinates.
Normal damage uses viewport row coordinates.

## Browser example and transport

Serve the repository through a local HTTP server and open `Web/example/`:

```sh
python3 -m http.server 8000
```

The Canvas example uses animation frames and device-pixel scaling. It owns
cursor blink timing. The shared input controller owns focus and visibility. Canvas shaping, font
fallback, ligatures, emoji, and BiDi can differ from native rendering. A host
can replace Canvas with WebGL 2 or WebGPU without changing the engine API.
The worker example keeps parsing in a worker and sends copied frames to its
host.

For a WebSocket PTY transport, set `socket.binaryType = 'arraybuffer'`. Pass
received bytes to `terminal.write(new Uint8Array(event.data))`. After each
write, send generated reply bytes back through the socket. Keyboard and paste
input must go to the PTY transport; do not pass it to `write`. Use `sendKey`
and `sendText` for keys and committed text. Use `sendMouse` and `paste` for
pointer input and paste. Drain their encoded bytes through `readOutput` to the
PTY. `inputState` reports keyboard and paste state plus mouse tracking, encoding,
Shift capture, alternate-scroll mode, and the active buffer. Call `poll` during idle frames to service host callbacks,
synchronized-output timeouts, clipboard timeouts, and image animation.

`drainEvents()` returns host requests such as title changes, bells, clipboard
writes, notifications, and resize requests. It does not execute them. The host
must opt in before it applies a request. The sample offers a visible clipboard
action. It supports standard clipboard text and PNG, atomic writes, and
OSC 52 reads; primary selection is unsupported. Current-directory and
current-document OSC updates require process trust and remain denied.

Full graphics use `graphicsSnapshot` and `markGraphicsRendered`. The copied
snapshot contains RGBA images and source/destination rectangles. Image IDs
and content generations let the renderer reuse pixels. Kitty placements
retain z order; default background cells carry flag32, and Unicode image
placeholder cells carry flag64. Sixel and iTerm PNG slices follow terminal
scrolling. The sample server converts Kitty file transfers from its private
session directory into inline data. The reactor itself cannot open files.

Graphics packets start with a 32-byte STGX/version1 header: generation:u64,
imageCount:u32, placementCount:u32, imageOffset:u32, placementOffset:u32.
Each 32-byte image record contains ID:u64, generation:u64, width:u32,
height:u32, dataOffset:u32, dataLength:u32. Zero data length means reuse the
accepted image generation. Each 64-byte placement contains imageID:u64,
source and destination rectangles (eight float32 values), z:int32, flags:u32,
token:u64, and order:u64. All fields use little-endian encoding. Pixel data
follows the records. Hosts must copy pixels before acknowledging a snapshot.

The Full reactor is larger because it includes Foundation and image codecs.
Use the generated size reports when choosing a build and enable HTTP
compression when serving it outside a local development session.

## Input and selection API

Use `TerminalInputController` from the TypeScript package for DOM input. Its
constructor takes a terminal, a canvas, a textarea, and host callbacks.
`geometry()` supplies logical cell size and grid dimensions. Optional
`rowScale(row)` handles doubled-width rows; optional `cursor` positions the IME
candidate window. `canInput()` gates input under transport pressure. `onInput()`
lets the host drain output, and `onSelection()` updates the selection overlay.
`onPaste()` and `shortcut()` supply host policy. A shortcut callback returns true
to keep the press and its release outside the terminal; call
`defaultKeyboardShortcut()` to keep the defaults when adding a host shortcut.

Call `refresh()` after PTY output, resize, or transport-pressure changes. Dispose
the controller before its terminal. It owns focus, composition, pressed keys,
pointer capture, wheel routing, and local copy. Focus is true only while its
textarea has focus in the active, visible document. The renderer does not infer
terminal focus from document focus. The sample and standalone Canvas example
both use this controller. See [Web/README.md](../Web/README.md) for a full example.

For direct calls, `sendKeyResult()` returns `text`, `sent`, or `ignored`.
Only `text` needs browser text fallback. `sendKey()` returns false for `text`
and true for the other two results. Use the unshifted key identity and keep it
for release. Supply shifted and base-layout scalar values separately.
`sendText()` submits committed text through the core keyboard modes. It does
not use paste framing. `paste()` retains its separate safety and mode rules.

`sendMouse()` accepts press, release, move, and wheel actions. Cell and pixel
coordinates are zero-based and relative to the viewport. Pixels use logical
screen dimensions, without a device-pixel ratio multiplier. Set cell dimensions
with `resize()`. Buttons are left=0, middle=1, right=2, none=3, wheel up=4,
down=5, left=6, and right=7. Use none only for motion. Modifier bits are
Shift=1, Alt=2, Control=4, and Super=8; Super is ignored. X10 sends presses
only. SGR release packets retain the released button. The return value is false
when the current tracking mode filters the event.

Selection pointer coordinates identify visible cells. `selectionBegin()`
accepts character, word, row, and Shift-extension modes. Character selection
includes both endpoint cells and complete wide characters. `selectionExtend()`
changes the target. `selectionClear()` clears the range, and `selectionAll()`
includes history. `selectionText()` uses core text extraction, including soft
wraps and selected rows outside the viewport.

`selectionState()` supplies owned visible spans with an exclusive `endCol` and
a separate generation. Render selection changes even when the cell frame is
clean. `viewportState()` supplies the current `topRow`, `maximumTopRow`, and
alternate-screen flag. `scrollViewport()` uses signed line movement; positive
values scroll down. `scrollViewportTo()` uses a buffer row. Both clamp to the
history bounds and update the state that keeps the viewport fixed during output.

Each WASM terminal owns one `SelectionService`. Calls hold the terminal lock.
Feed-owner checks compare selected content once per feed batch. They add no
selection work to the per-byte parser. Selection follows valid content during
scrolling. History eviction or changed selected content can clear it. Resize,
reset, and a buffer switch clear it. Rectangular selection, exact reflow
preservation, and words across wrapped rows remain deferred.

### Additive ABI version 1 exports

Existing version 1 record layouts remain unchanged. The loader checks the new
exports. Full and Embedded supply these capability bits:

| Bit value | Capability |
| --- | --- |
| 64 | Mouse input and pointer-mode state |
| 16384 | Committed text input |
| 32768 | Selection and viewport operations |

All arguments below are `u32`, except the scroll value, which is `i32`.
All results are `i32`. Negative results use the existing ABI error codes.

| Export | Arguments after the terminal handle | Success result |
| --- | --- | --- |
| `swiftterm_terminal_text` | UTF-8 pointer, byte length | 1 sent, 0 empty |
| `swiftterm_terminal_pointer_modes` | None | Packed mode bits |
| `swiftterm_terminal_mouse` | action, button, modifiers, col, row, pixelX, pixelY | 1 sent, 0 filtered |
| `swiftterm_terminal_scroll` | value, absolute flag | 0 |
| `swiftterm_terminal_selection` | action, col, row, mode | 0 |
| `swiftterm_terminal_selection_state_size` | None | Snapshot byte count |
| `swiftterm_terminal_selection_state_copy` | destination, capacity | Copied byte count |
| `swiftterm_terminal_selection_text_size` | None | UTF-8 byte count |
| `swiftterm_terminal_selection_text_copy` | destination, capacity | Copied byte count |

Mouse actions are press=0, release=1, move=2, and wheel=3. Selection actions
are begin=0, extend=1, clear=2, and all=3. Begin modes are character=0, word=1,
row=2, and Shift extension=3. The absolute scroll flag is 0 for relative lines
and 1 for an absolute top row. The existing `swiftterm_terminal_key` result is
0 for text fallback, 1 for sent, and 2 for ignored.

Pointer-mode bits 0–2 encode off=0, X10=1, VT200=2, button tracking=3, and
any motion=4. Bits 3–5 encode legacy=0, UTF-8=1, SGR=2, URXVT=3, and pixel
SGR=4. Bit 6 is Shift capture, bit 7 is alternate scroll, and bit 8 is the
alternate-screen flag.

The selection state has a 32-byte little-endian header:

| Byte offset | `u32` field |
| --- | --- |
| 0 | Version, always 1 |
| 4, 8 | Selection revision, low and high words |
| 12 | Viewport top row |
| 16 | Maximum viewport top row |
| 20 | Flags: active=1, alternate screen=2 |
| 24 | Visible span count |
| 28 | Reserved, zero |

Each 12-byte span contains `row`, `startCol`, and `endColExclusive`, as three
little-endian `u32` values. Rows are viewport-relative. A size call refreshes
its terminal-owned buffer. Copy reads that buffer without a refresh, even if
an intervening operation changes selection. Text size/copy calls use a separate
owned UTF-8 buffer. Both copies use the existing host-allocation checks and the
256 MiB snapshot limit. Committed text is limited to 64 KiB per call.

## Limits and memory

The ABI uses 32-bit handles and memory offsets, little-endian records, and a
64-bit state revision. A destroyed handle cannot become valid when its slot is
reused. Only the host allocator can free its buffers. Duplicate and interior
frees are errors. The facade restricts ABI reads and writes to tracked host
allocations. It also checks linear-memory bounds. The wrapper obtains a fresh
memory view after each WASM call and copies results before it frees memory.

Hard limits are 1024 columns, 1024 visible rows, 100000 scrollback lines,
16 MiB per write, 8 MiB per output queue, 8 MiB per event queue, 1 MiB per OSC
payload, and 256 MiB per snapshot. The default scrollback is 10000 lines.
Full reserves up to 64 MiB per screen for decoded Kitty images and a separate
64 MiB pool for inline image pixels. The snapshot encoder accepts up to 1 MiB
of UTF-8 text per cell.
Queue pressure returns an error and keeps already queued data. Input from a
failed write can have been applied. Do not retry that write. Drain the queues
and reset the terminal before further input. A failed queue append does not
allocate beyond the queue limit.

Sixel limits apply to native builds and Full WASM. Each sequence can contain
up to 64 MiB of input and produce up to 64 MiB of RGBA pixels. The decoder
checks dimensions and pixel work before it allocates the bitmap. The work
limit is 67,108,864 pixel writes, including repeated writes to the same pixel.
Transparent padding uses no pixel writes and is skipped without expansion.
Each colour or raster parameter list can contain up to 32 values. A sequence
that exceeds a limit is discarded; the next sequence can still be decoded.

## Tests

```sh
swift test --filter PortableRenderSnapshotTests
swift test --filter PortableSelectionTests
SWIFTTERM_EMBEDDED_CHECK=1 SWIFTTERM_WEB_WASM_TESTS=1 \
  swift test --filter SwiftTermWebWasmTests
npm test --prefix Web
node --test Tests/WebWasmTests/interaction.test.mjs
npm run test:browser --prefix Web
npm run benchmark --prefix Web
```

Install the browser engines with `cd Web && npx playwright install` before
browser tests. CI runs Chromium, Firefox, and WebKit, both runtime variants,
ABI validation, snapshot comparisons, invalid-input checks, and benchmarks.
The raw export and import lists are in `scripts/wasm/`. Change them only after
reviewing the compiler output and the browser WASI shim together.

The input implementation passed native input and selection tests, native facade
tests, and all 20 interaction tests against Full and Embedded artifacts. These
checks include exact encoded bytes, selection text and spans, scrollback,
invalid arguments, and stable size/copy buffers. Browser, live-shell, and latency
results are in [web-input-plan.md](web-input-plan.md). Manual checks with a native
IME remain necessary.

### WASI timer scheduling

Full reactors poll per-terminal host queues. Bounded callback storage is separate
from two replaceable timer slots: synchronized output and Kitty animation.
A full callback queue cannot discard either timer. A new animation deadline
replaces its previous slot; reset and disposal cancel both slots. Native timers
continue to use Dispatch without these browser queue limits.
