# Bidirectional Text (BiDi)

SwiftTerm implements the [terminal-wg BiDi
recommendation](https://terminal-wg.pages.freedesktop.org/bidi/) for
bidirectional text in terminal emulators.

## Overview

SwiftTerm renders right-to-left and mixed-direction text — Arabic, Hebrew, and
other RTL scripts — on macOS, iOS, and visionOS, in both the CoreGraphics and
the Metal renderers. The implementation follows the terminal-wg draft
recommendation, the same model that mlterm uses:

- The terminal buffer always stores characters in **logical order** (the order
  the application sent them). Reordering happens only at render time, so
  applications, `getText`, selection, and search all see the same logical
  content that a BiDi-unaware terminal would.
- In the default **implicit mode**, SwiftTerm reorders each paragraph for
  display with the Unicode Bidirectional Algorithm (UAX #9, delegated to
  CoreText), applies Arabic contextual shaping and lam-alef ligatures, and
  mirrors brackets on RTL runs.
- In **explicit mode**, the application supplies text already in display
  order and SwiftTerm performs no reordering or shaping; with an RTL
  character path, column zero is placed at the right edge of the view.

A *paragraph* is a row together with the soft-wrapped rows that continue it.
Each paragraph stores its own BiDi state (``BidiPresentationState``), so
scrollback keeps the presentation it had when it was produced. Escape
sequences change the current state for new paragraphs. At the first logical
position of a paragraph, a mode change also applies to that paragraph.
A line feed into a different paragraph applies the current state to all its
rows. A line feed within the same paragraph preserves its state. When a soft
wrap joins two paragraphs, all joined rows use the first paragraph's state.

### The six presentation modes

The recommendation defines six effective modes, exposed as
``BidiPresentationMode`` and derived from three independent settings: the
support mode (implicit or explicit), autodetection, and the fallback
direction.

| Mode | Support | Autodetect | Base direction |
|---|---|---|---|
| `implicitLeftToRight` | terminal reorders | off | always LTR |
| `implicitRightToLeft` | terminal reorders | off | always RTL |
| `implicitAutoLeftToRight` | terminal reorders | on | first strong character, LTR fallback |
| `implicitAutoRightToLeft` | terminal reorders | on | first strong character, RTL fallback |
| `explicitLeftToRight` | app supplies display order | — | column 0 at the left |
| `explicitRightToLeft` | app supplies display order | — | column 0 at the right |

SwiftTerm starts in `implicitAutoLeftToRight`: the terminal reorders,
autodetection is on, and paragraphs with no strong RTL character render
left-to-right. This makes RTL text work out of the box while leaving pure
LTR output pixel-identical to previous SwiftTerm releases. Autodetection
scans the paragraph for the first strong directional character, and it also
honors an explicit U+200E (LRM) or U+200F (RLM) mark.

## Escape sequences

Terminal applications control BiDi behavior with the sequences below. All of
them are live on this branch and can be probed with DECRQM.

### BDSM — BiDi support mode (ANSI mode 8)

| Sequence | Effect |
|---|---|
| `CSI 8 h` | Implicit mode: the terminal performs BiDi reordering and shaping |
| `CSI 8 l` | Explicit mode: the application supplies text in display order |

### SCP — Select Character Path (`CSI Ps SP k`)

Sets the paragraph base direction (the fallback direction when autodetection
is on, the fixed direction when it is off):

| Sequence | Effect |
|---|---|
| `CSI 0 SP k` (or `CSI SP k`) | Default direction (from ``TerminalOptions/initialBidiState``) |
| `CSI 1 SP k` | Left-to-right |
| `CSI 2 SP k` | Right-to-left |

### SPD — Select Presentation Directions (`CSI Ps SP S`)

The recommendation discourages SPD in favor of SCP, but SwiftTerm accepts it
as a compatibility alias because the original BiDi patches used it:

| Sequence | Effect |
|---|---|
| `CSI 0 SP S` | Left-to-right |
| `CSI 3 SP S` | Right-to-left |

### DEC private modes (DECSET/DECRST)

| Set | Reset | Effect |
|---|---|---|
| `CSI ? 2501 h` | `CSI ? 2501 l` | Autodetect paragraph direction from the first strong character; when off, the SCP-selected direction applies |
| `CSI ? 2500 h` | `CSI ? 2500 l` | Mirror horizontally asymmetric box-drawing characters on RTL runs |
| `CSI ? 1243 h` | `CSI ? 1243 l` | Swap the Left and Right arrow keys while the cursor is on an RTL paragraph |

### Querying, saving, and restoring

- **DECRQM** reports every mode above: `CSI 8 $ p` for BDSM and
  `CSI ? 2500 $ p`, `CSI ? 2501 $ p`, `CSI ? 1243 $ p` for the private
  modes. The reply is `CSI Ps ; Pm $ y` with `Pm` = 1 (set) or 2 (reset).
  For mode 1243, `Pm` is 4 (permanently reset) when the host draws all
  cells in logical order: ``Terminal/bidiHostPolicy`` is `.legacyLeftToRight`.
  The terminal does not ask the host for the report.
- **XTSAVE/XTRESTORE** (`CSI ? Pm s` and `CSI ? Pm r`) save and restore
  modes 2500, 2501, and 1243. The recommendation asks BiDi-aware
  applications to *save and disable* arrow swapping on startup and restore
  it on exit; SwiftTerm supports that dance.
- **RIS** and ``Terminal/resetToInitialState()`` restore the state
  configured in ``TerminalOptions``.

### Trying it from a shell

```bash
# Turn off autodetection and force RTL paragraphs:
printf '\e[?2501l\e[2 k'
echo "مرحبا بالعالم"

# Back to the default: autodetect, LTR fallback:
printf '\e[?2501h\e[0 k'

# Explicit mode: the app has done its own reordering:
printf '\e[8l'
```

## API for embedders

### Configuring initial state

``TerminalOptions`` gained three properties:

- ``TerminalOptions/initialBidiState`` — the ``BidiPresentationState`` that
  new paragraphs receive at startup and after a reset. The default enables
  implicit mode with autodetection and an LTR fallback.
- ``TerminalOptions/maximumBidiParagraphRows`` — the largest number of
  soft-wrapped rows the renderer treats as one paragraph (default 500).
  Above this limit, the renderer uses explicit display on each row. With
  autodetection, the rows keep logical column order. Without autodetection,
  the renderer uses the stored fallback direction: LTR keeps logical column
  order; RTL places logical column zero at the right edge. This limits the
  work for an endless wrapped line without changing its stored state.
- ``TerminalOptions/initialBidiArrowKeySwap`` — the initial value for
  arrow-key swapping (default `true`). Set it to `false` to disable swapping
  after startup and reset.

```swift
let options = TerminalOptions(
    initialBidiState: BidiPresentationState(
        supportMode: .implicit,
        autodetectDirection: true,
        fallbackDirection: .rightToLeft),
    initialBidiArrowKeySwap: false)
let terminal = Terminal(delegate: delegate, options: options)
```

### Inspecting and changing live state

``Terminal`` exposes the live protocol state:

- ``Terminal/currentBidiState`` — the state applied to the paragraph in
  progress and to new paragraphs (read-only; escape sequences change it).
- ``Terminal/bidiArrowKeySwap`` — read-write; the host can toggle arrow
  swapping directly, for example from a menu item.
- ``Terminal/bidiHostPolicy`` — read-write; how the host presents the BiDi
  state. A reset does not change it. `TerminalView` sets it.
- ``Terminal/bidiSupportEnabled``, ``Terminal/bidiAutodetectDirection``,
  ``Terminal/bidiRTLPreference``, ``Terminal/bidiBoxMirroring`` —
  convenience read-only views of the current state.

### Controlling the view

The AppKit and UIKit `TerminalView`s expose `bidiHostPolicy`
(``BidiHostPolicy``):

- `.respectTerminal` (default) — the view applies the per-paragraph BiDi
  state that the protocol stores in the buffer.
- `.legacyLeftToRight` — the view draws every cell in logical left-to-right
  order, which restores the pre-BiDi rendering behavior.

```swift
terminalView.bidiHostPolicy = .legacyLeftToRight   // opt out of BiDi rendering
```

The view copies the policy to ``Terminal/bidiHostPolicy``. With
`.legacyLeftToRight`, the arrow keys do not swap, and DECRQM reports mode
1243 as permanently reset. A host without a `TerminalView` that draws logical
order sets ``Terminal/bidiHostPolicy`` itself.

Selection, cursor placement, and mouse hit-testing map through the visual
layout, so they land on the cell the user sees, while the underlying
operations keep working on logical content.

### Arrow-key swapping

When ``Terminal/bidiArrowKeySwap`` is on and the cursor is on a paragraph
whose resolved base direction is RTL, the terminal swaps the sequences that
the Left and Right arrows send, so the cursor moves in the visual direction
of the key. The swap applies to the arrow keys and the keypad arrow keys, with
and without modifiers, and to the legacy and kitty keyboard encodings. Home
and End are not swapped. The feature is on by default. To disable it, set
``TerminalOptions/initialBidiArrowKeySwap`` to `false`, set
``Terminal/bidiArrowKeySwap`` to `false` at runtime, or send `CSI ? 1243 l`
from the application. A reset restores the configured initial value.

The terminal applies the swap in its key encoding step. The AppKit and UIKit
`TerminalView`s and the web host
(``Terminal/sendHostKey(key:code:modifiers:eventType:text:shiftedKey:baseLayoutKey:)``)
send all keys through this step. The `TerminalView` sequences that the kitty
encoder does not make, such as `ESC b` and `ESC f` for the word motion keys,
use the same swap.

The terminal finds the paragraph direction with the rules of the renderer:
the support mode, the fallback direction, and, with autodetection, the first
strong letter of the paragraph. Icons, flags, digits, and inline images do
not set the direction. A paragraph above
``TerminalOptions/maximumBidiParagraphRows`` uses explicit display. This
step reads the buffer only. It does not typeset text.

A key press chooses the swap. The auto-repeats and the release of that key
use the same choice, also when the cursor moves into a paragraph with a
different direction. Thus the application never gets a release for a key
that it did not see pressed. Each call of `sendKeyLeft()` or `sendKeyRight()`
and each step of the iOS floating cursor is a new press. A reset or a switch
between the normal and the alternate screen removes the stored choices.

## Rendering details

- Reordering uses CoreText's UAX #9 implementation over a one-glyph-per-cell
  probe line, which guarantees a stable 1:1 mapping between buffer cells and
  screen positions — the invariant that makes a character-cell terminal with
  BiDi possible.
- Arabic letters receive contextual forms (isolated, initial, medial, final)
  and the lam-alef combinations render as ligatures.
- Characters with a Unicode `Bidi_Mirrored` property (brackets, parentheses)
  render mirrored on RTL runs.
- With DECSET 2500, horizontally asymmetric box-drawing characters are also
  mirrored, so BiDi-unaware TUI frames stay coherent in RTL paragraphs.
- Each inline image stripe occupies one unit in the BiDi layout. All columns
  in the stripe move together. The renderer draws the image without horizontal
  reflection. SwiftTerm sets ``TerminalImage/columnWidth`` when it attaches
  the image. An image keeps its size in points, so `TerminalView` updates the
  width when the font changes.
- Paragraph layouts are cached and invalidated by a per-paragraph revision,
  so LTR-only workloads keep their previous performance.

## Testing

The repository includes a visual test harness at `Tools/BidiHarness` that
renders SwiftTerm next to a WebKit reference for scenarios covering
paragraph reflow, the six modes, reset behavior, box mirroring, combining
marks, selection, cursor movement, and scrollback. See its README for usage.

## Topics

### Configuration

- ``TerminalOptions/initialBidiState``
- ``TerminalOptions/maximumBidiParagraphRows``
- ``TerminalOptions/initialBidiArrowKeySwap``

### Live State

- ``Terminal/currentBidiState``
- ``Terminal/bidiArrowKeySwap``
- ``Terminal/bidiHostPolicy``
- ``Terminal/bidiSupportEnabled``
- ``Terminal/bidiAutodetectDirection``
- ``Terminal/bidiRTLPreference``
- ``Terminal/bidiBoxMirroring``

### Types

- ``BidiPresentationState``
- ``BidiPresentationMode``
- ``BidiSupportMode``
- ``BidiDirection``
- ``BidiHostPolicy``
