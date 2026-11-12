#!/usr/bin/env python3
"""Report where the hot SwiftTerm functions are in a SwiftTermProfile binary.

Run it on each binary before an A/B benchmark. When the cycles change but the
instruction count does not, the report tells you if the code layout changed.

Two layout effects are known:

* The start of a hot function in a 64-byte line. Build both sides with
  `-Xswiftc -Xllvm -Xswiftc -align-all-functions=6` to remove this effect.
* A 4 KB alias window. When Terminal.cmdCsiM starts at 3584..4095 (mod 4096),
  dense_cells is 1-4% slower with the same instructions. The cost is
  fetch-redirect stalls (MAP_DISPATCH_BUBBLE and FETCH_RESTART go up; L1I and
  iTLB misses do not), so it is predictor aliasing, not cache capacity. The
  same offset 4 KB and 16 KB higher is slow too. Measured 2026-11-12 on an M3
  Ultra with padding builds: slow at 3584, 3776, 4032; not slow at 3520, 3264,
  192 and the other offsets. 0..191 was not measured. The alias partner is not
  known: parseBorrowed (8 KB, it covers every offset) and dispatchWholeCsi did
  not move in the measurement. When they are at other offsets, the report says
  so, and the window is not verified.

Usage:
  ./layout-report.py BINARY            # report one binary
  ./layout-report.py BINARY_A BINARY_B # report both and the differences

The binary must keep its symbols. The script only reports. It does not fail.
"""

import argparse
import subprocess
import sys

# (label, text that the demangled name starts with)
HOT_FUNCTIONS = [
    ("parseBorrowed", "EscapeSequenceParser.parseBorrowed(_:_:)"),
    ("dispatchWholeCsi", "EscapeSequenceParser.dispatchWholeCsi("),
    ("simpleCsiLength", "static EscapeSequenceParser.simpleCsiLength("),
    ("dispatchExecute", "EscapeSequenceParser.dispatchExecute("),
    ("cmdCsiM", "Terminal.cmdCsiM("),
    ("cmdCharAttributes", "Terminal.cmdCharAttributes("),
    ("handlePrintBorrowed", "Terminal.handlePrintBorrowed("),
    ("cmdLineFeedBasic", "Terminal.cmdLineFeedBasic("),
    ("insertAsciiRun", "Buffer.insertAsciiRun("),
    ("setPackedAsciiRun", "BufferLine.setPackedAsciiRun("),
    ("recycle", "BufferLine.recycle("),
]

ALIAS_SUBJECT = "cmdCsiM"
ALIAS_SLOW = (3584, 4096)        # measured slow, cmdCsiM offset mod 4096
ALIAS_UNKNOWN = (0, 192)         # not measured
# Offsets mod 4096 of the functions that did not move in the measurement.
ALIAS_MEASURED_WITH = {"parseBorrowed": 64, "dispatchWholeCsi": 2496}


def text_symbols(binary):
    """Return [(address, size, demangled name)] for the text symbols, in address order."""
    nm = subprocess.run(["nm", "-n", binary], capture_output=True, text=True)
    if nm.returncode != 0:
        sys.exit(f"error: nm failed for {binary}: {nm.stderr.strip()}")
    rows = []
    for line in nm.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1] in ("T", "t"):
            rows.append((int(parts[0], 16), parts[2]))
    if not rows:
        sys.exit(f"error: {binary} has no text symbols (stripped?)")
    demangled = subprocess.run(
        ["xcrun", "swift-demangle", "--simplified"],
        input="\n".join(name for _, name in rows) + "\n",
        capture_output=True, text=True).stdout.splitlines()
    symbols = []
    for index, (address, _) in enumerate(rows):
        following = rows[index + 1][0] if index + 1 < len(rows) else address
        symbols.append((address, following - address, demangled[index]))
    return symbols


def hot_layout(binary):
    symbols = text_symbols(binary)
    layout = {}
    for label, prefix in HOT_FUNCTIONS:
        for address, size, name in symbols:
            if name.startswith(prefix):
                layout[label] = (address, size)
                break
    return layout


def alias_report(layout):
    if ALIAS_SUBJECT not in layout:
        return "alias window: cannot check (cmdCsiM is missing or inlined)", None
    offset = layout[ALIAS_SUBJECT][0] % 4096
    if ALIAS_SLOW[0] <= offset < ALIAS_SLOW[1]:
        verdict = "IN THE SLOW WINDOW (expect dense_cells +1..4% cycles)"
    elif ALIAS_UNKNOWN[0] <= offset < ALIAS_UNKNOWN[1]:
        verdict = "near the window edge (not measured)"
    else:
        verdict = "outside the window"
    moved = [f"{label} at {layout[label][0] % 4096} (measured at {expected})"
             for label, expected in ALIAS_MEASURED_WITH.items()
             if label in layout and layout[label][0] % 4096 != expected]
    note = ""
    if moved:
        note = "\n    note: not verified, these moved: " + ", ".join(moved)
    return (f"alias window: {ALIAS_SUBJECT} at {offset} mod 4096, slow window "
            f"{ALIAS_SLOW[0]}..{ALIAS_SLOW[1] - 1}: {verdict}{note}"), offset


def alignment_report(layout):
    misaligned = [label for label, (address, _) in layout.items() if address % 64]
    if not misaligned:
        return "alignment: all hot functions start on 64 bytes (aligned build)"
    return ("alignment: NOT an aligned build; these start inside a 64-byte line: "
            + ", ".join(f"{label} ({layout[label][0] % 64})" for label in misaligned))


def print_single(binary, layout):
    print(binary)
    print(f"  {'function':<20}{'address':>14}{'size':>8}{'mod64':>7}{'mod4096':>9}")
    for label, _ in HOT_FUNCTIONS:
        if label in layout:
            address, size = layout[label]
            print(f"  {label:<20}{address:>14x}{size:>8}{address % 64:>7}{address % 4096:>9}")
        else:
            print(f"  {label:<20}{'(inlined or missing)':>38}")
    print("  " + alignment_report(layout))
    print("  " + alias_report(layout)[0])


def print_compare(layout_a, layout_b):
    print("differences (B - A)")
    print(f"  {'function':<20}{'moved':>8}{'size':>8}{'mod4096 A':>11}{'mod4096 B':>11}")
    for label, _ in HOT_FUNCTIONS:
        if label not in layout_a or label not in layout_b:
            continue
        address_a, size_a = layout_a[label]
        address_b, size_b = layout_b[label]
        moved = address_b - address_a
        size = size_b - size_a
        if moved or size:
            print(f"  {label:<20}{moved:>+8}{size:>+8}{address_a % 4096:>11}{address_b % 4096:>11}")
    in_a = alias_report(layout_a)[0].find("IN THE SLOW") >= 0
    in_b = alias_report(layout_b)[0].find("IN THE SLOW") >= 0
    if in_a != in_b:
        print(f"  alias window: only {'A' if in_a else 'B'} is in the slow window; "
              "a dense_cells cycles delta with flat instructions is probably layout")


def main():
    parser = argparse.ArgumentParser(
        description="Report the code layout of hot SwiftTerm functions in a SwiftTermProfile binary.")
    parser.add_argument("binaries", nargs="+", metavar="BINARY")
    options = parser.parse_args()
    if len(options.binaries) > 2:
        parser.error("give one or two binaries")

    layouts = [hot_layout(binary) for binary in options.binaries]
    for index, (binary, layout) in enumerate(zip(options.binaries, layouts)):
        if len(layouts) == 2:
            print("AB"[index] + ": ", end="")
        print_single(binary, layout)
        print()
    if len(layouts) == 2:
        print_compare(*layouts)


if __name__ == "__main__":
    main()
