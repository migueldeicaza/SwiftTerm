# CPU profile: where the parse thread and the glyph path lose time

`io-baselines.md` measures wall-clock latency and frame delivery. This document
answers a different question: once the threading model is right, **what is the
CPU actually doing**, and how much of it is work the terminal needs done.

The short answer is that on a saturated parse thread, **71% of the cycles are
not terminal work** — they are reference counting, exclusivity checks, and
clearing cells that are about to be overwritten. That is the bulk of the
remaining distance to Ghostty, and none of it is algorithmic.

Source: a Time Profiler capture of Tecolot (Release, `new-io` at `6b51164`),
63.6s, macOS 27.0, Mac Studio. 51.7s of CPU across all threads.

---

## 1. How to reproduce

Instruments' Time Profiler template, attached to a Release build, Deferred
recording, 1ms sample interval. Then export and rebuild the trees yourself
rather than reading the UI — the aggregate numbers below all come from the
exported samples:

    xcrun xctrace export --input /path/to.trace \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
        --output tp.xml

Two things about the export are worth knowing before anyone repeats this.
Frames *and whole backtraces* are deduplicated by reference — a naive parser
that handles `<frame ref=…>` but not `<tagged-backtrace ref=…>` silently drops
about 60% of the samples as empty stacks, and every tree comes out wrong in the
same direction. And the capture used `record-waiting-threads=0`, so **every
sample is a running thread**: there is no blocked time in this data at all. See
§5 before drawing any conclusion about locks from it.

---

## 2. Shape of the run

CPU per 5-second window, in ms, by category:

| t(s) | parse | main | read | glyph raster | other |
| ---: | ----: | ---: | ---: | -----------: | ----: |
| 10 | 1206 | 167 | 171 | 6 | 48 |
| 15 | 4794 | 750 | 656 | 24 | 296 |
| 20 | 4745 | 480 | 164 | 1 | 16 |
| 25 | 4918 | 488 | 168 | 1 | 10 |
| 30 | 4710 | 436 | 121 | 0 | 36 |
| 35 | 4932 | 325 | 148 | 0 | 7 |
| 40 | 4952 | 611 | 346 | 0 | 251 |
| 45 | 3804 | 1393 | 423 | **8219** | 1216 |
| 50 | 0 | 34 | 0 | 0 | 56 |

Two phases, and they fail differently.

**Phase A, t≈12–48s — streaming.** `swiftterm-io-reader` runs at 98% of one core
(4900ms of every 5000ms window) and nothing else is close: the main thread is at
~10%, `swiftterm-io-gather` at ~3%, and that gather thread's time is 2.08s of
blocking `read(2)` plus 87ms of `poll(2)`. The threading model is doing its job.
Throughput in this phase is exactly `1 / parse cost` — there is no second
bottleneck to blame, so §3 is where all the headroom is.

**Phase B, t≈45–50s — a glyph storm.** 8.2s of CPU in ~4s of wall clock,
rasterizing glyph outlines on CoreAnimation's render workers, while the main
thread nearly triples. This is §4.

Totals by thread over the whole trace:

| Thread | CPU | Note |
| --- | ---: | --- |
| `swiftterm-io-reader` | 34,061 ms | the bottleneck |
| CA render workers (many) | 10,303 ms | 8.2s of it is glyph rasterization |
| Main thread | 5,107 ms | of which `TerminalView.draw` is 3,010 ms |
| `swiftterm-io-gather` | 2,197 ms | 2,080 ms blocked in `read` |

---

## 3. Phase A: 71% of the parse thread is overhead

Self time on `swiftterm-io-reader`, 34,061 ms total:

| | ms | % of thread |
| --- | ---: | ---: |
| ARC (retain / release / weak / unowned) | 14,798 | **43.4%** |
| `swift_beginAccess` (exclusivity) | 3,385 | **9.9%** |
| Blank-line clear (`assign(repeating:count:)`) | 5,559 | **16.3%** |
| malloc / free | 503 | 1.5% |
| **Sum** | **24,245** | **71.2%** |

Ghostty pays none of the first two, and its cell clear is a real `@memset`.
That table *is* the gap, restated.

Top self-time symbols, same thread:

| ms | Symbol |
| ---: | --- |
| 6042 | `RefCounts::doDecrementSlow` |
| 5559 | `UnsafeMutablePointer.assign(repeating:count:)` |
| 2554 | `swift_beginAccess` |
| 2049 | `RefCounts::incrementSlow` |
| 1676 | `swift_release` |
| 1200 | `swift_unownedRetainStrong` |
| 837 | `swift_retain` |
| 664 | `EscapeSequenceParser.parse(data:)` |
| 646 | `swift_weakLoadStrong` |
| 635 | `DYLD-STUB$$swift_beginAccess` |
| 520 | `swift_weakCopyInit` |

The first entry in that list is the whole story of §3.1.

### 3.1 ARC is on the side-table path, and one `weak` per class put it there

The dominant ARC symbols are `doDecrementSlow` (6.0s) and `incrementSlow`
(2.0s) — the **side-table** paths, not the inline fast path.

An object grows a `HeapObjectSideTableEntry` the first time someone forms a
**`weak`** reference to it, and the transition is one-way: there is no path back
to inline refcounting for the rest of the object's life. Measured on this
machine (`swiftc -O`, retain/release driven through `dlsym`'d runtime entry
points so the ARC optimizer cannot pair them away):

| | ns/op |
| --- | ---: |
| retain + release, inline refcount | 3.49 |
| retain + release, side table | **32.38** |
| read through `unowned`, inline refcount | 5.74 |
| read through `unowned`, side-tabled object | **25.14** |
| read through `unowned(unsafe)` | 5.69 |
| read through `weak` | 21.80 |

So a side table costs **9.3× on every retain/release** of that object, forever,
no matter who caused it.

Two corrections to what one might assume here, both checked by reading the
refcount word (`InlineRefCountBits` bit 63, `UseSlowRC`) after forming each kind
of reference:

- **`unowned` does not create a side table.** The unowned count lives in the
  inline bits (the word goes `0x3` → `0x5`). Only `weak` flips `UseSlowRC`.
- **`unowned` is therefore not what taints `Terminal`.** It has its own,
  much smaller cost — an atomic liveness check per read, ~5.7 ns against ~0 for
  `unowned(unsafe)` — which is where `swift_unownedRetainStrong` (1.2 s, 1.03 s
  of it inside `EscapeSequenceParser.parse`) comes from. Worth fixing, but
  second.

The references that actually side-table the two hot objects are all `weak`:

**`Terminal`**
- `Terminal.swift:789`, `:790`, `:885` — `normalBuffer.scroll = { [weak self] … }`
  and the `altBuffer` twin. This one is in the hot path itself: it is the
  `closure #1 in Terminal.init` that shows 458 ms with a `swift_weakLoadStrong`
  inside it.
- `Terminal.swift:6825` — the DECSET 2026 timeout `DispatchWorkItem { [weak self] }`.
  Cold, fires at most once per synchronized-output window, but taints all the same.
- `iOSAccessoryView.swift:24` — `weak var terminal: Terminal?` (iOS only, so not
  in this trace, but it taints there).

**`Buffer`**
- `BufferLine.swift:49` — `weak var owningBuffer: Buffer?`, formed for every line.
- `Buffer.swift:252`, `:257`, `:265` — the `[weak self]` in `setupLinesCallbacks`,
  of which `onLineRecycled` runs on every scroll.

Callers of `doDecrementSlow` on this thread are then exactly the hot parser
functions retaining and releasing those two objects: `Terminal.scroll` (1040 ms),
`closure #7 in configureParser` (999 ms), `dispatchExecute` (993 ms),
`EscapeSequenceParser.parse` (909 ms).

**Fix.** De-table `Terminal` and `Buffer` by removing *every* `weak` reference to
them — the constraint is total, since one survivor keeps the side table and the
whole win. The closure callbacks (`Buffer.scroll`, `setupLinesCallbacks`) should
become plain `unowned(unsafe)` back-pointers with direct calls, which removes
the weak load and the closure indirection together. The two genuinely-deferred
sites need more care than an annotation: see §3.1.1.

#### 3.1.1 The two sites that cannot just be re-annotated

`Terminal.swift:6825` is a real deferred async — the work item may outlive any
particular caller, and `[weak self]` is the correct pattern there in isolation.
Swapping it to `unowned(unsafe)` would trade a 9.3× ARC tax for a use-after-free.
The options, in increasing order of intrusiveness: capture `self` **strongly**
and accept that a Terminal with a pending timeout stays alive for at most
`synchronizedOutputTimeoutSeconds` after its last external reference drops
(bounded, safe, no dangling); or hold a small lifetime box that both Terminal and
the work item retain strongly, with the box carrying an `unowned(unsafe)`
terminal plus a `valid` flag cleared under `terminalLock` in `Terminal.deinit`.
The box moves the `weak`-equivalent cost onto an object nobody touches in a hot
path.

`BufferLine.owningBuffer` is the other one. A blank/template line can be cached
on `Terminal` (`blankLine`) and cloned across a buffer reset, so line lifetime is
*not* strictly nested inside buffer lifetime and `unowned(unsafe)` there is not
obviously safe. The field exists only so `copyFrom` can ask which of two
colliding same-kind semantic marks is the live origin; the cheaper answer is
probably to stop storing a reference at all and pass what `copyFrom` needs at the
call site.

### 3.2 `Terminal.scroll` is 44% of the thread

`Terminal.scroll(isWrapped:)` is 15,062 ms inclusive. Its subtree:

```
15062  Terminal.scroll(isWrapped:)                              Terminal.swift:6487
 6388    CircularBufferLineList.recycle(clearAttribute:)         CircularList.swift:332
 5505      BufferLine.clear(with:)                               BufferLine.swift:158
 5381        UnsafeMutablePointer.assign(repeating:count:)
 1852    Terminal.selectionsAdjustForInPlaceScroll(...)          Terminal.swift:360
  533      swift_weakLoadStrong
  511      swift_weakCopyInit
  463      doDecrementSlow
 1096    TerminalView.scrolled(source:yDisp:)                    MacTerminalView.swift:1244
  566      incrementSlow
 1005    doDecrementSlow
  943    CircularBufferLineList.shiftElements(start:count:offset:)
  422    BufferLine.__allocating_init(from:)
```

Three separate problems live in there.

**(a) Every recycled line is cleared to its full width — 5.4s.** `clear(with:)`
does `data.update(repeating: empty)` over all `cols` cells, and `handlePrint`
then overwrites them. `CharData` is a POD struct, so this is semantically a
memset, but `assign(repeating:count:)` compiles to a scalar store loop rather
than a vectorized fill. Two independent wins: track a per-line high-water mark
of written cells and clear only up to it (most terminal lines are far shorter
than `cols`), and get the remainder down to an actual memset.

**(b) `selectionsAdjustForInPlaceScroll` runs per scrolled line with no
selection active — 1.85s.** It iterates `[WeakSelection]`, and `for entry in
selections` alone costs `swift_weakCopyInit` + `swift_weakLoadStrong` (1.04s of
atomic side-table traffic) before `adjustForInPlaceScroll` immediately returns on
its `guard active` at `SelectionService.swift:45`. A plain non-weak
`hasActiveSelection` flag checked before the loop makes the whole thing free in
the common case.

**(c) The `scrolled` delegate fires once per scrolled line — 1.1s.** All it does
is `markScrolledDirty()` + `frameDriver.markDirty()`, and
`markScrolledDirty` (`AppleTerminalView.swift:864`) takes `viewStateLock` to set
one Bool. That is a lock acquire, a lock release, and a slow-path retain
(`incrementSlow`, 566ms) per scrolled line, to set a flag that is only read once
per frame. Set a local flag in `scroll` and notify once at the end of `feed`.

### 3.3 Exclusivity checking is on — 3.4s

`Package.swift:55`–`57` carries a commented-out
`.unsafeFlags(["-enforce-exclusivity=none"])`, so Release builds run with
checked exclusivity and every read-modify-write of a class stored property emits
a `swift_beginAccess`. Biggest contributors on the parse thread:

| ms | Caller |
| ---: | --- |
| 463 | `Terminal.cmdLineFeedBasic()` |
| 444 | `BufferLine.bump()` |
| 380 | `Terminal.scroll(isWrapped:)` |
| 337 | `CircularBufferLineList.getCyclicIndex(_:)` |
| 234 | `Terminal.handlePrint(_:)` |
| 171 | `BufferLine.isWrapped.setter` |

Two of those are worth calling out on their own terms, independent of the flag:

- `BufferLine.bump()` is `generation &+= 1` behind a runtime exclusivity check,
  and it is reached from the `didSet` on *every* line property — `isWrapped`,
  `bidiState`, `renderMode`, `semanticMarks`, `images`. `recycle` assigns
  `isWrapped = false` on every single scroll purely to trip that observer, and
  `clear(with:)` has already bumped one line earlier.
- `getCyclicIndex` costs 337ms **despite** the comment at `CircularList.swift:292`
  claiming the private version lets the optimizer elide `swift_beginAccess`. It
  reads `startIndex` and `array.count`, both stored properties of a class. The
  comment is aspirational; the profile says the call is still there.

### 3.4 What the remaining ~29% is doing

For scale, the actual terminal work on the same thread:

| ms (incl.) | |
| ---: | --- |
| 18,762 | `dispatchExecute` — of which 16,986 is `cmdLineFeedBasic` → `scroll` |
| 6,220 | `Terminal.handlePrint` |
| 1,493 | · `Buffer.insertCharacter` |
| 926 | · `UnicodeUtil.columnWidth` |
| 2,006 | `dispatchCsi` |
| 426 | `Terminal.updateRange` |
| 359 | `Buffer.insertAsciiRun` |

`columnWidth` at 926ms is notable: `computeColumnWidth` is being reached often
enough to matter, which suggests the ASCII fast path in `insertAsciiRun` is not
catching as much of this workload as intended. Worth a look, but it is a
distant second to §3.1–3.3.

---

## 4. Phase B: the glyph storm

8,258 ms of CPU in `CGGlyphBitmapCreateWithPathAndDilation_8` — CoreGraphics
building glyph bitmaps from outlines, fanned out over `dispatch_apply` workers
off `CA::CG::Queue::batch_render_callback`. Underneath it: 3,786 ms inside
`Clipper2Lib` polygon clipping, 740 ms in `CGFontCreateGlyphPath`, and 1,144 ms
in `THierVariationsFontHandler` — the font in use is a **variable** font, whose
outline extraction is markedly more expensive than a static one.

Meanwhile the main thread, in that same window, spends 754 ms in
`drawTerminalContents` and **674 ms of it (89%) in `glyphSlotFit`**. Across the
whole trace that is 940 ms out of 3,010 ms of drawing:

```
2987  TerminalView.drawTerminalContents
1030    SnapshotTextBuilder.buildAttributedString
 940    TerminalView.glyphSlotFit  ->  CTFontGetBoundingRectsForGlyphs   (927)
 330    Sequence.compactMap
  99    CTFontDrawGlyphs
```

`GlyphSlotFit.calculate` (`AppleTerminalView.swift:445`) is called per glyph, per
run, per row, **per frame** for every segment with `columnWidth >= 2`, and it is
completely uncached — it re-asks CoreText for advances and ink bounds every
frame for glyphs whose metrics never change. Ghostty computes the equivalent
constraint once, when the glyph enters the atlas.

**Fix.** Memoize on `(CTFont, CGGlyph, columnWidth)`. `GlyphSlotFit` is three
`CGFloat`s and the key is cheap; this removes the 940 ms outright.

The 8.2 s underneath is the same problem one level down — a screenful of
distinct wide glyphs re-rasterized frame after frame instead of being drawn from
cache. One contributing detail we control: cell origins are snapped to the
device pixel grid (`computeFontDimensions`, `AppleTerminalView.swift:920`), but
`GlyphSlotFit`'s `dx = (slotWidth - advance.width * scale) / 2` is not, so
centered wide glyphs land on arbitrary subpixel phases and each distinct phase
is a separate entry in CG's bitmap cache. Rounding `dx` to the device pixel grid
collapses those. Whether that is enough to end the storm, or whether this
workload simply exceeds what CG's cache will hold and wants the Metal atlas
path, needs a measurement rather than a guess.

Ruled out while looking: the rare down-scaled path in
`drawTerminalContents` that calls `CTFontCreateCopyWithAttributes` per glyph
costs 6 ms total. It is not implicated.

---

## 5. Limits of this data

- **No blocked time.** `record-waiting-threads=0`, so every sample is a running
  thread. `TerminalLock.withLock` shows no measurable cost here *only* because
  time spent waiting on it is not in the capture. Nothing in this document says
  anything about lock contention, and `markScrolledDirty`'s per-line
  `viewStateLock` in §3.2(c) is called out for the lock *operations*, not for
  contention we observed.
- **One workload, one machine.** Phase A looks like a flood of mostly-ASCII
  output and phase B like a screen of wide glyphs, but the trace does not record
  what was run. The percentages are stable within phase A; they should not be
  assumed to hold for the `bidi`, `tui`, or `binary` baselines.
- **Attribution near inlined frames.** Self time landing on `DYLD-STUB$$…`
  entries (635 ms of `swift_beginAccess`, 414 ms of `swift_release`) is counted
  into the totals in §3, which is right for the aggregate but means individual
  caller attributions are approximate at the margin.

---

## 6. Ranked work

Everything in the first group lands on the one saturated thread in phase A, so
it converts directly into streaming throughput.

| # | Change | Recovers | Where |
| --- | --- | ---: | --- |
| 1 | De-table `Terminal` / `Buffer` by removing **every** `weak` reference to them (all six sites, or the win is zero) | **done — +21.0% / +7.3%** | §3.1, §7 |
| 1b | Then `[unowned(unsafe) self]` for the parser handler closures and the parser's back-reference; `parser` made `private` | **done — ~+2%** | §3.1, §9 |
| 2 | Clear only to a per-line high-water mark (the memset half was a red herring) | **done — +34% flood, −2.6% long lines** | §3.2(a), §10 |
| 3 | Non-weak selection registry + active-count guard | **done — +9.0%** | §3.2(b), §8 |
| 4 | Coalesce the per-line `scrolled` callback to once per `feed` | 1.1 s | §3.2(c) |
| 5 | `-enforce-exclusivity=unchecked` for Release; drop `bump()` from the `didSet` chain on the scroll path | 3.4 s | §3.3 |
| 6 | Cache `GlyphSlotFit` by `(font, glyph, columnWidth)` | 0.94 s of draw | §4 |
| 7 | Snap `GlyphSlotFit.dx` to the device pixel grid, then re-measure the storm | up to 8.2 s | §4 |

Arithmetic on items 1–5 puts roughly **2.5×** on the table for phase A
throughput before anyone touches the parser's algorithm. Items 6 and 7 are
about the hitch, not the throughput, and 7 is explicitly measurement-led: land 6
first, re-capture, and only then decide whether the subpixel snap is sufficient
or the workload belongs on the Metal atlas.

No item here has a number in `io-baselines.md` yet. Each one should land with a
before/after against the relevant baseline case, per the rule in that document.

---

## 7. Item 1, landed

De-tabling `Terminal` and `Buffer`. The rule that shaped the change: the side
table is per-object and one-way, so **every** `weak` reference to these two had
to go or the win would be exactly zero.

### 7.1 What changed

| Site | Was | Now |
| --- | --- | --- |
| `Buffer.scroll` | `{ [weak self] wrapped in self?.scroll(isWrapped: wrapped) }`, installed 3× | `unowned(unsafe) var terminal` on `Buffer` + a direct `scroll(_:)` call |
| `CircularBufferLineList` | 4 closures (`makeEmpty`, `onLineRecycled`, `onLinePushed`, `onLineAttached`), 3 of them `[weak self]` | one `unowned(unsafe) var owner: Buffer` + direct method calls |
| `BufferLine.owningBuffer` | `weak var owningBuffer: Buffer?` | `BufferRef` box, cleared in `Buffer.deinit`; `owningBuffer` kept as a computed accessor so call sites are unchanged |
| DECSET 2026 timeout | `DispatchWorkItem { [weak self] … }` | strong capture (see below) |
| `TerminalAccessory.terminal` | `weak var terminal: Terminal?` | deleted — it was assigned once and never read |

Two of those deserve their reasoning recorded.

**The timeout work item captures `self` strongly.** No `unowned` variant is
race-free here: the item outlives its caller by design, so any non-owning
reference races teardown. A strong capture cannot dangle, and libdispatch
releases the block once the item runs or its deadline passes — so a Terminal
abandoned with a synchronized-output window open outlives its last external
reference by at most `synchronizedOutputTimeoutSeconds` (1 s). That bounded,
benign delay buys back a 9.3× tax the parse loop was paying continuously.

**`BufferLine` reaches its buffer through a box, not `unowned(unsafe)`.** Line
lifetime is *not* strictly nested inside buffer lifetime — a template line can be
cached on `Terminal` and survive a buffer reset — so a raw back-pointer there
would be a genuine dangling risk rather than a nested-lifetime shortcut. The box
is held strongly from both ends and `Buffer.deinit` nils it, so a line that
outlives its buffer reads nil. `Buffer` itself never has a weak reference formed
against it, which is the whole point.

### 7.2 A regression the closures had been hiding

Collapsing four optional closures into one back-pointer changed a silent no-op
into a hard requirement, and the test suite caught it immediately: reflow builds
**scratch** `CircularBufferLineList`s to stage a rearrangement, and those had only
`makeEmpty` installed. Their `onLineAttached` / `onLinePushed` hooks were nil, so
staging a line neither re-stamped its owner nor moved the buffer's image counter.
A single `owner` back-pointer would have done both — double-counting every line
carrying an image.

`CircularBufferLineList.isLive` restores the split: a scratch list still borrows
`owner` so an empty slot can be filled, but only the buffer's live list stamps
ownership and counts. Worth noting for its own sake — the old design encoded a
real distinction in which closures were left nil, and nothing named it.

### 7.3 Result

Measured with a headless harness shaped like phase A: 200×50 terminal, 80-column
lines terminated CRLF for the scroll-heavy case (~44% of work in `Terminal.scroll`,
matching §3.2), 4000-column lines for the print-heavy case. Best of five runs,
Release, same machine as the trace.

| Case | Before | After | |
| --- | ---: | ---: | ---: |
| flood (scroll-heavy) | 96.8 MB/s | **117.1 MB/s** | **+21.0%** |
| wide lines (print-heavy) | 199.8 MB/s | **214.4 MB/s** | **+7.3%** |

The split is what the profile predicts: the scroll path retains and releases
`Buffer` and `Terminal` far more often than the print path, so it gains more.

Verified: `Terminal`, `Buffer`, `normalBuffer` and `altBuffer` all read back with
`UseSlowRC` clear at runtime; 784 tests pass; `BufferOwnerRefTests` pins the
invariants — no side table on either object, an attached line naming its owner, a
line outliving its buffer reading nil, and the image counter surviving repeated
reflow.

### 7.4 What this does not do

The remaining ARC on the parse thread is ordinary inline retain/release traffic,
and there is a lot of it (§3 measured 43.4% of the thread in ARC overall; only the
side-table multiplier is gone). Item 1b — the `[unowned self]` handler closures
and the parser's `unowned var terminal`, worth ~1.2 s of atomic liveness checks —
is untouched and now the cheapest remaining ARC win. Items 2 through 7 are
unaffected.

---

## 8. The last weak on the parse thread

With `Terminal` and `Buffer` de-tabled (§7), one weak reference was left costing
real time in the parser: the selection registry.

| Symbol | ms on the parse thread | Attributed to |
| --- | ---: | --- |
| `swift_weakLoadStrong` | 551 | `selectionsAdjustForInPlaceScroll` |
| `swift_weakCopyInit` | 540 | `selectionsAdjustForInPlaceScroll` |
| `swift_weakDestroy` | 64 | `destroy for Terminal.WeakSelection` |
| | **1 155** | |

All of it to notify a selection that was almost always inactive and returned
immediately on `guard active`. The `weakCopyInit` half is worth calling out: it
came from `for entry in selections` **copying each weak box**, which is a
retain on the side table — the loop paid to copy references it then only read.

### 8.1 Why it could not just be re-annotated

`SelectionService` owns its `Terminal` strongly, so the registry must not retain
or the two form a cycle — that is why it was weak. Making the slots
`unowned(unsafe)` needs the entries removed when a service dies, and the obvious
`deinit` → `terminal.unregister` has a hazard worth recording:

`AppleTerminalView` builds its `SelectionService` **inside** a
`terminalLock.withLock` block (`AppleTerminalView.swift:637`), and that same
assignment releases the previous service. A `deinit` that took the lock
unconditionally would therefore deadlock on any re-setup — `TerminalLock` is a
ticket lock and is not re-entrant. The registry mutations run through
`withSelectionRegistry`, which uses `terminalLock.isLockedByCurrentThread` to
take the lock only when it is not already held. `SelectionRegistryTests`
exercises exactly that shape.

### 8.2 What changed

- `WeakSelection` → `SelectionSlot` holding `unowned(unsafe) let value`,
  with `SelectionService.deinit` removing its own entry. No slot can outlive its
  service.
- Iteration is by index, so no box is copied.
- `Terminal.activeSelectionCount`, maintained by a `didSet` on
  `SelectionService._active`, lets the scroll path skip the registry entirely
  while nothing is selected — which is the normal state.

### 8.3 Result

Isolated A/B: the only difference between the two builds is the registry shape
(weak slots + copying loop + no guard, versus `unowned(unsafe)` + indexed loop +
active-count guard). Everything else, including §7, is identical.

| Case | weak registry | non-weak + guard | |
| --- | ---: | ---: | ---: |
| flood (scroll-heavy) | 106.2 MB/s | **115.8 MB/s** | **+9.0%** |
| wide lines (print-heavy) | 198.0 MB/s | **210.2 MB/s** | +6.2% |
| in-place scroll (DECSTBM), no selection | 85.9 MB/s | **93.6 MB/s** | **+9.0%** |
| in-place scroll, selection active | 85.5 MB/s | **92.7 MB/s** | **+8.4%** |

Two things to read out of that table. The scrollback-push flood gains as much as
the in-place case, because `Terminal.scroll` notifies selections there too once
the buffer is full (`Terminal.swift:6588`). And the *selection active* row still
gains 8.4% — the guard does nothing there, so that is the indexed non-weak loop
on its own, which is the part that needed the `unowned(unsafe)` change rather
than just an early return.

### 8.4 Coverage

`adjustForInPlaceScroll` had **no test coverage at all** before this change,
which is a poor place to add a fast-path guard: if `activeSelectionCount` ever
drifts, selections silently stop tracking in-place scrolls and nothing fails.
`SelectionRegistryTests` now covers the count against activate / deactivate /
re-activate / dealloc, registry removal on `deinit`, an active selection
following an in-place scroll, a selection scrolled out of its region being
cleared, and the construct-and-release-under-the-lock shape from §8.1.

Both behavioural tests were mutation-checked: forcing the guard to `false` fails
them, so they are testing the invariant rather than passing vacuously.

---

## 9. Item 1b: the handler closures

The parser's back-references, converted from `unowned` to `unowned(unsafe)`:

- `Terminal.configureParser` — 8 `[unowned self]` handler closures
  (`printHandler`, `printStateReset`, and the six dispatch fallbacks)
- `EscapeSequenceParser.terminal`
- `Terminal.DECRQSS.terminal` and `SixelDcsHandler.terminal`

Unlike §7 and §8 this is not about side tables — `unowned` never created one
(§3.1). It removes `swift_unownedRetainStrong`, the atomic liveness check a safe
`unowned` performs on **every read**: 1 200 ms on the profiled parse thread,
1 030 ms of it attributed directly to `EscapeSequenceParser.parse`.

### 9.1 Result

The delta is small enough that single runs cannot resolve it, so these are
interleaved alternating runs of two statically-linked binaries:

| Case | pre-1b | post-1b | |
| --- | ---: | ---: | ---: |
| flood (scroll-heavy) | 117.6–119.6 MB/s | 120.4–120.8 MB/s | **~+2%** |
| wide lines (print-heavy) | 213.8–214.3 | 216.4–216.9 | ~+1.2% |
| in-place scroll, no selection | 95.0–95.3 | 96.0–96.8 | ~+1.3% |
| in-place scroll, selection active | 95.7–96.0 | 96.3–96.4 | ~+0.6% |

Consistent, and in line with what the trace predicts (1 200 ms of 34 061 ms is
3.5% of the parse thread; the harness also measures work outside it). But it is
an order of magnitude smaller than §7 (+21%) and clearly below §8 (+9%).

Absolute numbers drifted between sessions — pre-1b measured 114.6 MB/s on the
flood earlier and 118.6 MB/s here, on the same binary. Only interleaved
comparisons on this table are meaningful; do not read across to §7 or §8.

### 9.2 The trade, and how it was closed

`Terminal` owns `parser`, and these closures and handlers live on that parser, so
their lifetime is nested by construction.

As first written there was one way to break that: `Terminal.parser` was a
**public var**, so an embedder could pull the parser out and keep it after the
terminal was gone. Under `unowned` that misuse traps; under `unowned(unsafe)` it
is undefined behaviour. The misuse was always a programming error, but the
failure mode got worse — a poor trade for ~2%.

**`parser` is now `private`**, which removes the hatch entirely and makes the
annotation unconditionally sound rather than a bet on embedder behaviour. Some
notes on that change:

- Nothing in the repository used `terminal.parser` — not the app, the
  benchmarks, or the tests, which construct `EscapeSequenceParser()` directly.
- `private` (not merely `internal`) turned out to be achievable: every use is
  inside `Terminal.swift`. That also stops *future* module-internal code from
  reintroducing the hatch.
- It is still a **breaking API change** for any out-of-tree embedder that
  reached for `terminal.parser`. The one documented use — installing a custom
  OSC handler — is served by the existing public
  `Terminal.registerOscHandler(code:handler:)`, and the doc comment on
  `EscapeSequenceParser.oscHandlers` now points there instead of at the parser.
- `EscapeSequenceParser` remains a public type but is no longer vended by any
  public API. Tightening that further was left alone as out of scope.

With the hatch closed, §9 is no longer a safety trade — just a ~2% win. The
weakest remaining justification in this document is its size, not its risk.

The two `[unowned self]` captures left in `MacTerminalView` (the
`NSWindow` key-notification observers) were deliberately not converted: they are
not on the parse path, and a NotificationCenter token's lifetime is not nested in
the view's, so `unowned(unsafe)` there would be a genuine hazard for no gain.

---

## 10. Item 2: clearing recycled rows

`BufferLine.clear` stored blanks over the whole row on every recycle — 5 559 ms,
16.3% of the parse thread, the single largest non-ARC entry in §3.

### 10.1 The memset half of the plan was wrong

§3.2(a) proposed two independent wins: clear less, and get the remainder down to
a real vectorised fill. The second one does not exist. Measured on a hot 200-cell
buffer, an exponential `memcpy` doubling fill beats `update(repeating:)` 58 ns
against 94 ns per line — but that is instruction throughput on an L1-resident
buffer, and `recycle` walks a different row of the scrollback ring every time.
Re-measured against a 5 000-line ring:

| | ns/line | GB/s |
| --- | ---: | ---: |
| `update(repeating:)` (today) | 111.8 | 42.9 |
| memcpy doubling | 112.4 | 42.7 |
| doubling, 50% of the row | 76.7 | 62.6 |
| doubling, 25% of the row | 44.0 | 109.0 |

The clear is memory-bandwidth bound, not store-loop bound. How you write the
bytes is irrelevant; how many you write is everything. **Only the high-water mark
matters** — the vectorisation idea was measuring the wrong thing.

Worth recording alongside it: `CharData` is **24 bytes** (size 23, stride 24, of
which `Attribute` is 14). That is what makes a row expensive to touch at all, and
it is a standing difference from Ghostty's packed cell. Shrinking it would pay
off everywhere, not just here — a much larger change, not attempted.

### 10.2 What changed

`BufferLine` gained `usedLength`, an upper bound on the cells that may hold
anything other than a blank carrying `tailAttribute`, with the invariant that
every cell in `usedLength ..< dataSize` is exactly `CharData(attribute: tailAttribute)`.
`clear(with:)` then wipes only `0 ..< usedLength`, and falls back to a full wipe
when the row was fully written or when the erase attribute differs from the one
the tail already carries.

Maintaining that bound is the entire risk: under-report it once and stale text
survives on a recycled row, silently. So the hot, simple writers (the subscript
setter, ranged `fill`, `replaceCells`, ranged `copyFrom`) track it precisely,
while every bulk or index-shuffling operation (`insertCells`, `deleteCells`,
`resize`, whole-line `copyFrom`, `copyForSnapshot`, both initialisers) just sets
it to `dataSize` — always safe, and costs only a full clear next time. `data` is
`private`, so this file bounds the audit.

### 10.3 Result

Interleaved alternating runs, same harness as §9:

| Case | pre | post | |
| --- | ---: | ---: | ---: |
| flood (scroll-heavy) | 117.3–118.6 MB/s | 157.3–161.4 MB/s | **+34%** |
| wide lines (print-heavy) | 210.1–212.3 | 203.8–207.3 | **−2.6%** |
| in-place scroll (DECSTBM) | 93.9–96.2 | 93.9–94.9 | flat |

Three different behaviours, all expected:

- **flood** pushes 80-column lines through a 200-column scrollback, so a recycle
  clears 40% of each row instead of 100%. This is the case §3.2(a) measured.
- **wide lines** are 4 000 characters and wrap, so every row is fully written,
  `usedLength == dataSize`, and the clear is full anyway — leaving only the
  per-write bookkeeping, which is the 2.6%. A plausible contributor is that
  `usedLength` is a class stored property and exclusivity checking is still on
  (item 5); if so, item 5 absorbs it.
- **in-place scroll** never recycles — DECSTBM shifts rows and installs a fresh
  `BufferLine`, so `clear` is not on that path at all.

The regression is real and consistent, and it was left in place: recovering it
means either an unchecked cell setter (reintroducing exactly the footgun this
design avoids) or moving terminal-level logic into `BufferLine`. A 2.6% cost on
4 000-character lines for 34% on ordinary output is a good trade, recorded here
so it can be revisited if long-line throughput ever matters.

### 10.4 Coverage

Two layers, because the failure is silent:

- A **DEBUG-only assertion** in `clear(with:)` verifies the invariant against the
  actual cells, so all 801 tests audit every writer on every clear rather than
  only the paths someone thought to test. Mutation-checked: dropping the
  subscript setter's tracking makes it fire.
- `LineRecycleTests` covers the behaviour itself, since that assertion is
  compiled out of release: stale text from a longer line, trailing cells past
  new content, a changed erase attribute repainting the tail, erase-in-line
  residue, and resize-then-recycle. Also mutation-checked — the same injected
  bug produces 234 failures with the assertion disabled.
