# ``KittyGraphicsRenderSnapshot``

Immutable image and placement data for a Kitty graphics renderer.

## Overview

Get this value from ``Terminal/kittyGraphicsRenderSnapshot()`` while you hold
``Terminal/terminalLock``. You can render the value on another thread after you
release the lock.

For cache keys, layer order, coordinate handling, and lifetime considerations,
see <doc:KittyGraphicsIntegration>.

## Topics

### Create a Snapshot

- ``init(storageGeneration:imagesById:placements:)``

### Read Snapshot State

- ``storageGeneration``
- ``imagesById``
- ``placements``

### Renderer Values

- ``KittyGraphicsRenderImage``
- ``KittyGraphicsRenderPlacement``
- ``KittyGraphicsPixelRect``
- ``KittyGraphicsCellGeometry``
