# GPU-Accelerated Rendering

Use Metal to render the terminal with hardware-accelerated graphics.

## Overview

SwiftTerm includes an optional Metal-based rendering path that replaces the
default CoreGraphics renderer. The GPU renderer rasterizes glyphs into a
texture atlas and draws each terminal cell as a GPU quad, offloading the bulk
of the rendering work to the GPU. This can significantly reduce CPU usage,
especially for large terminals or applications that update the screen rapidly.

Metal rendering is available on macOS, iOS, and visionOS — any platform where
MetalKit can be imported. It is **disabled by default**; you opt in
by calling ``TerminalView/setUseMetal(_:)``.

## Enabling Metal Rendering

Call ``TerminalView/setUseMetal(_:)`` after the view has been added to a
window. The method throws a ``MetalError`` if the GPU pipeline cannot be
created (for example, on hardware without Metal support):

```swift
do {
    try terminalView.setUseMetal(true)
} catch {
    print("Metal not available: \(error)")
    // The view continues using CoreGraphics — no action needed.
}
```

You can switch back to the CoreGraphics renderer at any time:

```swift
try terminalView.setUseMetal(false)
```

Check the current rendering path with
``TerminalView/isUsingMetalRenderer``:

```swift
if terminalView.isUsingMetalRenderer {
    print("Using Metal")
}
```

## Buffering Mode

The ``TerminalView/metalBufferingMode`` property controls how the renderer
builds and caches GPU buffers each frame:

| Mode | Behavior | Best for |
|------|----------|----------|
| ``MetalBufferingMode/perRowPersistent`` (default) | Caches vertex data per row; only dirty rows are rebuilt each frame. | Interactive shells, editors, and typical terminal use. |
| ``MetalBufferingMode/perFrameAggregated`` | Rebuilds all visible rows into a single buffer every frame. | Full-screen TUI apps that repaint most of the screen each frame. |

Change the mode at any time — the renderer picks it up on the next frame:

```swift
terminalView.metalBufferingMode = .perFrameAggregated
```

## Text Blending

The ``TerminalView/metalTextBlending`` property controls how the renderer
blends the coverage of monochrome glyphs with the color behind them. Color
glyphs such as emoji are not affected.

| Mode | Behavior | Best for |
|------|----------|----------|
| ``MetalTextBlending/native`` (default) | Blends glyph coverage directly in sRGB space, as Core Graphics does. | Matching the weight of text in other macOS and iOS apps. |
| ``MetalTextBlending/linearCorrected`` | Applies a gamma-corrected coverage curve chosen by the brightness of the text color. | Keeping antialiased strokes at a similar optical weight in light and dark themes. |

Change the mode at any time; the renderer picks it up on the next frame
without rebuilding its glyph caches:

```swift
terminalView.metalTextBlending = .linearCorrected
```

`TerminalRenderView` has the same property. The Core Graphics renderer
ignores it.

## Font Smoothing

On macOS, ``TerminalView/fontSmoothing`` (on by default) lets Core Graphics
thicken glyph stems the way other macOS apps do. Set it to `false` for
thinner strokes on Retina displays.

Core Graphics thickens light text on a dark background more than dark text on
a light one. The Metal renderer follows this per cell: it compares each
cell's text color with the background the text is drawn on (the selection
color, an explicit cell background, the cursor, or the terminal background)
and rasterizes the glyph for that polarity. Dark text in a light theme
therefore keeps its normal weight, while a selection, an inverse-video status
bar, or the block cursor in the same window still get the heavier
light-on-dark form. Both forms of a glyph stay in the atlas, so reverse video
and a visual bell do not flush it.

Changing `fontSmoothing` takes effect on the next frame and rebuilds the
glyph atlas once.

## Environment Variables

The following environment variable can be used to tune Metal behavior:

| Variable | Values | Description |
|----------|--------|-------------|
| `SWIFTTERM_METAL_LIVE_RESIZE_THROTTLE` | `0` or `false` to disable | On macOS, Metal redraws are throttled during live window resizing for smoother interaction. Set this variable to disable throttling if you prefer immediate redraws during resize. |

## Error Handling

``MetalError`` describes the specific reason Metal initialization failed.
Common cases include:

- ``MetalError/deviceUnavailable`` — No Metal-capable GPU was found (for
  example, running in a VM or on very old hardware).
- ``MetalError/shaderCompilationFailed(_:)`` — The Metal shader source could
  not be compiled. This typically indicates a build-configuration issue.

A full list of cases is available in the ``MetalError`` documentation.

## Supported Features

The Metal renderer supports the full set of terminal rendering features:

- All text attributes (bold, italic, underline, strikethrough, dim/faint,
  inverse, blink)
- Underline styles: single, double, curly, dotted, dashed
- ANSI, 256-color, and TrueColor
- Cursor rendering and blinking
- Selection highlighting
- Inline images (Sixel, iTerm2, Kitty graphics protocol)
- Custom block-element and box-drawing glyphs
- Emoji and color glyph rendering (via a split grayscale/color atlas)

## Architecture Notes

Internally, the Metal renderer uses a **cell-buffer model** inspired by
Ghostty: backgrounds, text glyphs, and decorations are emitted as per-cell
structs on the CPU and expanded to quads in the GPU. A **glyph atlas** backed
by CoreText rasterization caches rendered glyphs across frames, with automatic
eviction when the atlas reaches its size limit. Two atlas textures are
maintained — one grayscale for regular text and one BGRA for color glyphs
(emoji).

## Topics

### Enabling GPU Rendering

- ``TerminalView/setUseMetal(_:)``
- ``TerminalView/isUsingMetalRenderer``

### Configuration

- ``TerminalView/metalBufferingMode``
- ``MetalBufferingMode``
- ``TerminalView/metalTextBlending``
- ``MetalTextBlending``

### Error Handling

- ``MetalError``
