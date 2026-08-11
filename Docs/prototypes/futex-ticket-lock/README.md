# TerminalLock alternatives: prototypes and measurements

Reference material for `io-gaps.md` section G3. **Nothing here is part of the
package build** — `Package.swift` does not reference this directory. It is kept
so that a future revisit of `TerminalLock` is a lookup and not a new
investigation.

Outcome: **no change to `TerminalLock`**. The current `NSCondition` ticket lock
won. Details and the reasoning are in `io-gaps.md` G3, G3.1 and G3.2.

## `noshim.swift` — the pure-Swift alternative (G3.2)

Compares the current `NSCondition` ticket lock with a targeted-wake ticket lock
built on `DispatchSemaphore`, which needs no C code.

    swiftc -O -o noshim noshim.swift && ./noshim

Measured on an M-series machine: the semaphore version is about 7 ns per
acquisition **slower**, with contended figures inside the noise band. Rejected.

## `shim.c` / `shim.h` / `main.swift` — the futex approach (G3.1)

A ticket lock over `os_sync_wait_on_address`, which is what Ghostty's fairness
handoff uses (through Zig's `std.Thread.Futex`).

    swiftc -O -o probe main.swift shim.c \
        -Xcc -fmodule-map-file=module.modulemap -import-objc-header shim.h
    ./probe

Findings:

- `os_sync_wait_on_address` is **public** API (`__API_AVAILABLE(macos(14.4),
  ios(17.4), ...)`) but is **not** in `os.modulemap`, so Swift cannot see it.
  A C shim is mandatory, which is why this approach is deferred.
- The shim compiles at a macOS 11 deployment floor using `__builtin_available`
  plus a weak-import null check.
- Measured 18.2 ns per uncontended acquisition versus 27.8 ns for the current
  lock in the same run — real, but worth about 9 microseconds per second at
  SwiftTerm's acquisition rate.
- **Trap**: the first version called `os_sync_wake_by_address_all`
  unconditionally in `unlock`, making every release a syscall. That measured
  128.5 ns per acquire, five times worse than the current lock. Gating the wake
  on an atomic waiter count is what makes this design work at all.

## Reading the numbers

Absolute figures drift between runs on the same machine (the current lock
measured 27.8, 30.7 and 35.5 ns across three runs). Only compare values
produced inside a single run.
