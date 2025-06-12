# Metal Terminal Renderer

SwiftTerm now includes an optional Metal-based renderer that provides 
high-performance terminal text rendering as an alternative to the default C
ore Graphics renderer.

By default, it will use the best system available, but it can fall down
to using CoreGraphics if Metal does not work.

The code is loosely based on the GPU-accelerated version found in Microsoft's
Terminal accelerator.

Setting the Renderer Type

You can configure the renderer type on any `TerminalView` instance:

```swift
// Use Metal renderer (falls back to Core Graphics if Metal unavailable)
terminalView.rendererType = .metal

// Use Core Graphics renderer (default behavior)
terminalView.rendererType = .coreGraphics

// Automatic selection (Metal if available, otherwise Core Graphics)
terminalView.rendererType = .auto  // This is the default
```

The Metal renderer includes:

- Custom vertex and fragment shaders for text and background rendering
- Glyph atlas management for font rendering
- GPU-optimized pipeline for large terminal buffers
- Support for text attributes (bold, italic, underline, colors)
- Selection highlighting and cursor rendering

