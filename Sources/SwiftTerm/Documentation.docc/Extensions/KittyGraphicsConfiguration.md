# ``KittyGraphicsConfiguration``

Configuration for Kitty graphics storage and local media.

## Overview

Set this value in ``TerminalOptions/kittyGraphics`` before you create a
terminal. The default accepts direct payloads only and has a 10,000,000-byte
limit for each terminal screen.

Keep local media disabled for remote and untrusted sessions. For policy and
security considerations, see <doc:KittyGraphicsIntegration>.

## Topics

### Create a Configuration

- ``init(storageLimitBytesPerScreen:localMediaPolicy:trustedTemporaryDirectory:)``

### Storage

- ``storageLimitBytesPerScreen``

### Local Media

- ``localMediaPolicy``
- ``trustedTemporaryDirectory``
- ``LocalMediaPolicy``
