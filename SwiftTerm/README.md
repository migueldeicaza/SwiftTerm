# SwiftTerm

The SwiftTerm library itself - this contains the source code for both
the engine and the front-ends.  The front-ends are conditionally
compiled based on the target platform.

The engine is in this directory, while code for macOS lives under `Mac`, and
code for iOS, lives under `iOS`.    Given that those two share a lot of common 
traits, the shared code is under `Apple`.

