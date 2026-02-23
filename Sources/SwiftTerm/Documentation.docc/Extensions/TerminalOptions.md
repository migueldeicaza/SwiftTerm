# ``TerminalOptions``

Configuration options for the terminal engine.

## Overview

`TerminalOptions` controls the initial dimensions, scrollback size, cursor style,
and feature flags for a ``Terminal`` instance. Pass an options struct when
constructing a terminal or a ``HeadlessTerminal``.

Use ``TerminalOptions/default`` for sensible defaults (80x25, 500-line scrollback,
blinking block cursor).

For a guide on customization, see <doc:Customization>.

## Topics

### Getting Default Options

- ``default``

### Terminal Dimensions

- ``cols``
- ``rows``

### Scrollback

- ``scrollback``

### Appearance

- ``cursorStyle``
- ``tabStopWidth``

### Terminal Identity

- ``termName``

### Behavior

- ``convertEol``
- ``screenReaderMode``

### Graphics

- ``enableSixelReported``
- ``kittyImageCacheLimitBytes``

### Colors

- ``ansi256PaletteStrategy``
