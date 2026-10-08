# OSC 7501: spec ambiguities and SwiftTerm decisions

Date: 2026-10-07.

SwiftTerm validates a report before it changes stored records. It gives invalid record addresses and report limits priority over recovery of individual pairs. Ghostty uses a shared metadata iterator and passes valid reports to a host. These choices explain most of the differences in [spec-diffs.md](spec-diffs.md).

This document compares the current SwiftTerm working tree, based on `15fed4fd`, with Ghostty commit [`a4aacd918ba9e79929ff608034c60a4341773ef0`](https://github.com/ghostty-org/ghostty/commit/a4aacd918ba9e79929ff608034c60a4341773ef0). The spec is [Program Status Protocol, revision 0.2][spec], dated 2026-10-06.

The code, comments, and tests establish the behavior. The rationale below is an interpretation of that evidence. It is not a record of an author's private intent. In particular, a Ghostty behavior caused by validation order need not be an intended protocol policy.

**Spec rules used in this analysis**

These short labels identify the relevant clauses. They do not replace the full spec.

| Rule | Spec section | Basis |
| --- | --- | --- |
| R1 | Syntax | Skip malformed pairs and unknown keys; the last repeated value wins. |
| R2 | Records and ids | Reject an invalid id; an absent id selects the root. |
| R3 | Syntax; Limits | Invalid text or a limit breach rejects the report. Check pairs before mutation. |
| R4 | Conventions | OSC uses `ESC ]`; ST uses `ESC \` or BEL. |
| R5 | Limits | Byte caps bound storage and work. Lower caps are permitted. |
| R6 | States | New prompt (`OSC 133 A`) or attached-process exit removes working/blocked. Idle removal is optional; done/error survive. |
| R7 | Records and ids; Keys | Complete replacement, descendant clearing, app inheritance, and terminal ownership. |
| R8 | Feature detection; Terminfo | Fixed `?` reply; `Pst` is recommended. |
| R9 | Security | Plain text; display sanitization and external event rate limits. |
| R10 | Relationship to other sequences | Mapping OSC 9;4 into status records is optional. |

Source for these rules: [the spec][spec].

**1. An invalid id must not become an absent id**

R1 and R2 overlap when an `id` contains a byte outside the general value alphabet.

For the body `state=clear:id=bad!`, SwiftTerm rejects the report. It calls `validId` before the general value filter. Existing records remain. The comment at that check states its purpose: prevent a malformed id from selecting the root.

Ghostty's metadata iterator skips `id=bad!` before `validateId` can see it. Its report then has no id. A host that follows Ghostty's clear contract clears all records. For `id=bad!:id=build`, Ghostty instead selects `build`; SwiftTerm still rejects the report.

SwiftTerm's interpretation gives the address rule R2 priority over pair recovery R1. This keeps the address of an operation stable: an invalid supplied address cannot turn a local operation into a root operation.

Ghostty's own parser comments also describe rejection of invalid ids to prevent root fallback. The observed difference is therefore a conflict between the iterator and that stated goal. It should not be described as Ghostty deliberately choosing root fallback.

Disposition: keep SwiftTerm's validation order. A useful spec clarification would state whether address validation precedes the general malformed-pair filter.

Sources: [SwiftTerm parser][swift-status], [invalid-id tests][swift-tests], [Ghostty parser][ghostty-status], and [Ghostty iterator][ghostty-metadata].

**2. A malformed pair can still exceed a field limit**

SwiftTerm checks the length of a known field before it checks the value alphabet. For example, `state=done:app=` followed by 33 `!` bytes rejects the report. Ghostty skips that app pair and emits done without an app.

The two validation orders give R1 and R3 different priority. SwiftTerm treats a supplied, oversized known field as a report failure, even if the field would later be skipped. This also prevents a later duplicate from hiding the size violation.

The rule is narrower than rejecting every malformed pair. SwiftTerm skips `msg=bad!` when it is within the message limit. It also ignores unknown values, subject to the sequence cap. Both parsers check excessive key length, including unknown keys that have `=`.

Disposition: keep the early length checks. Ask for a clear order between pair filtering and field limits if exact interoperability on malformed input is required.

Sources: [SwiftTerm parser][swift-status], [field-limit tests][swift-tests], and [Ghostty validation][ghostty-status].

**3. Does a later text value repair an earlier invalid value?**

For `state=done:msg=a:msg=SGk=`, Ghostty emits done with the message `Hi`. SwiftTerm rejects the report because `a` cannot decode as base64.

SwiftTerm validates and decodes each accepted text occurrence before replacing the candidate field. Ghostty checks encoded lengths for all values that pass its alphabet filter, but decodes only the final selected title and message.

SwiftTerm interprets R3 as applying to every text occurrence that reaches decoding. R1 selects the final value only after those checks pass. Ghostty applies text decoding to the selected value. Thus, it can accept a report with an invalid earlier value that never reaches the host.

Both interpretations preserve complete replacement for valid input. The difference concerns validation scope. SwiftTerm's tests deliberately place invalid text before a valid duplicate in clear reports. An earlier decoding failure prevents every record change.

Disposition: retain this explicit compatibility choice. A clarification should say whether decoding, UTF-8 checks, control checks, and decoded limits apply to every accepted occurrence or only the final value. This difference is separate from base64 pad-bit validation; both implementations reject nonzero pad bits.

Sources: [SwiftTerm parser][swift-status], [invalid-text tests][swift-tests], and [Ghostty validation][ghostty-status].

**4. Validate the received payload or the normalized OSC payload?**

Ghostty's terminal parser removes ignored C0 bytes inside OSC before the status parser sees them. SwiftTerm retains those bytes after the exact `7501;` prefix. It also rejects a status prefix if ignored control bytes preceded its completion.

This can change valid-looking field content. With a raw TAB inside `state=work<TAB>ing`, Ghostty reads working. SwiftTerm skips the malformed state pair and rejects the report for missing state. With `msg=SG<TAB>k=`, Ghostty decodes `Hi`; SwiftTerm skips the message pair. Trimming at field edges still works in SwiftTerm.

The current regression tests cover retained bytes in the capture cap, control bytes before the complete prefix, and trimming at field edges. No regression test covers a control byte inside a field. Temporary probes confirmed the two examples above in both implementations.

The inferred SwiftTerm rationale is to avoid repairing a field by removing an internal byte. Retained bytes also count toward the capture cap. Ghostty applies the existing terminal-wide OSC rules before protocol validation. This difference belongs to stream processing as well as report parsing.

Disposition: retain the current status-specific handling. A clarification should define which input bytes reach the protocol parser and which bytes count toward R5. Senders should use clean ASCII fields and base64 text for interoperability.

Sources: [SwiftTerm stream parser][swift-stream], [Ghostty OSC table][ghostty-table], and [framing tests][swift-tests].

**5. Complete ST, raw C1 ST, and recovery after overflow**

SwiftTerm waits for the backslash after ESC before it applies an OSC 7501 report. Ghostty dispatches OSC when ESC leaves the string state. The following backslash is a separate escape action. As a result, Ghostty can apply a status before the terminator is complete.

SwiftTerm follows the complete framing in R4. Its separate pending-ST state prevents a split input chunk from causing an early record change. If the next byte is not a backslash, the pending report is discarded and escape parsing continues. This is a framing choice, rather than a different interpretation of a valid report body.

Raw C1 ST (`0x9c`) is outside the spec's listed forms. SwiftTerm accepts it as an extension unless it is a UTF-8 continuation byte. A C1 query receives a two-byte ST reply. Ghostty's OSC stream treats raw `0x9c` as payload at the pinned commit.

For OSC 7501, SwiftTerm keeps C1 detection active after overflow. It discards the oversized report but retains a small tail to distinguish a continuation byte from a terminator. Following screen output can then resume. Losing terminator detection after overflow was a recovery error, not a useful spec interpretation. Other OSC commands still treat raw `0x9c` as payload after overflow.

Disposition: keep complete-ST validation and overflow recovery. Document raw C1 support as an extension, not a requirement imposed on Ghostty.

Sources: [SwiftTerm stream parser][swift-stream], [split and overflow tests][swift-tests], [Ghostty parser][ghostty-parser], and [Ghostty OSC table][ghostty-table].

**6. Enforce a report cap during capture**

SwiftTerm limits accumulated OSC 7501 data to 4092 bytes, including `7501;`. The body cap is 4087 bytes. It reserves the longer framing, so BEL reports have a slightly lower physical limit. Ghostty uses the same body cap at report dispatch.

The difference is when capture stops. Ghostty's allocating OSC buffer has a general default cap of 8 MiB. It can capture far more than a valid status report before the status parser rejects it. Without an allocator, its fixed 2048-byte buffer can instead reject otherwise acceptable reports.

SwiftTerm reads R5 as a reason to bound status capture early. It keeps only the prefix and recovery tail after overflow. This bounds retained input; it does not assert that Swift Array capacity equals the byte-count cap.

Disposition: keep early capture limits. Ghostty's general allocation mode is an implementation constraint to compare, not a limit SwiftTerm should copy.

Sources: [SwiftTerm capture][swift-stream] and [Ghostty OSC capture][ghostty-osc].

**7. A new prompt is an event, not every prompt mark**

The spec names `A`; its broader phrase about a new shell prompt leaves coverage of `N` and `P` open. It does not define repaint or alternate-screen prompt handling. See [States][spec-states].

SwiftTerm uses its existing semantic prompt groups to identify the event. It validates options first and clears active status only when a valid `A` allocates a new group. Right prompts, continuation prompts, repaint of the current group, and invalid options preserve records. The existing prompt handler ignores marks on the alternate screen.

The inferred reason is that a right-prompt update or repaint does not establish that the previous work has ended. Clearing at the start of the handler would destroy live child status before that distinction was made.

Ghostty sends a prompt-start event for `A`, `N`, and `P`, with the prompt kind. This includes right, continuation, and secondary prompts. An unknown `k` value is reported as a primary prompt. Ghostty stores no status records, but its C host contract states the cleanup rule: the host removes working and blocked records on each `GHOSTTY_SEMANTIC_PROMPT_PROMPT_START` event. The rule has no prompt-kind condition. The header also states that no flag identifies a redrawn prompt yet. Thus, a host that follows this contract clears active status on every prompt-start mark, including a repaint.

SwiftTerm can allocate a group for `N` or an initial `P` without clearing active status. Its tests explicitly preserve records on `N`. The spec's named `A` path supports the current scope; treating all equivalent new-prompt events alike would support broader cleanup. SwiftTerm's scope is narrower than Ghostty's documented host rule. This is a deliberate difference, not agreement with an open Ghostty policy. This refines the open policy point in [spec-diffs.md](spec-diffs.md).

Disposition: keep validation and new-group checks. Decide separately whether a newly allocated primary prompt from `N` or `P` should clear active status. Add tests if that policy changes. Do not copy Ghostty's rule directly. Without a repaint flag, that rule also clears status on right prompts, continuation prompts, and repaints.

Sources: [SwiftTerm prompt handler][swift-terminal], [prompt lifetime tests][swift-tests], [Ghostty prompt effects][ghostty-handler], and [Ghostty host contract][ghostty-header].

**8. Storage, support detection, and host policy**

SwiftTerm implements R7 inside `Terminal`: it stores records, resolves `effectiveApp`, clears descendants, and evicts by the oldest update. Ghostty delivers reports to its host. Its header documents complete replacement, descendant clearing, lifetime cleanup, and the record limit as host duties. It does not mention app inheritance, so a Ghostty host must take that rule from the spec. This is an API boundary choice. There is no different wire meaning for valid records.

That boundary explains support detection. SwiftTerm stores useful records even without a status callback, so it attempts the fixed reply through its send delegate. Ghostty replies only if a program-status effect is installed. Its code explicitly ties the support claim to having a report handler. SwiftTerm also adds `Pst`; its absence from pinned Ghostty terminfo is not a spec ambiguity.

SwiftTerm now preserves BEL or two-byte ST in replies. R8 requires the reply body, but does not explicitly require terminator echo. Matching the query follows Ghostty's behavior and avoids an unnecessary compatibility difference.

Other decisions follow SwiftTerm's host API. Direct callbacks deliver value snapshots. Apple views can combine pending updates. An explicit empty title or message remains `""`, while an omitted field is `nil`; Ghostty's Zig API treats empty text as absent. A clear that changes no stored record sends no SwiftTerm status callback. Ghostty still delivers the clear report to an installed effect.

SwiftTerm preserves idle, done, and error on prompt cleanup and process exit. Hosts explicitly dismiss results. Local process hosts apply exit cleanup after output parsing; remote hosts must call `programStatusProcessExited()`. This order lets final reports replace active records before cleanup. It also prevents buffered output from restoring stale working or blocked status after exit, when the output drain completes. `LocalProcess.drainTimeout` limits that drain to 0.5 seconds by default. With direct delivery, which `LocalProcessTerminalView` uses, a timed-out drain can leave one output batch in flight. That batch can restore an active record after cleanup.

SwiftTerm leaves display sanitization and external notification policy to the host. It keeps OSC 9;4 progress separate. These are host responsibilities and an optional mapping choice under R9 and R10, respectively.

Disposition: keep the current division of duties. Hosts that need every intermediate event must account for combined Apple view updates. Protocol conformance requires the full terminal-and-host behavior to be considered, especially for Ghostty.

Sources: [SwiftTerm store][swift-status], [host documentation][swift-doc], [host tests][swift-host-tests], [Ghostty status effects][ghostty-handler], [Ghostty host contract][ghostty-header], and [Ghostty terminfo][ghostty-terminfo].

**Evidence and limits**

This document adds no code changes. It uses the source comparison and the existing regression tests described in [spec-diffs.md](spec-diffs.md). Ghostty outcomes were first derived from the pinned source. On 2026-10-07, temporary probes at the pinned commit confirmed the Ghostty examples in sections 1 to 6 and 8 with `zig build test-lib-vt`. Ghostty's own semantic prompt test, run at the same commit, confirms the section 7 events. Matching SwiftTerm probes also passed. The probes are not part of either repository.

The points that need spec clarification are validation precedence, duplicate text validation, control-byte normalization, and the scope of new-prompt events. Complete ST, early capture limits, and snapshot delivery each have a concrete implementation rationale. Raw C1 support is an extension. None of these differences alone justifies copying Ghostty's behavior without checking the complete host contract.

[spec]: https://www.superlogical.com/rex/docs/build/program-status
[spec-states]: https://www.superlogical.com/rex/docs/build/program-status#states
[swift-status]: Sources/SwiftTerm/ProgramStatus.swift
[swift-stream]: Sources/SwiftTerm/EscapeSequenceParser.swift
[swift-terminal]: Sources/SwiftTerm/Terminal.swift
[swift-tests]: Tests/SwiftTermTests/ProgramStatusTests.swift
[swift-host-tests]: Tests/SwiftTermTests/ProgramStatusHostTests.swift
[swift-doc]: Sources/SwiftTerm/Documentation.docc/ProgramStatus.md
[ghostty-status]: https://github.com/ghostty-org/ghostty/blob/a4aacd918ba9e79929ff608034c60a4341773ef0/src/terminal/osc/parsers/program_status.zig
[ghostty-metadata]: https://github.com/ghostty-org/ghostty/blob/a4aacd918ba9e79929ff608034c60a4341773ef0/src/terminal/osc/kitty_metadata.zig
[ghostty-parser]: https://github.com/ghostty-org/ghostty/blob/a4aacd918ba9e79929ff608034c60a4341773ef0/src/terminal/Parser.zig
[ghostty-table]: https://github.com/ghostty-org/ghostty/blob/a4aacd918ba9e79929ff608034c60a4341773ef0/src/terminal/parse_table.zig
[ghostty-osc]: https://github.com/ghostty-org/ghostty/blob/a4aacd918ba9e79929ff608034c60a4341773ef0/src/terminal/osc.zig
[ghostty-handler]: https://github.com/ghostty-org/ghostty/blob/a4aacd918ba9e79929ff608034c60a4341773ef0/src/terminal/stream_terminal.zig
[ghostty-header]: https://github.com/ghostty-org/ghostty/blob/a4aacd918ba9e79929ff608034c60a4341773ef0/include/ghostty/vt/terminal.h
[ghostty-terminfo]: https://github.com/ghostty-org/ghostty/blob/a4aacd918ba9e79929ff608034c60a4341773ef0/src/terminfo/ghostty.zig
