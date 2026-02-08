# Graphics Support

Display inline images in the terminal using Sixel, iTerm2, or Kitty protocols.

## Overview

SwiftTerm supports three inline graphics protocols, allowing terminal applications
to display images directly in the terminal output. Each protocol has different
capabilities and trade-offs.

## Sixel

[Sixel](https://en.wikipedia.org/wiki/Sixel) is the oldest inline graphics
protocol, dating back to DEC terminals. It encodes images as a sequence of
six-pixel-tall rows using a compact text encoding.

SwiftTerm parses Sixel data via `SixelDcsHandler` and renders the result using
the ``TerminalDelegate/createImageFromBitmap(source:bytes:width:height:)``
callback. The bitmap is decoded from the Sixel stream and delivered to the
front-end as raw RGBA pixel data.

### Testing Sixel

Use `img2sixel` from the [libsixel](https://github.com/saitoha/libsixel) package:

```bash
img2sixel image.png
```

### Configuration

Sixel support is advertised to querying applications when
``TerminalOptions/enableSixelReported`` is `true` (the default). Set it to `false`
if you want to hide Sixel support from applications.

## iTerm2 Inline Images

iTerm2's [inline image protocol](https://iterm2.com/documentation-images.html)
uses OSC 1337 to transmit Base64-encoded image data. It supports specifying
display dimensions and preserving aspect ratio.

SwiftTerm handles this via the ``TerminalDelegate/createImage(source:data:width:height:preserveAspectRatio:)``
delegate callback. The image data (PNG, JPEG, GIF, etc.) is delivered as `Data`
along with size requests.

### Testing iTerm2 Images

Use the `imgcat` script available from iTerm2:

```bash
imgcat image.png
```

### Size Requests

Both iTerm2 and Kitty images use ``ImageSizeRequest`` to specify dimensions:

- `.auto` — Use the image's native size
- `.cells(n)` — Size in terminal cell units
- `.pixels(n)` — Exact pixel size
- `.percent(n)` — Percentage of the terminal area

## Kitty Graphics Protocol

The [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
is the most capable of the three. It supports:

- Transmitting images in chunks (for large images)
- Referencing previously transmitted images by ID
- Placing images at arbitrary positions with z-ordering
- Virtual placements and Unicode placeholders
- Sub-image display (cropping regions of a stored image)

SwiftTerm implements the Kitty graphics protocol including image storage,
placement management, and Unicode placeholder rendering.

### Testing Kitty Graphics

Use the `kitten icat` command from [Kitty](https://sw.kovidgoyal.net/kitty/):

```bash
kitten icat image.png
```

Or use [timg](https://github.com/hzeller/timg) with Kitty output:

```bash
timg -pk image.png
```

### Cache Limits

Kitty images are cached in memory for re-display. Control the cache size with
``TerminalOptions/kittyImageCacheLimitBytes``, which defaults to 320 MB.

## Implementing Graphics in a Custom Front-End

If you are building a custom front-end (not using the bundled AppKit/UIKit views),
implement these ``TerminalDelegate`` methods to handle graphics:

- ``TerminalDelegate/createImageFromBitmap(source:bytes:width:height:)`` —
  Called for Sixel images. Receives raw RGBA pixel data. Return a
  ``TerminalImage`` conforming object.

- ``TerminalDelegate/createImage(source:data:width:height:preserveAspectRatio:)`` —
  Called for iTerm2 and Kitty images. Receives encoded image data (PNG, etc.)
  with sizing instructions.

The bundled AppKit and UIKit views implement both of these automatically and
handle slicing images across terminal rows for rendering.
