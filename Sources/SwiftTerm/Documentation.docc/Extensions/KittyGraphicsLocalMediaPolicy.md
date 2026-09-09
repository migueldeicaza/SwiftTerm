# ``KittyGraphicsConfiguration/LocalMediaPolicy``

Local Kitty transmission media that a terminal accepts.

## Overview

The empty policy is the secure default. Direct payloads continue to work with
the empty policy. Add a local medium only when the terminal session needs it.

For the file-system effects and security considerations of each medium, see
<doc:KittyGraphicsIntegration>.

## Topics

### Create a Policy

- ``init(rawValue:)``
- ``rawValue``

### Permit Local Media

- ``regularFiles``
- ``temporaryFiles``
- ``sharedMemory``
- ``all``
