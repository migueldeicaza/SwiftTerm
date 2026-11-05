# Customizing the Terminal

Configure fonts, colors, cursor style, and input behavior.

## Overview

SwiftTerm's ``TerminalView`` exposes a number of properties for customizing the
terminal's appearance and input handling. This guide covers the most common
customization points available on both macOS and iOS.

## Fonts

Both the macOS and iOS ``TerminalView`` expose a `font` property. Setting it
replaces the font used for rendering terminal text:

```swift
// macOS
terminalView.font = NSFont(name: "SF Mono", size: 14)!

// iOS
terminalView.font = UIFont(name: "Menlo", size: 14)!
```

Under the hood, the view manages a `FontSet` that derives bold, italic, and
bold-italic variants from the base font. If you need to override individual
variants on iOS, use `setFonts(normal:bold:italic:boldItalic:)`.

Call `resetFontSize()` to return to the default font.

## Colors

### Foreground and Background

The view-level native colors control the default foreground and background:

```swift
terminalView.nativeForegroundColor = NSColor.white   // or UIColor.white
terminalView.nativeBackgroundColor = NSColor.black    // or UIColor.black
```

### ANSI Palette

To install custom base ANSI colors on a view, use
``TerminalView/installColors(_:)``.
The array must contain exactly 16 ``Color`` values. SwiftTerm derives entries
16 through 255 from these colors and the selected ANSI 256 strategy:

```swift
terminalView.installColors(myCustomPalette)
```

### Selection and Cursor Colors

```swift
terminalView.selectedTextBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.3)
terminalView.caretColor = NSColor.systemGreen
terminalView.caretTextColor = NSColor.black  // optional: text color under cursor
```

### Progress Bar Color

The OSC 9;4 progress bar follows the system accent color unless the host picks
one, which keeps it in step with a themed terminal. The error and paused states
keep their system red and orange either way:

```swift
terminalView.progressBarColor = NSColor.systemPurple  // nil restores the accent color
```

## Cursor Style

The cursor style is typically controlled by the remote application via escape
sequences, but you can set an initial style through ``TerminalOptions``:

```swift
let options = TerminalOptions(cursorStyle: .steadyBar)
```

Available styles in ``CursorStyle``:
- `blinkBlock`, `steadyBlock`
- `blinkUnderline`, `steadyUnderline`
- `blinkBar`, `steadyBar`

## Input Behavior

### Option as Meta Key

On macOS, the Option key normally inserts special characters. Setting
`optionAsMetaKey` to `true` makes it send an ESC prefix instead, which is
essential for terminal applications like Emacs that rely on the Meta key:

```swift
terminalView.optionAsMetaKey = true
```

With it `false`, the key goes to the OS, which composes whatever the keyboard
layout puts behind it (Option+Q is `@` on a Turkish layout). The layout composes
nothing for the arrows, Home, End, the function keys, Enter, Tab and Backspace,
so `optionAsMetaKeyForFunctionalKeys` keeps Option as Meta on those keys alone:
Option+Left still moves a word back while Option+Q still types `@`, which is
what iTerm2 does when its Option key is set to "Normal":

```swift
terminalView.optionAsMetaKey = false
terminalView.optionAsMetaKeyForFunctionalKeys = true
```

On iOS with an external keyboard, `optionAsMetaKey` is available too. The iOS
view also supports toggling it at runtime with Option-Command-O.

### Mouse Reporting

By default the view forwards mouse events to the terminal. Set
`allowMouseReporting` to `false` to disable this and let the view handle mouse
events natively (selection only):

```swift
terminalView.allowMouseReporting = false
```

### Backspace Behavior

Some systems expect Backspace to send `Control-H` (0x08) rather than DEL (0x7f).
Toggle this with:

```swift
terminalView.backspaceSendsControlH = true
```

## Link Reporting and Link Activation

SwiftTerm's Apple terminal views can resolve links from two sources:

- **Explicit links**: OSC 8 hyperlink payloads emitted by the terminal app.
- **Implicit links**: URL-like text detected directly from rendered terminal content.

Use ``LinkReporting`` via `linkReporting` to control which source is used during
view-level link tracking:

```swift
terminalView.linkReporting = .none      // Disable link tracking
terminalView.linkReporting = .explicit  // Track OSC 8 links only
terminalView.linkReporting = .implicit  // Default: explicit first, then implicit fallback
```

Important: `.implicit` means "explicit + implicit fallback", not "implicit only."

Link activation is also gated by `linkHighlightMode`. The reporting mode chooses
how links are discovered during tracking, while highlight mode decides whether a
click/tap is allowed to open the link.

### Link Color

By default a highlighted link is underlined in its own text color. Set
`linkColor` to draw every highlighted link, explicit or implicit, in one color
instead; set it back to `nil` to restore the default:

```swift
terminalView.linkColor = NSColor.systemBlue
```

To color only the underline while keeping the text and strikethrough colors,
set `linkUnderlineColor` (`NSColor?` on macOS, `UIColor?` on iOS):

```swift
terminalView.linkUnderlineColor = NSColor.systemCyan
```

`linkUnderlineColor` takes precedence over `linkColor` for highlighted link
underlines, including OSC 8 and implicit links. Its default, `nil`, preserves
`linkColor` behavior (or the cell foreground when both are `nil`). It leaves
non-link decorations unchanged. Selection colors take precedence over both.

### What happens when the user activates a link

Set `TerminalOptions.enableOsc8Hyperlinks` to `false` to disable OSC 8 hyperlinks
at startup. Set `terminalView.enableOsc8Hyperlinks` to change this while the
terminal runs. The setting also hides links already in the buffer. Implicit URL
and path detection remain available.

When a click/tap lands on an active link, ``TerminalView`` calls
``TerminalViewDelegate/requestOpenLink(source:request:)`` with a
``TerminalLinkRequest``.

- `request.link` is the text from the terminal output, unchanged. It can be a
  relative path, a path with a `:line` or `:line:column` suffix, or a URL with
  any scheme. Treat it as untrusted data.
- `request.isExplicit` is true for an OSC 8 hyperlink. The program chose its
  target, and the target can be different from the visible text. It is false
  for a link that SwiftTerm detected in the visible text.
- `request.params` contains the key/value pairs of an OSC 8 hyperlink. It is
  empty for detected links.
- On macOS, `request.openDefault(_:)` checks the link before it opens it with
  `NSWorkspace`. HTTP and HTTPS links need a host. Mail links need an address.
  Custom URL schemes require confirmation, with Cancel as the default. Local
  files must exist and must not be executable files, scripts, applications, or
  other active content. The check resolves symbolic links and rejects remote
  file hosts. OSC 8 targets must have a scheme; detected paths can become file
  URLs. Alerts show as a sheet on the window of the view.
- When `resolvesLinksAgainstShellDirectory` is true, a detected relative path
  resolves against the shell's directory, when the shell reports it with OSC 7.
  Without OSC 7, or when the property is false, a relative path resolves
  against the directory of the application. When OSC 7 names a different host,
  detected paths are remote files, and SwiftTerm does not open them, with
  either value of the property.
- OSC 7 is terminal output, so it cannot prove that the session is local. A
  remote program can report a `file://localhost/...` directory. The property is
  false by default. `LocalProcessTerminalView` sets it to true. Keep it false
  for a view that shows a remote session. A local shell can still start a
  remote session, for example with ssh; SwiftTerm cannot see that.
- A custom delegate can give `openDefault` a rewrite of the link. For an OSC 8
  target, a rewrite must be a URL with a scheme, such as a `file://` URL.
  It can call `openDefault` later, for example after an async step. Nothing
  opens if the view is gone or if OSC 8 links were disabled.
- `openDefault` resolves a relative path when you call it. If you keep a request
  and the shell changes directory before that call, the path can resolve to a
  different file. Resolve it first and pass an absolute path to `openDefault`
  when it must refer to the file at click time.
- On iOS/visionOS, implement `requestOpenLink(source:request:)` to handle link
  taps (for example, with `UIApplication.open`). Without an implementation, a
  tap on a link does nothing. Check the scheme before you open the link.

### Migrate a macOS link delegate

An existing `requestOpenLink(source:link:params:)` implementation still runs
through the default implementation of the new method. On macOS, the old method
receives a checked, absolute URL. It does not receive the original text or
`isExplicit`. For example, `main.swift:12` can arrive as a `file://` URL without
the line number. Move to `requestOpenLink(source:request:)` if your app must
resolve a path or open a file at a line number.

For a `LocalProcessTerminalView` subclass, handle only the links that need your
app's own opener. Send other links to SwiftTerm's default opener:

```swift
override func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
    if !request.isExplicit, handleSourceLocation(request.link) {
        return
    }
    request.openDefault()
}
```

Here, `handleSourceLocation(_:)` is a method supplied by your app. It must check
the path before it opens a file. A terminal program can print a path or set an
OSC 8 target that points to an unexpected file or application. If your code
opens a link itself, SwiftTerm's default check does not run. Calling
`openDefault()` checks and opens the link; it does not return a checked URL for
another opener. An override that neither opens the link nor calls
`openDefault()` leaves the click without an action.

``TerminalViewDelegate/requestOpenLink(source:link:params:)`` is deprecated.
The default implementation of the new method calls it. On macOS, it gets the
link only after the check, as an absolute URL with a canonical path for local
files. On iOS/visionOS, it gets the original link.

### macOS behavior

- Tracking is driven by AppKit mouse movement.
- The default highlight mode is `.hoverWithModifier`, so holding Command while
  hovering enables link preview/highlighting and Command-click opens links.
- If you switch to `.hover`, link activation does not require Command.
- `.always` and `.alwaysWithModifier` only activate explicit OSC 8 links.
- Link previews escape invisible characters, directional controls, and line
  breaks. File previews show the canonical path.

### iOS and visionOS behavior

- Tracking is driven by `UIPointerInteraction` (iOS 13.4+) and
  `UIHoverGestureRecognizer` (iOS 13+).
- The default highlight mode is `.hover`.
- Single tap opens links only when the current `linkHighlightMode` considers the
  link active/visible.
- For modifier-based modes (`.hoverWithModifier`, `.alwaysWithModifier`),
  activation requires the Command key from a hardware keyboard.

## Terminal Options

``TerminalOptions`` controls engine-level settings. Create a custom options struct
and pass it when constructing a ``Terminal`` or ``HeadlessTerminal``:

```swift
let options = TerminalOptions(
    cols: 120,
    rows: 40,
    scrollback: 10_000,
    tabStopWidth: 4,
    cursorStyle: .steadyBar,
    termName: "xterm-256color",
    ansi256PaletteStrategy: .base16Lab
)
```

BiDi left/right arrow swapping requires opt-in. Set its initial value when you
create the terminal, or change the live terminal state later:

```swift
let options = TerminalOptions(initialBidiArrowKeySwap: true)
let terminal = Terminal(delegate: delegate, options: options)

terminal.bidiArrowKeySwap = false
```

A terminal reset restores `initialBidiArrowKeySwap`. Terminal applications can
also change the live state with DEC private mode 1243.

For the full bidirectional text support — presentation modes, escape
sequences, and the rendering pipeline — see <doc:BiDi>.

Key options:

| Property | Default | Description |
|----------|---------|-------------|
| `cols` / `rows` | 80 / 25 | Initial terminal dimensions |
| `scrollback` | 500 | Number of lines in the scrollback buffer |
| `tabStopWidth` | 8 | Tab stop interval |
| `termName` | `"xterm-256color"` | Value reported for `TERM` |
| `cursorStyle` | `.blinkBlock` | Initial cursor appearance |
| `screenReaderMode` | `false` | Accessibility mode |
| `enableSixelReported` | `true` | Advertise Sixel support to applications |
| `initialBidiState` | implicit, autodetect, LTR | BiDi state for new paragraphs after startup or reset |
| `maximumBidiParagraphRows` | `120` | Maximum rows processed as one BiDi paragraph |
| `initialBidiArrowKeySwap` | `false` | Initial state for BiDi left/right arrow swapping |
| `kittyGraphics` | 10 MB per screen, direct media only | Kitty storage and local-media policy |
| `ansi256PaletteStrategy` | `.base16Lab` | 256-color palette generation strategy |

The `.base16Lab` and `.base16LabHarmonious` strategies are based on the
palette-generation write-up by
[Jake Stewart](https://gist.github.com/jake-stewart/0a8ea46159a7da2c808e5be2177e1783).

Use `.base16Lab` to keep the generated cube and grayscale ramp ordered dark to
light even on light themes. Use `.base16LabHarmonious` to preserve the theme's
native background-to-foreground direction instead.

## Rendering Options

The view supports a few additional rendering flags:

```swift
// Use SwiftTerm's built-in box-drawing and block-element glyphs
// instead of the font's glyphs (often more accurate)
terminalView.customBlockGlyphs = true
terminalView.antiAliasCustomBlockGlyphs = true

// Use bright colors for bold text (traditional terminal behavior)
terminalView.useBrightColors = true

// Keep explicit bright/256-color foreground indexes without promoting bold
// text to a bright color. Both properties default to true for compatibility.
terminalView.useBrightColors = false
terminalView.collapseBrightColorsToBase = false

// Darken or lighten text that falls below a WCAG contrast ratio against
// its background, such as colors a program picked for a dark theme shown
// on a light one. 1, the default, keeps every color as it is.
terminalView.minimumContrastRatio = 4.5
```

### GPU-Accelerated Rendering

On macOS, iOS, and visionOS, you can switch to a Metal-based rendering path
that offloads drawing to the GPU. See <doc:GPURendering> for full details.

```swift
// Enable Metal rendering
try terminalView.setUseMetal(true)

// Choose a buffering strategy
terminalView.metalBufferingMode = .perRowPersistent   // default
terminalView.metalBufferingMode = .perFrameAggregated // for full-screen TUIs

// Check current renderer
if terminalView.isUsingMetalRenderer {
    print("GPU rendering active")
}
```

## Search

On macOS, ``TerminalView`` includes a built-in find bar that integrates with the
standard **Edit > Find** menu (Cmd-F, Next, Previous, and "Use Selection for Find").

If you want to drive search programmatically or supply your own search UI, use the
public helpers on ``TerminalView``:

```swift
terminalView.findNext("term")
terminalView.findPrevious("term", options: SearchOptions(caseSensitive: true))
terminalView.clearSearch()
```

``SearchOptions`` lets you toggle case sensitivity, regex matching, and whole-word
matching.

## Change Notifications

If you need to be notified when specific rows change (for example, to drive a
custom overlay), set `notifyUpdateChanges` to `true` and implement
``TerminalViewDelegate/rangeChanged(source:startY:endY:)``:

```swift
terminalView.notifyUpdateChanges = true
```

## Progress Bar Timeout

The OSC 9;4 progress bar clears itself after 15 seconds without a report, so a
program that dies mid-task does not leave a bar behind. That safety net assumes
reports keep arriving while the work runs: a program that reports once at the
start and once at the end of a long task looks silent in between and loses its
bar halfway through.

``TerminalView/progressReportTimeout`` sets that wait, and `nil` turns it off
for a host that trusts its program to close every bar it opens:

```swift
terminalView.progressReportTimeout = 60   // wait a minute instead
terminalView.progressReportTimeout = nil  // keep the bar until the program removes it
```

Changing it while a bar is on screen restarts the wait from that moment, and
`nil` cancels a wait already running. The default is
``TerminalView/defaultProgressReportTimeout``.
