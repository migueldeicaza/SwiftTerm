# Integrating Kitty Graphics

Configure Kitty graphics and add Kitty image support to a custom renderer.

## Overview

SwiftTerm parses Kitty graphics commands in the terminal core. It decodes image
data, manages image storage, resolves placements, and advances animations. The
bundled AppKit and UIKit views render this state automatically.

A custom host uses two main API entry points:

- Set ``TerminalOptions/kittyGraphics`` before you create the terminal.
- Call ``Terminal/kittyGraphicsRenderSnapshot()`` to get renderer input.

For wire protocol behavior, see <doc:KittyGraphicsProtocol>.

## Configure the protocol

``KittyGraphicsConfiguration`` sets the decoded image limit and the local media
policy. The default configuration stores at most 10,000,000 decoded bytes on
each screen. The primary screen and the alternate screen have separate limits.
A value of zero disables all Kitty graphics operations and query responses.

This example uses the default direct-payload policy:

```swift
var options = TerminalOptions.default
options.kittyGraphics = KittyGraphicsConfiguration(
    storageLimitBytesPerScreen: 20_000_000
)

let terminal = Terminal(delegate: delegate, options: options)
```

Direct payloads do not need an entry in
``KittyGraphicsConfiguration/LocalMediaPolicy``. Keep the policy empty for a
remote or untrusted session.

### Local media security

Local media commands make SwiftTerm read data from the host system. Enable only
the media that the session needs:

- ``KittyGraphicsConfiguration/LocalMediaPolicy/regularFiles`` lets the client
  name a regular file that the host can read.
- ``KittyGraphicsConfiguration/LocalMediaPolicy/temporaryFiles`` accepts files
  only in ``KittyGraphicsConfiguration/trustedTemporaryDirectory``. The base
  name must start with `tty-graphics-protocol`.
- ``KittyGraphicsConfiguration/LocalMediaPolicy/sharedMemory`` lets the client
  name a POSIX shared-memory object.

SwiftTerm removes an accepted temporary file or shared-memory object after it
reads the object. Do not use an object that another part of the host must keep.
Do not use a broad directory as the trusted temporary directory. Use a directory
that the host controls for this terminal integration.

## Take a render snapshot

All direct terminal access must use ``Terminal/terminalLock``. Take the Kitty
snapshot in the same locked operation as the related terminal cells. Release
the lock before you create textures or draw a frame.

```swift
let kittySnapshot = terminal.terminalLock.withLock {
    terminal.kittyGraphicsRenderSnapshot()
}

renderer.draw(kittySnapshot)
```

``KittyGraphicsRenderSnapshot`` and its values are immutable and `Sendable`.
You can give the snapshot to a render thread after you release the terminal
lock. The snapshot contains state for the active screen only.

The snapshot shares immutable pixel array storage with the terminal. This
prevents a full pixel copy for each frame. A snapshot keeps its pixel arrays
alive, also after the terminal removes an image. Do not keep old snapshots for
long periods. Long retention can make memory use larger than the configured
storage limit.

## Render images and placements

``KittyGraphicsRenderSnapshot/imagesById`` contains all stored images for the
active screen. ``KittyGraphicsRenderSnapshot/placements`` is in ascending
z-index and insertion order. For each non-virtual placement, get its image from
``KittyGraphicsRenderPlacement/imageId``.

``KittyGraphicsRenderImage/rgba`` uses row-major, top-row-first, straight-alpha
RGBA8 data. Some graphics APIs require premultiplied alpha or a bottom-left
texture origin. Convert the data when your graphics API requires it. Cache a
decoded texture with both ``KittyGraphicsRenderImage/imageId`` and
``KittyGraphicsRenderImage/contentGeneration``. An application can replace an
image and keep the same image ID. An animation also changes the content
generation when its visible frame changes.

Use ``KittyGraphicsRenderPlacement/visibleSource`` as the source pixel crop.
Use ``KittyGraphicsRenderPlacement/geometry`` as the destination in terminal
cells. The row is relative to the current viewport and can be outside that
viewport. Clip the destination to the viewport. The pixel offsets are protocol
pixel values, not cell counts. Convert them once to the coordinate units of your
renderer.

Use three drawing passes and keep snapshot order in each pass:

1. Draw a placement with `zIndex < Int32.min / 2` before cell backgrounds.
2. Draw another negative z-index placement after cell backgrounds and before
   text.
3. Draw a placement with `zIndex >= 0` after text.

Do not draw a placement when
``KittyGraphicsRenderPlacement/isVirtual`` is `true`. A virtual placement is a
source for Unicode placeholder cells. Interpret the U+10EEEE cells and their
color and diacritic metadata as specified in <doc:KittyGraphicsProtocol>.

### Cache invalidation

Use ``KittyGraphicsRenderSnapshot/storageGeneration`` to detect a change to
images or placements. Use ``KittyGraphicsRenderPlacement/token`` as the stable
identity of a placement. Client placement ID zero is anonymous, but it still
has a unique token. A crop cache can use the placement token, the image content
generation, and the visible source rectangle as one key.

The public initializers for the snapshot value types do not validate their
arguments. ``Terminal/kittyGraphicsRenderSnapshot()`` returns valid dimensions,
pixel counts, crops, and placement sizes. If you construct these values, verify
the same conditions before you render them.

## Advance animations

SwiftTerm schedules Kitty animations automatically. A normal host must not add
a second animation timer.

``Terminal/kittyGraphicsAdvanceAnimations(monotonicNanoseconds:)`` is available
for deterministic tests and integrations that intentionally supply a monotonic
clock. This method changes terminal state. Call it while you hold
``Terminal/terminalLock``. Use one clock epoch for all calls. The return value is
the next deadline in that epoch, or `nil` when no animation needs a timer.

## Topics

### Configuration

- ``TerminalOptions/kittyGraphics``
- ``KittyGraphicsConfiguration``
- ``KittyGraphicsConfiguration/LocalMediaPolicy``

### Snapshot Access

- ``Terminal/terminalLock``
- ``Terminal/kittyGraphicsRenderSnapshot()``
- ``Terminal/kittyGraphicsAdvanceAnimations(monotonicNanoseconds:)``

### Renderer Values

- ``KittyGraphicsRenderSnapshot``
- ``KittyGraphicsRenderImage``
- ``KittyGraphicsRenderPlacement``
- ``KittyGraphicsPixelRect``
- ``KittyGraphicsCellGeometry``

### Protocol Details

- <doc:KittyGraphicsProtocol>
- <doc:KittyGraphicsParityMatrix>
