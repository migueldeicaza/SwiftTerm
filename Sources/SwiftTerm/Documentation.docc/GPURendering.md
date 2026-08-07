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

### Error Handling

- ``MetalError``
