# Semantic prompt (OSC 133) design specification

## Scope and status

This document is the normative design for SwiftTerm's OSC 133 semantic-prompt
support: prompt marking, input classification, and click-to-cursor routing.
It replaces the incremental design that six review rounds could not stabilize.

The specification describes the data model, the ownership rules, the state
machine, and the acceptance criteria. Implementation names are suggestions;
the rules are not.

## Design history: why the previous model did not converge

Six audit rounds found bugs that cluster into five structural classes. Each
rule in this document exists to make one of these classes unrepresentable.

| # | Failure class | Examples found in audits |
| --- | --- | --- |
| 1 | Derived data is stored, so every row-moving path must maintain it | scroll double-stamped continuation anchors; the recycle branch stamped none; reflow replanted anchors mid-line, then stamped them onto output rows |
| 2 | Lifecycle policy distributed across cell mutators | EL fixed while DCH still deleted anchors; after the EL fix, nothing pruned and repaints stacked 30 anchors on one row |
| 3 | Cached origin maintained by per-call-site adjust calls | margin, splice, and recycle scroll branches each missed the adjust call in different rounds |
| 4 | Input lifetime guessed by heuristics with an unsafe failure direction | clicks injected arrow keys into running programs (too lax); bracketed paste and alternate-screen visits killed routing (too eager) |
| 5 | Verifier checks what is convenient, not what regressed | `semanticPromptInvariantsHold()` could not detect duplicate anchors; two tests pinned defective behavior |

## Vocabulary

| Term | Meaning |
| --- | --- |
| mark | A zero-width, shell-authored prompt marker: the position and `k=` kind of an OSC 133 `A` or `P` action. Stored. |
| prompt group | One prompt-and-input unit: the rows from an initial mark up to the end of its input region. |
| origin | The line that carries the group's initial (or preserved-primary) mark. |
| row kind | The derived classification of a row: `initial`, `continuation`, or none. Never stored. |
| input region | The cells classified `.input` between `B`/`I` and the end of input. |
| logical offset | A character index into the group's input text, after joining soft-wrapped rows and counting hard continuations as one newline. |

## Core principle

**Store only what the shell said. Derive everything else.**

The shell is the sole author of stored state. Terminal-side events (wrap,
scroll, reflow, erase) never author prompt metadata; they at most move it or
destroy it together with the line that carries it.

## R1 — Stored marks

- A `BufferLine` stores only shell-authored marks: `(kind, column)` pairs from
  OSC 133 `A` and `P`.
- There are no synthetic marks. Remove `SemanticPromptLineAnchor.isSynthetic`
  and every code path that creates or rebuilds synthetic continuation anchors
  (`prepareSemanticContinuation`, `addSemanticContinuationAnchor`,
  `restoreSemanticPromptAnchorsAfterReflow`,
  `takeSemanticPromptAnchorsForReflow`).
- One line-level epoch, `semanticHardContinuationGroup: UInt64?`, records
  that the line was created by a hard line feed inside a specific prompt
  group: it is assigned the **active prompt-group ID** at stamp time.
  Exactly one function sets it: `finishSemanticLineAdvance`, on the line
  object the cursor landed on, after `scroll()` has resolved which object
  that is. Scroll branches themselves set nothing; the epoch travels with
  the line object, so push, splice, and recycle branches cannot disagree.
- Stamping is gated on the interaction state: `finishSemanticLineAdvance`
  stamps while the buffer is in the `prompt` or `armed` state, and never
  while `submitted` or `idle`. Prompt-state rows are pre-`B` by definition
  (a multi-line prompt's own continuation rows) and must stamp; the rows
  the gate exists to exclude are post-submission. The user's submission
  (R4) normally precedes the pty's echoed CRLF, so echoed-Enter rows and
  pre-`C` output rows (PS0, DEBUG traps) are never stamped in the common
  case. A missed submission heuristic leaves stamped rows behind,
  but the group epoch bounds the damage to the already-dead group.
- The epoch is **structural, not content**: it describes the relationship
  between line objects, never their current cells. Cell erasure — including
  whole-row EL and ED — does not clear it. Do not add conditional
  carve-outs such as "preserve only while armed": erase behavior must not
  depend on transient protocol state.
- The epoch is cleared or replaced only by:
  - `C`/`D` removing the echoed-Enter continuation from the cursor row (a
    narrow backstop; with armed-gated stamping it is usually a no-op).
  - A full-width line copy replacing it with the source line's value.
  - Line recycle or destruction.
  - A full reset destroying the semantic state.
- A narrow-margin copy leaves the epoch — the conservative choice under
  R4's asymmetry (a stale group yields dead clicks, never injection).

## R2 — Mark lifecycle

Creation:

- Only the OSC 133 handler creates marks, through a single entry point,
  `Buffer.setSemanticMark(kind:row:column:)`.
- Setting a mark on a row that already has a mark of the same kind **replaces**
  that mark. It does not append. Readline redisplay re-emits `A` on the same
  row on every repaint; replace-on-re-mark is the semantics that pattern
  requires, and it bounds the per-line mark count by the number of kinds.

Group allocation. Re-emitted `A` is real shell behavior — ghostty's zsh
integration puts `A` inside PS1, so zsh re-emits it on `reset-prompt`,
SIGWINCH, and some SIGCHLD redisplays (its bash integration instead uses
`P` for readline redisplay and reserves `A` for the initial prompt). The
group ID must therefore never depend on the screen row alone; it derives
from the active lifecycle state plus the resolved origin **identity**:

- `N` always allocates a new group.
- `A` or `P;k=i` **reuses** the active group only when all three hold:
  the interaction state is `prompt` or `armed`; the target line is the
  resolved current origin **line object** (identity comparison, never the
  numeric row); and that line already carries a group-opening mark for the
  active group. Otherwise `A`/`P;k=i` allocates a new group.
- `P;k=s`, `P;k=c`, and `P;k=r` join the current group. They never
  allocate.
- `B` and `I` never allocate groups.
- Never use `aid` as the group ID: ghostty's bash integration passes the
  constant shell PID as `aid`, so it is not a command-instance identifier.

Required outcomes: `CR EL A … B` while armed reuses the group (repaint);
Ctrl-R, completion, and SIGWINCH repaints reuse; `D A … B` on the same
line object allocates new; `N … B` while a group is open allocates new;
the same numeric row after line recycling allocates new (identity
changed); `P;k=s … B` after a locally submitted Return rejoins the
existing group.

A genuinely new primary prompt emitted as `A`/`B` on the same line while
the previous group is still armed, with no other boundary, is
byte-indistinguishable from a repaint. No terminal can discriminate it;
this specification defines that integration behavior as ambiguous, and the
repaint interpretation (reuse) wins.

Destruction. A mark is removed only by:

1. Replacement by a new mark of the same kind on the same row (above).
2. Destruction of the line itself: scrollback trim, line recycle.
3. A full reset: RIS, DECSTR, `ED 3` (scrollback erase clears marks on the
   erased lines).

**Cell-content mutations never touch marks.** EL, ECH, ED 0/1/2, DCH, ICH,
`fill`, `replaceCells`, `deleteCells`, `insertCells`, and `clear(with:)`
must not add or remove a mark. A mark is line-level metadata like
`isWrapped` and `bidiState`; erasing the cells under it does not erase it.
This deletes every per-mutator anchor policy and ends failure class 2.

Column maintenance is the only mark work mutators do, through exactly two
shared helpers:

- `marksShift(from:by:)` — ICH/DCH shift mark columns with the cells.
- `marksClampTo(width:)` — shrink resize clamps columns into the new width.

Movement between lines is centralized in one place: `copyFrom(range)` moves
the marks whose columns fall **inside the copied column range** together with
the cells, and leaves marks outside the range on the source line. This is the
single mark-movement policy for every margin-restricted scroll branch. A mark
outside the scrolled margin columns must not move (moving it was a past
defect).

## R3 — Origin tracking

- The origin is `semanticPromptStartLine`, a reference to the `BufferLine`
  object, plus a cached row index.
- Read path: if `lines[cachedRow] === startLine`, return `cachedRow` (one
  pointer compare). On mismatch, scan outward from `cachedRow` (scrolls move
  the line by small deltas), with a full scan as fallback; update the cache.
- Re-bind rule: when the identity line no longer carries a group-opening
  mark — its content moved to another line via `copyFrom(range)`, or the
  line was recycled and reused — the getter re-binds to the **most recent**
  group-opening mark at or above the cursor row. If none exists, the origin
  is nil and click routing is ineligible. Re-binding must never attach to an
  earlier prompt group below the most recent one: a stale binding would make
  `click_events` relative reports compute `y` from the wrong origin.
- **No adjust calls anywhere.** Delete `adjustSemanticPromptStartForScroll`,
  `adjustSemanticPromptStartForTrim`, and all their call sites. No scroll,
  splice, margin, trim, or reflow path needs to know the cache exists, so no
  future path can forget it. Failure class 3 becomes unrepresentable, and
  scroll never consults the origin, so the earlier O(scrollback × lines)
  throughput regression cannot return.

## R4 — Input lifetime state machine

States per buffer: `idle`, `prompt`, `armed` (tagging input, clicks
eligible), `submitted` (tagging stopped, clicks ineligible).

Authoritative transitions (from the pty stream):

- `A` / `N` → `prompt`; begins a group unless `k=s` (preserve primary origin)
  or `k=r` (mark only; no fresh-line, no origin change).
- `B` / `I` → `armed`.
- `C` / `D` → `submitted` (then `output` classification for new cells).
- Alternate-screen switch, in either direction, → `submitted` on **both**
  buffers, and stops `.input` tagging on both. Resetting the interaction
  state while leaving `semanticContent == .input` is a defect.
- RIS / DECSTR → `idle`.

Heuristic transitions obey the safety asymmetry: **a wrong suspension costs
one dead click; a wrong arm injects bytes into a child process. Heuristics
may only move toward `submitted`, never toward `armed`.**

- A CR or LF in `Terminal.sendUserInput` **outside** an `ESC[200~` /
  `ESC[201~` bracketed-paste region → `submitted`. Inside the brackets,
  newlines are literal text and cause no transition.
- A kitty-keyboard-protocol Enter (`CSI 13 ... u`, which carries no raw CR
  byte) → `submitted`. Any future submission encoding may be added here;
  suspension-only heuristics are always admissible under the asymmetry rule.
- No output-side heuristic ends the input region. A hard line feed in the
  pty stream while `armed` sets `semanticHardContinuation` on the new line
  and stays `armed` (multi-row editors redraw without re-emitting `B`).

Recovery is authoritative only: the next `B` re-arms. Nothing else does.

The interaction state and the group lifetime are related but not
identical. A local submission heuristic **suspends clicks**; it never
closes the group. Only authoritative `C`, `D`, `N`, a reset, or an
accepted new primary origin (per R2's allocation rules) closes or
replaces the group identity. The active group ID therefore remains
available while clicks are suspended — required for PS2: a local Return
on an incomplete command suspends, the shell answers with `P;k=s`, which
rejoins the existing group, and the following `B` re-arms clicks against
it.

Known accepted cost: zle's quoted newline (Alt-Enter) reaches
`sendUserInput` containing `0x0d` outside a paste region and suspends
routing until the next `B`. This is the safe side of the asymmetry.

Click eligibility is re-derived at click time, never trusted from stored
state alone: the buffer must be `armed`, the clicked row must belong to the
active group per R5's derivation, and the target must resolve onto input
cells.

## R5 — Derived row classification and click translation

Row kind is a query, not data:

- A row is `initial` if its line carries an initial (or preserved-primary)
  mark.
- A row is `continuation` if it is reachable from the origin line through
  the `isWrapped` chain, or through lines whose
  `semanticHardContinuationGroup` **matches the origin mark's group ID**.
  A group-ID mismatch ends the chain: an old continuation can never join a
  new prompt, which is what makes indefinite preservation across
  erase-and-repaint safe.
- Any other row has no kind. An output row can never acquire a prompt kind,
  because it does not satisfy the derivation. Failure class 1 is gone.

Click translation uses one traversal for all strategies:

1. Build the group's logical offset sequence once per click: walk the
   group's rows in order; count each input cell (a wide glyph counts once at
   its lead column; zero-width cells count zero); join soft-wrapped rows with
   nothing; count each hard continuation boundary as one newline (consumed
   by `cl=m`).
2. Compute the cursor's logical offset from `buffer.x` **unclamped**: the
   offset is the number of input cells strictly before the cursor position,
   so a pending wrap (`buffer.x == cols`) naturally contributes the full
   row. Clamping to `cols - 1` is a defect (it drops one movement and makes
   a click on the last cell of a full-width row compare equal to the
   cursor).
3. Compute the click's logical offset the same way, after normalizing a
   click on a wide glyph's trailing cell to its lead column, and clamping a
   click past the end of input to the input's end.
4. Each strategy (`cl=line`, `cl=m`, `cl=v`, `cl=w`, `click_events`) is a
   pure function of `(cursorOffset, clickOffset)` over the same sequence.
   Strategies differ only in how the delta is emitted. `cl=line` rejects a
   click outside the cursor's logical line (not its visual row).
5. Emission is one concatenated write per click
   (`sendRepeatedSemanticSequence`); `special_key=1` selects the CSI-u
   encodings for horizontal and vertical movement alike; `click_events`
   validates that the click resolved inside the group and clamps the
   reported coordinates to the viewport.
6. Under `special_key=1` there are no vertical keys, so a cross-row target
   is reached entirely by horizontal traversal, and the emitted count
   **includes** each embedded hard newline crossed (`backward-char`
   traverses the newline in the shell's edit buffer). For `ab\ncd` with the
   cursor at the end, a click on `a` emits 4 backward movements, not 3.

## R6 — View integration: one arbiter

- The views collect `(hit, modifiers, snapshot)` and delegate the decision
  to one shared core-side arbiter. `snapshot` is captured in
  mouseDown/touch-begin, **before** any handler mutates state:
  `selectionWasActive`, `didDrag`, `clickCount`. Guards that test live view
  state after earlier handlers changed it are a known defect class.
- Precedence, identical on macOS and iOS:
  1. Hyperlink under an unmodified or command click.
  2. Application mouse reporting, only if the child enabled a mouse mode.
  3. Selection gestures: drag, shift-extend, double- and triple-click, and
     the click that dismisses an active selection (per `snapshot`).
  4. iOS near-cursor context menu, with the cursor row computed from
     `yBase`, not `yDisp`.
  5. Semantic prompt click.
- The semantic route is gated by `semanticPromptClickBehavior` only.
  `allowMouseReporting` governs mouse *reports* and must not gate arrow-key
  emission. `.requireModifier(m)` must be satisfiable for every modifier the
  platform can deliver, including shift.
- Under the default `.enabled` policy, a click that carries any modifier the
  view uses for its own gestures (command, control, shift, option) is not a
  semantic prompt click.

## R7 — Invariants and test discipline

`semanticPromptInvariantsHold()` must check, at minimum:

- No two marks of the same kind on one line.
- Every mark column is inside the line's content width.
- The origin reference resolves to a line whose marks include an initial or
  preserved-primary kind.
- No stored mark has a derived-only kind (continuation is derived; a stored
  continuation mark is a bug by definition).
- On a sampled row, the derived row kind is consistent with the cell-level
  `semanticContent` tags.

Test discipline:

- Every behavioral test asserts observable output — bytes sent to the
  delegate — not internal counters.
- Every invariant and every guard gets a neuter-and-confirm check: disable
  the guard, confirm a named test fails.
- A test must never pin a behavior this specification defines as a defect.
  Two current tests do and must be inverted:
  `disabledMouseReportingBlocksSemanticPromptClicks` (contradicts R6) and
  `testOscUserInputPathSuspendsPasteAndKittySubmission` (contradicts R4's
  bracketed-paste rule).

## Protocol conformance notes

- `A` and `N` perform a fresh-line (CR+LF unless already at the left
  margin), per the Per Bothner semantic-prompts specification and ghostty's
  `fresh_line_new_prompt`. `k=r` is exempt: a right prompt is a mark on the
  current row and must not move the cursor or the origin. `k=s` marks a
  secondary prompt row without beginning a new group.
- `C` and `D` are the authoritative end of input. `L` is a fresh-line with
  no classification change.
- Unknown actions, and options with unknown or malformed values, are ignored
  entirely: no cursor movement, no state change.
- Public enums added by this feature follow the project convention: no raw
  types on public enums; expose `description` (and `tagName` where hosts
  need a stable serialization).

## Public API

- `semanticPromptMarks(at:) -> [SemanticPromptAnchor]` — shell-authored
  marks only.
- `semanticRowKind(at:) -> SemanticPromptKind?` — the derived
  classification (R5). Hosts use this for gutter marks and prompt
  navigation.
- `semanticContent(at:) -> SemanticContent` — cell classification,
  unchanged.
- `handleSemanticPromptClick(at:modifiers:)` — unchanged signature; R5/R6
  semantics.
- The previous mixed query `semanticPromptAnchors(at:)` is removed (it
  predates any release; there is no compatibility cost).

## Migration order

Each step is independently testable and leaves the tree green:

1. **R2 + R3** — replace-on-re-mark, mutators stop touching marks, identity
   origin, delete all adjust calls. Mechanical; closes the accumulation,
   DCH, and any remaining origin-drift findings.
2. **R1 + R5 derivation** — delete synthetic anchors, add
   `semanticHardContinuation`, implement `semanticRowKind(at:)`, split the
   public API. Closes the recycle-branch and reflow-over-stamping findings.
3. **R5 traversal** — one offset model for all strategies, unclamped cursor
   offset. Closes the pending-wrap findings.
4. **R4** — the state machine with bracketed-paste awareness and the
   alternate-screen rule. Closes the paste and alt-screen findings.
5. **R6** — the shared arbiter; remove the `allowMouseReporting` gate; fix
   the iOS precedence and `yBase` row. Closes the platform-parity findings.
6. **R7** — grow the invariant checker and invert the two pinning tests
   alongside each step, not at the end.

## Acceptance criteria

The feature is done when all of the following hold against the built
library:

1. 30 repeated `CR EL A "> " B` repaints leave exactly one mark on the row.
2. `DCH` at the prompt column, then a click, still moves the cursor.
3. A scroll through the margin, splice, and recycle branches keeps
   `semanticPromptStartRow` pointing at the visible prompt row, with no
   adjust calls present in the codebase.
4. A wrapped prompt at `scrollback: 0` reports `continuation` for its last
   visual row; a widened output row reports no kind.
5. `cols`-width input with pending wrap: a click on the first cell emits
   `cols` movements; a click on the last cell emits one.
6. A multi-line bracketed paste leaves the buffer `armed`; a bare CR through
   `sendUserInput` leaves it `submitted`; `ESC[?1049h/l` leaves it
   `submitted` with no `.input`-tagged output cells.
7. With `allowMouseReporting = false` and `cl=line`, a click moves the
   cursor on both platforms; with `.requireModifier(.shift)`, a shift-click
   works on both platforms.
8. In-place repaint, for both EL 2 and ED 2: create a multi-row `B` input
   with hard line feeds; move through the existing rows and erase each
   whole row; repaint them without another line feed or `B`; clicks on all
   repainted input rows still work. Then emit `C` or `D` and confirm click
   routing stops.
9. Group allocation and isolation, per R2's rules (a bare `A`/`B` while
   the old group is armed is indistinguishable from a repaint, so each
   case carries a discriminator):
   a. Repeated same-origin `A`/`B` while armed retains one group ID.
   b. `D` then `A`/`B` on the same line object allocates a different
      group ID, and no old continuation row derives into the new group.
   c. `N`/`B` while still armed allocates a different group ID.
   d. A local Return followed by `P;k=s`/`B` retains the old group ID and
      re-arms clicks against it.
   e. A local Return followed by `A;k=i`/`B` allocates a new group ID.
   f. Reuse is refused when the numeric row is unchanged but the
      BufferLine identity changed (recycling).
10. Every acceptance test above fails when its guard is neutered.
