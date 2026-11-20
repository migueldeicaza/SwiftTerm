# Mouse pointer shapes

Let terminal applications select a native pointer shape with OSC 22.

The core supports setting a shape, an independently bounded 16-entry stack for
each screen, and capability queries using the
[Kitty OSC 22 protocol](https://sw.kovidgoyal.net/kitty/pointer-shapes/).
The implemented shape subset is `default`, `text`, `pointer`, and `crosshair`.
The additional CSS `none` shape hides the pointer. Since `none` is an extension,
applications should query it before use:

```sh
# Query support; an implementing host replies with OSC 22 ; 1 ST.
printf '\033]22;?none\033\\'
# Push a hidden pointer over the application's previous shape.
printf '\033]22;>none\033\\'
# Restore that shape.
printf '\033]22;<\033\\'
```

An empty OSC 22 resets the active screen's stack. RIS clears both stacks.
Pointer shape state is independent of mouse reporting and of the text caret.
Queries for `__current__`, `__default__`, and `__grabbed__` are also supported.
Unknown or unimplemented shapes are ignored when setting and return `0` when
queried. Existing registered OSC 22 handlers retain precedence.

On macOS, `TerminalView` renders all five shapes. The hidden shape uses a shared
transparent `NSCursor` in the view's cursor rect, rather than the process-wide
cursor hide count. Leaving the view restores AppKit's cursor behavior. Holding
Shift to bypass application mouse reporting also restores the selection I-beam.
Shape changes refresh a stationary pointer and are copied through the view's
coalescing event queue; AppKit callbacks do not acquire the terminal lock.

Other hosts opt in through
``TerminalDelegate/supportedMousePointerShapes(source:)`` and apply the copied
``Terminal/mousePointerShape`` from
``TerminalDelegate/mousePointerShapeChanged(source:)`` on their UI thread.
The default implementation advertises no support, so headless and unsupported
hosts never claim to hide a native pointer. The macOS copied state is available
as ``TerminalView/currentMousePointerShape``.
