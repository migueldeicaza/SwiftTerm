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

To install a custom 256-color palette, use ``Terminal/installPalette(colors:)``.
The array must contain exactly 256 ``Color`` values — the first 16 are the
standard ANSI colors, 16-231 are the 6x6x6 color cube, and 232-255 are the
greyscale ramp:

```swift
let terminal = terminalView.getTerminal()
terminal.installPalette(colors: myCustomPalette)
```

### Selection and Cursor Colors

```swift
terminalView.selectedTextBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.3)
terminalView.caretColor = NSColor.systemGreen
terminalView.caretTextColor = NSColor.black  // optional: text color under cursor
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

On iOS with an external keyboard, the same property is available. The iOS view
also supports toggling it at runtime with Option-Command-O.

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
    termName: "xterm-256color"
)
```

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
| `kittyImageCacheLimitBytes` | 320 MB | Memory limit for Kitty image cache |

## Rendering Options

The view supports a few additional rendering flags:

```swift
// Use SwiftTerm's built-in box-drawing and block-element glyphs
// instead of the font's glyphs (often more accurate)
terminalView.customBlockGlyphs = true
terminalView.antiAliasCustomBlockGlyphs = true

// Use bright colors for bold text (traditional terminal behavior)
terminalView.useBrightColors = true
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
