# Web terminal sample

This SwiftPM package starts a Hummingbird HTTP server at `127.0.0.1:8080`.
Open its page to start an interactive local shell in a backend PTY. The page
uses the SwiftTerm WASM engine and the Canvas renderer from `Web/`.
Each browser connection starts a separate shell. Reconnect starts a new shell.

## Run

Use Swift 6.2 or later, Node.js 22 or later, and macOS 14 or later or Linux.
Install the pinned Swift WASM compiler and SDK described in
[Docs/wasm.md](../../Docs/wasm.md) before the first asset build.

From the repository root:

```sh
TerminalApps/WebTerminal/run.sh
```

The script installs the web build dependencies if needed, builds missing
Full WASM assets, and runs the Swift package. Open
<http://127.0.0.1:8080>. Press Control-C in the server terminal to stop it.
The shell has the same user access as the server process.

After the web assets exist, the package can run directly:

```sh
swift run --package-path TerminalApps/WebTerminal web-terminal
```

To select a shell, working directory, or port:

```sh
TerminalApps/WebTerminal/run.sh --port 9090 --shell /bin/sh --directory /tmp
```

The default shell is `$SHELL`, with `/bin/sh` as the fallback. The server starts
it with `-i`. Its default working directory is the server's working directory.
`--web-assets PATH` and `--public-directory PATH` override the source checkout
asset locations. `web-terminal --help` lists the options.

The Full engine is the default. To try the smaller Embedded engine, build it
and open `/?variant=embedded`:

```sh
scripts/build-wasm.sh embedded --browser --release
```

## Data flow

```text
Browser input → WebSocket binary message → LocalProcess → PTY → local shell
Browser canvas ← SwiftTerm WASM ← WebSocket binary message ← PTY output
```

The WebSocket endpoint is `/terminal`. Binary messages in both directions
contain raw terminal bytes. Engine replies, such as cursor position reports,
go back to the PTY through the same input path.

Client text messages set the PTY size:

```json
{"type":"resize","cols":80,"rows":24,"cellWidth":9,"cellHeight":20}
```

The server sends text messages with `type` set to `ready`, `exit`, or `error`.
Exit messages include `code` (an integer, or `null` for a signal). Error messages
include `message`. Output is sent before the exit message. The final output
drain has a 15-second limit; a client that stalls longer can lose the remaining output.

The server binds to IPv4 loopback. A WebSocket upgrade requires a loopback
Host and its matching HTTP Origin. The server allows eight active sessions.
This sample has no authentication for remote access. Keep it on loopback;
do not expose it through a proxy or tunnel.

PTY output uses a bounded 256 KiB queue and awaits each WebSocket write. Input
messages are limited to 64 KiB, and the server awaits each PTY write. A write
that stalls for ten seconds ends the session. This also bounds cleanup time
when a disconnected client has input pending. Closing a session closes the
PTY and terminates and reaps its shell. Processes that deliberately detach
from the shell are outside the sample's process lifecycle.

The PTY child resets inherited signal handlers and its signal mask before it
starts the shell. Thus, the server's signal policy does not disable Control-C
in programs such as `cat`. The server's own signal state does not change.

Each session sets `TMPDIR` to a private directory. Kitty graphics file transfers
(`t=f` and `t=t`) can read regular files in that directory. Temporary transfers
(`t=t`) also require names that start with `tty-graphics-protocol`. The server
checks ownership, rejects links and
path traversal, and limits files to 64 MiB. It converts these files to direct
Kitty chunks with at most 4096 base64 bytes each. The output queue still applies
backpressure. Other local paths stay unsupported. Temporary transfers delete
the file after delivery; session close removes the private directory. The
browser engine can impose a lower total image limit.

## Checks

```sh
swift test --package-path TerminalApps/WebTerminal
node --test TerminalApps/WebTerminal/BrowserTests/*.test.mjs
```

With the server running, check the HTTP routes, WebSocket origin checks,
PTY input, resize, exit, and WASM output parsing:

```sh
node TerminalApps/WebTerminal/BrowserTests/server-smoke.mjs http://127.0.0.1:8080
```

To check five Control-C cycles, exact Kitty file bytes, and `mc` response times
with the local server running (`mc` and `/usr/bin/python3` must be installed):

```sh
node TerminalApps/WebTerminal/BrowserTests/backend-live.mjs http://127.0.0.1:8080
```

To check normal canvas focus, typed Control-C, and the time to paint the
Midnight Commander menu footer, install the Web package's Playwright browser
and run:

```sh
node TerminalApps/WebTerminal/BrowserTests/ui-live.mjs http://127.0.0.1:8080
```

The sample supports text, IME input, core key encoding, application cursor and
keypad modes, bracketed paste, resize, and reconnect. Full builds also render
Kitty graphics, Sixel, and iTerm PNG images. Kitty Clipboard and OSC 52 reads
are reported when browser Clipboard APIs are available. This does not read
clipboard data. Clipboard actions require a visible browser action; supported
formats are text/plain and image/png. Primary selection is
unsupported. Mouse reporting, selection, scrollback navigation, and
screen-reader terminal output are not implemented.
