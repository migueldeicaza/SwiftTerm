# Kitty Clipboard Protocol

Serve DEC private mode 5522 paste events and OSC 5522 clipboard requests.

## Overview

SwiftTerm implements two related features:

- **Mode 5522, paste events.** When the mode is set and the host serves the
  complete standard-clipboard extension, a user paste sends the terminal
  application the list of MIME types the clipboard holds instead of text. The
  application then asks for the representations it wants.
- **OSC 5522, the Kitty clipboard protocol.** The terminal application reads
  and writes clipboard representations with explicit permission.

Both features are off until the host opts in. This is deliberate: the
clipboard is the user's data, and OSC 5522 is a channel that an untrusted
program in the terminal drives.

### Behavior change from earlier releases

``TerminalOptions/kittyClipboardPolicy`` now defaults to an empty set. It
previously defaulted to `.all`. A host that relied on the old default must set
the policy and the host capabilities explicitly. Without them, mode 5522
reports as unsupported and every OSC 5522 request answers `ENOSYS`.

These API changes accompany it:

- ``KittyClipboardCapabilities`` gained
  ``KittyClipboardCapabilities/standardRead``,
  ``KittyClipboardCapabilities/standardWrite``,
  ``KittyClipboardCapabilities/primaryRead``, and
  ``KittyClipboardCapabilities/primaryWrite``. The old `read` and `write`
  names are gone; they were location-blind, and a `contains(.read)` check
  wrongly approved a primary-selection read.
- The read delegate now returns a ``KittyClipboardReadResult`` instead of
  `Data?`, so a host can distinguish unavailable, denied, and busy. Empty data
  is a valid representation.
- The write delegate now receives a ``KittyClipboardWriteContent``, which
  carries the alias relations next to the representations. Use
  ``KittyClipboardWriteContent/flattened`` when the platform pasteboard cannot
  express an alias.
- ``TerminalPasteRequest`` lost its `source` parameter and the
  `TerminalPasteSource` type. The snapshot's location now selects the
  clipboard. Build a clipboard paste with `TerminalPasteRequest(snapshot:text:)`
  and text insertion with `TerminalPasteRequest(text:)`; the `mimeTypes:` and
  `readMimeType:` parameters are gone too.
- ``TerminalPasteResult`` has four cases: ``TerminalPasteResult/eventSent``,
  ``TerminalPasteResult/textSent``, ``TerminalPasteResult/rejected``, and
  ``TerminalPasteResult/failed``. The old `kittyEvent(password:)`, `text`,
  `requiresText`, `unsafePayload`, `entropyUnavailable`, and `deliveryFailed`
  cases no longer exist.

> Warning: Both delegate requirements have default implementations. A
> conformance written against the old `kittyClipboardRead` signature, with a
> `(Data?) -> Void` completion, or the old `kittyClipboardWrite(...,
> representations:, ...)` label still compiles as an unrelated method. The
> default witness then runs instead, every OSC 5522 read and write answers
> `ENOSYS`, and the host's clipboard store is never consulted. Check that
> your conformance uses the new signatures.

## Opting In

Two independent gates gate every operation, and both must allow it:

1. **Terminal policy**, ``TerminalOptions/kittyClipboardPolicy``. This is the
   embedder's decision about the terminal session.
2. **Host capability**, the value the delegate returns from
   `kittyClipboardCapabilities(source:)`. This states which services the host
   can actually perform.

```swift
var options = TerminalOptions.default
options.kittyClipboardPolicy = .all
let terminal = Terminal(delegate: myDelegate, options: options)
```

```swift
func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
    // The primary selection is optional; return only what you can serve.
    [.standardRead, .standardWrite]
}
```

Mode 5522 is reported as supported only when the policy holds both directions
and the capability set holds both ``KittyClipboardCapabilities/standardRead``
and ``KittyClipboardCapabilities/standardWrite``. A read-only or write-only
host reports the mode as unrecognized, and a user paste keeps the ordinary
text path, including mode 2004 bracketing.

If the host's services change during a session, call
``Terminal/refreshKittyClipboardCapabilities()``. The Apple views forward
their own `refreshKittyClipboardCapabilities()` to it. Like every `Terminal`
method, the core call runs under the terminal lock that the caller holds.
Losing the complete standard service resets mode 5522, revokes every grant and
paste token, and aborts an active write with `ENOSYS`.

## Paste Events

The Apple views build a clipboard snapshot for you. When your
``TerminalViewDelegate`` answers the MIME-list and read hooks, the snapshot
uses your clipboard as well, so a paste event and a later OSC 5522 read agree.
A portable host builds a snapshot itself and hands it to
``Terminal/paste(_:allowUnsafe:)``:

```swift
let snapshot = TerminalClipboardSnapshot(
    location: .standard,
    mimeTypes: ["text/plain", "text/html"],
    identity: clipboard.changeCount
) { mimeType, completion in
    myQueue.async {
        guard clipboard.changeCount == identity else {
            completion(.unavailable)
            return
        }
        completion(.data(clipboard.data(for: mimeType)))
    }
    return true
}

let result = terminal.paste(TerminalPasteRequest(
    snapshot: snapshot,
    text: clipboard.string))
```

An event is sent only when mode 5522 is set, the mode is supported, and the
host serves reads at the snapshot's location. A primary-selection paste on a
host without ``KittyClipboardCapabilities/primaryRead`` takes the text path.

The adapter enumerates the MIME list once, at the moment of the paste. It reads
a representation only after the application asks for it. The read also needs
the platform change counter to match. A clipboard the user replaced in between
answers `ENOSYS`.

``Terminal/paste(_:allowUnsafe:)`` has one clear outcome:

| Result | Meaning |
| --- | --- |
| ``TerminalPasteResult/eventSent`` | The output sink took the complete event. No text follows. |
| ``TerminalPasteResult/textSent`` | No event was started and the text was sent. |
| ``TerminalPasteResult/rejected`` | The paste safety policy rejected the text. |
| ``TerminalPasteResult/failed`` | Nothing was sent. The host can run its own text path. |

Text from an IME, a key, automation, drag and drop, or the text convenience
initializer is never a paste event. Use `TerminalPasteRequest(text:)` for it.

## Permission

An OSC 5522 content request reaches the host through
`kittyClipboardRequestPermission(source:request:)` unless one of two
authorizations already covers it:

- A **paste token**. The paste event carries a single-use `pw` value bound to
  that session, direction, location, and snapshot. It expires after 30
  seconds. The application spends it with the suggested name `Paste event`.
- A **persistent session grant**. The user can let a password be remembered
  through ``KittyClipboardPermissionResult/allow(rememberPassword:)``. Grants
  are separate per direction and per clipboard location, and RIS clears them.

A request for the MIME list alone, the `.` request, never prompts: it returns
type names, not clipboard content.

No clipboard service or permission callback ever runs while the terminal lock
is held.

## Limits

| Option | Default | Rule |
| --- | --- | --- |
| ``TerminalOptions/kittyClipboardWriteLimitBytes`` | 64 MiB | Reads back as at least 64 MiB, on assignment as well as in the initializer. Base64 expansion does not count, and aliased data counts once. |
| ``TerminalOptions/kittyClipboardMaximumRepresentations`` | 256 | At least 1. Exceeding it answers `EFBIG` and discards the transaction. |
| ``TerminalOptions/kittyClipboardMaximumAliases`` | 256 | At least 0. Exceeding it answers `EFBIG` and discards the transaction. |

``TerminalOptions/maximumOscBytes`` bounds each individual packet, separately
from the decoded transaction limit. Three fixed bounds apply to request
metadata: a sanitized `id` keeps its first 512 bytes, a decoded `mime`,
`name`, or `pw` field holds at most 4096 bytes, and a decoded request or alias
list holds at most 64 KiB.

## Topics

### Policy and Capability

- ``KittyClipboardPolicy``
- ``KittyClipboardCapabilities``
- ``KittyClipboardLocation``
- ``Terminal/refreshKittyClipboardCapabilities()``

### Pasting

- ``TerminalPasteRequest``
- ``TerminalPasteResult``
- ``TerminalClipboardSnapshot``
- ``Terminal/paste(_:allowUnsafe:)``

### Clipboard Data

- ``KittyClipboardRepresentation``
- ``KittyClipboardAlias``
- ``KittyClipboardWriteContent``
- ``KittyClipboardReadResult``
- ``KittyClipboardWriteResult``

### Permission

- ``KittyClipboardPermissionRequest``
- ``KittyClipboardPermissionDirection``
- ``KittyClipboardPermissionResult``
