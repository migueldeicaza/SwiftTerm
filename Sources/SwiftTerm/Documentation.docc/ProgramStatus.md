# Program Status

Read program state from OSC 7501 reports and receive status updates.

## Overview

SwiftTerm supports revision 0.2 of the
[Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status).
Programs report `idle`, `working`, `done`, `blocked`, or `error`. They can also
report a program name, message, title, progress, and the action required from
the user. The protocol lets the host choose how to show this information.

Each report replaces one record. A report without `id` replaces the root
record. Other ids are paths, such as `build/test`. A child can exist without
its parent. The `app` property contains the name from the last report.
The `effectiveApp` property contains that name or the name from the nearest
ancestor with an `app` value.

Send a report with `state=clear` to remove a record and its descendants.
Without an id, this removes all records. Each terminal stores up to 256
records. When a new record exceeds this limit, SwiftTerm removes the record
with the oldest update. Reading a record does not change its age.

## Host Integration

For a direct ``Terminal`` host, read ``Terminal/programStatusRecords`` or
``Terminal/programStatus(id:)``. Implement
``TerminalDelegate/programStatusChanged(source:records:)`` to receive value
snapshots. Hold ``Terminal/terminalLock`` when you read or change terminal
state. The delegate callback runs on the thread that changes the state.
Do not acquire the same terminal lock from that callback.

For an Apple ``TerminalView``, read ``TerminalView/programStatusRecords``.
Implement ``TerminalViewDelegate/programStatusChanged(source:records:)`` to
receive the current snapshot on the main actor. Pending updates can be
combined into one callback. A ``LocalProcessTerminalView`` forwards this
callback to its ``LocalProcessTerminalViewDelegate``.

Use ``Terminal/clearProgramStatus(id:)`` or
``TerminalView/clearProgramStatus(id:)`` to dismiss a record after the user
has seen its result. An empty id removes all records. SwiftTerm does not
automatically dismiss completed records when the user presses a key.

## Record Lifetime

Records belong to the terminal. A screen change does not affect them.
A full reset (RIS) removes all records. A soft reset (DECSTR) preserves them.
A valid `OSC 133 A` that starts a new shell prompt group removes working
and blocked records. Invalid reports, right and continuation prompt marks,
and repaint of the current prompt preserve records. Prompt marks on the
alternate screen are ignored. Idle, done, and error records remain.

``HeadlessTerminal`` and ``LocalProcessTerminalView`` remove working and
blocked records after process exit and output parsing. A remote or custom
host must call ``Terminal/programStatusProcessExited()`` or
``TerminalView/programStatusProcessExited()`` at that point. Done and error
records remain until they are replaced or cleared.

## Validation and Detection

Messages and titles use standard base64 with optional padding. SwiftTerm
requires valid UTF-8 and rejects control characters. It checks every pair
before it changes a record. Invalid base64 or a field that exceeds a size
limit discards the whole report. Malformed pairs and unknown keys are ignored.

SwiftTerm uses the specification's field limits and a 4096-byte sequence cap.
It reserves four bytes for OSC and ST framing. This gives BEL and C1 sequences
a slightly lower limit. An ESC terminator must have a following backslash
before the report is applied. The OSC code must use the spelling `7501;`.

The query `OSC 7501 ; ? ST` receives a reply with the same `?` body.
The reply preserves BEL or the two-byte ST terminator. A query that uses
C1 ST receives a two-byte ST reply. The reply never includes record data.
SwiftTerm answers queries because the terminal stores records for the host
to read. A status delegate callback is optional. The `Pst` capability in
`swifterm-terminfo` also advertises support. SwiftTerm keeps OSC 9;4 progress
reports separate from OSC 7501 records.

Treat all status text as untrusted plain text. Do not interpret it as markup.
Remove text direction overrides and invisible formatting characters before
you show text outside the terminal grid. Identify the source terminal and
limit the rate of external notifications or sounds.
