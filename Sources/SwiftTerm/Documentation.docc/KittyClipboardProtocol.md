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
the policy and the host capabilities explicitly, or mode 5522 reports as
unsupported and every OSC 5522 request answers `ENOSYS`.

Three other API changes accompany it:

- ``KittyClipboardCapabilities`` gained
  ``KittyClipboardCapabilities/standardRead``,
  ``KittyClipboardCapabilities/standardWrite``,
  ``KittyClipboardCapabilities/primaryRead``, and
  ``KittyClipboardCapabilities/primaryWrite``. The old `read` and `write`
  names remain as aliases for the standard-clipboard services.
- The read delegate now returns a ``KittyClipboardReadResult`` instead of
  `Data?`, so a host can distinguish unavailable, denied, and busy. Empty data
  is a valid representation.
- The write delegate now receives a ``KittyClipboardWriteContent``, which
  carries the alias relations next to the representations. Use
  ``KittyClipboardWriteContent/flattened`` when the platform pasteboard cannot
  express an alias.

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
``Terminal/refreshKittyClipboardCapabilities()`` — the Apple views forward
their own `refreshKittyClipboardCapabilities()` to it. Losing the complete
standard service resets mode 5522, revokes every grant and paste token, and
aborts an active write with `ENOSYS`.

## Paste Events

The Apple views build a clipboard snapshot for you. A portable host builds one
itself and hands it to ``Terminal/paste(_:allowUnsafe:)``:

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
    source: .clipboard(.standard),
    text: clipboard.string,
    snapshot: snapshot))
```

The MIME list is enumerated once, at the moment of the paste. A representation
is read only after the application asks for it, and only while the platform
change counter still matches — a clipboard the user replaced in between
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
| ``TerminalOptions/kittyClipboardWriteLimitBytes`` | 64 MiB | Raised to at least 64 MiB. Base64 expansion does not count, and aliased data counts once. |
| ``TerminalOptions/kittyClipboardMaximumRepresentations`` | 256 | Exceeding it answers `EFBIG` and discards the transaction. |
| ``TerminalOptions/kittyClipboardMaximumAliases`` | 256 | Exceeding it answers `EFBIG` and discards the transaction. |

``TerminalOptions/maximumOscBytes`` bounds each individual packet, separately
from the decoded transaction limit.

## Topics

### Policy and Capability

- ``KittyClipboardPolicy``
- ``KittyClipboardCapabilities``
- ``KittyClipboardLocation``
- ``Terminal/refreshKittyClipboardCapabilities()``

### Pasting

- ``TerminalPasteRequest``
- ``TerminalPasteSource``
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
