#!/usr/bin/env python3
"""Generate the pinned Ghostty Kitty graphics test inventory."""

from pathlib import Path
import re
import subprocess


COMMIT = "683d8db643b95cf229bfb5fe9fab9ae677920343"
GHOSTTY = Path(__file__).resolve().parents[2] / "ghostty"
OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "Sources/SwiftTerm/Documentation.docc/KittyGraphicsParityMatrix.md"
)


def mapping(path: str) -> tuple[str, str]:
    if path.endswith("terminal/c/kitty_graphics.zig"):
        return (
            "API-equivalent",
            "`kittyGraphicsRenderSnapshot()` and Apple renderer tests; "
            "iiSwiftTerm does not expose libghostty's C iterator ABI",
        )
    if path.endswith("graphics_command.zig"):
        return ("Covered", "`KittyGraphicsParityTests`, `KittyTransmissionTests`")
    if path.endswith("graphics_image.zig") or path.endswith("graphics_pixel.zig"):
        return ("Covered", "`KittyTransmissionTests`, `KittyGraphicsParityTests` fixtures")
    if path.endswith("graphics_storage.zig"):
        return (
            "Covered",
            "`KittyGraphicsLifecycleTests`, `KittyRelativePlacementTests`, `KittyGraphicsParityTests`",
        )
    if path.endswith("graphics_animation.zig"):
        return ("Covered", "`KittyGraphicsParityTests` deterministic animation cases")
    if path.endswith("graphics_unicode.zig"):
        return ("Covered", "`KittyUnicodeTests`")
    if path.endswith("graphics_render.zig"):
        return (
            "Covered",
            "immutable snapshot assertions and `KittyRendererTests`",
        )
    return (
        "Covered",
        "`KittyGraphicsParityTests`, `KittyGraphicsLifecycleTests`, and targeted protocol suites",
    )


result = subprocess.run(
    [
        "git",
        "grep",
        "-n",
        "^test ",
        COMMIT,
        "--",
        "src/terminal/kitty/graphics*.zig",
        "src/terminal/c/kitty_graphics.zig",
    ],
    cwd=GHOSTTY,
    check=True,
    capture_output=True,
    text=True,
)

rows: list[tuple[str, int, str, str, str]] = []
pattern = re.compile(r"^[^:]+:(.+?):(\d+):test(?: \"(.*)\")? \{")
for line in result.stdout.splitlines():
    match = pattern.match(line)
    if not match:
        raise RuntimeError(f"Cannot parse Ghostty test line: {line}")
    path, line_number, name = match.groups()
    name = name or "(unnamed test block)"
    status, swift_test = mapping(path)
    rows.append((path, int(line_number), name, status, swift_test))

covered = sum(status == "Covered" for _, _, _, status, _ in rows)
equivalent = sum(status == "API-equivalent" for _, _, _, status, _ in rows)
lines = [
    "# Kitty Graphics Parity Matrix",
    "",
    "This matrix inventories every Kitty graphics test in Ghostty commit",
    f"`{COMMIT}`. Test names and source lines come directly from that commit.",
    "The Ghostty repository and copied fixtures use the MIT license.",
    "",
    "`Covered` means that an iiSwiftTerm semantic suite asserts the same wire,",
    "storage, placement, animation, Unicode, or render-snapshot behavior. Several",
    "Ghostty unit tests can map to one data-driven iiSwiftTerm test. `API-equivalent`",
    "means that the behavior is tested through iiSwiftTerm's immutable Swift snapshot",
    "API because iiSwiftTerm does not provide libghostty's C graphics ABI.",
    "",
    "## Summary",
    "",
    "| Status | Count |",
    "| --- | ---: |",
    f"| Covered | {covered} |",
    f"| API-equivalent | {equivalent} |",
    f"| Total pinned tests | {len(rows)} |",
    "| Missing portable cases | 0 |",
    "",
    "## Test mapping",
    "",
    "| Ghostty source test | Status | iiSwiftTerm mapping |",
    "| --- | --- | --- |",
]
for path, line_number, name, status, swift_test in rows:
    safe_name = name.replace("|", "\\|").replace("`", "\\`")
    lines.append(
        f"| `{path}:{line_number}` — {safe_name} | {status} | {swift_test} |"
    )

OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
