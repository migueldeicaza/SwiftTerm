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

The input extension supplies `inputModes()`, `sendKey()`, and `paste()`. Key encoding uses the core encoder for application cursor, application keypad, and Kitty keyboard modes. `sendKey()` returns false when the browser must deliver normal text input. Keep IME composition in the browser and send only its committed text to the PTY. `paste()` uses the core safety policy and current paste modes. A rejected multiline paste needs a separate user action before `allowUnsafe: true`; do not set this flag by default. The paste operation queues the complete batch in the reply queue, including bracket markers or Kitty paste-event packets.

Full supports the asynchronous clipboard extension. Call `configureClipboard(3)` only when the host can serve standard clipboard reads and atomic writes. The browser sample advertises this service when its Clipboard APIs are available. This does not access clipboard data. The **Disable clipboard** button revokes the service for the current connection. Event `clipboardRequest` has a request ID and an operation. Supply its result through `completeClipboard()`. Status values are in `ClipboardStatus`. List completions carry a UTF-8 JSON array of MIME names; read completions carry raw representation bytes; permission and write completions carry no data. A request expires after 30 seconds, and reset or disposal cancels it. Call `poll()` at regular intervals to service protocol completions and deadlines even when no PTY output arrives.

The local shell sample supports `text/plain` and `image/png` clipboard items when the browser supports them. It checks every representation before one atomic write. Other formats fail with `ENOSYS`; primary selection is not offered. Actual clipboard reads and writes need a visible action. Browser activation rules can require an extra format-read or write action. The captured clipboard is reused for follow-up reads for at most 30 seconds. OSC 52 writes have a separate copy action. OSC 52 reads preserve the requested selector. Notifications remain requests and are not shown automatically. Embedded supplies key and text-paste encoding but does not implement the Kitty clipboard protocol.

A worker has no Clipboard API. Relay its clipboard request events to the window, complete the browser operation there, and return the result with the worker `completeClipboard` message. The worker also accepts `inputModes`, `key`, `paste`, `poll`, `configureClipboard`, and `resetClipboard` messages.
