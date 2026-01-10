#!/usr/bin/env python3
import urllib.request
from pathlib import Path

EAST_ASIAN_WIDTH_URL = "https://www.unicode.org/Public/UCD/latest/ucd/EastAsianWidth.txt"
EMOJI_VARIATION_SEQUENCES_URL = (
    "https://www.unicode.org/Public/UCD/latest/ucd/emoji/emoji-variation-sequences.txt"
)


def fetch(url):
    with urllib.request.urlopen(url) as response:
        return response.read().decode("utf-8")


def merge_ranges(ranges):
    if not ranges:
        return []
    ranges = sorted(ranges)
    merged = [list(ranges[0])]
    for lo, hi in ranges[1:]:
        cur = merged[-1]
        if lo <= cur[1] + 1:
            cur[1] = max(cur[1], hi)
        else:
            merged.append([lo, hi])
    return [tuple(r) for r in merged]


def parse_east_asian_width(text):
    ranges = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [x.strip() for x in line.split(";")]
        if len(fields) < 2:
            continue
        code_range, prop = fields[0], fields[1]
        if prop not in ("W", "F"):
            continue
        if ".." in code_range:
            lo, hi = code_range.split("..")
        else:
            lo = hi = code_range
        ranges.append((int(lo, 16), int(hi, 16)))
    return merge_ranges(ranges)


def parse_emoji_vs16_bases(text):
    bases = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [x.strip() for x in line.split(";")]
        if len(fields) < 2:
            continue
        seq, style = fields[0], fields[1]
        if style != "emoji style":
            continue
        parts = seq.split()
        if len(parts) != 2:
            continue
        base = int(parts[0], 16)
        vs = int(parts[1], 16)
        if vs != 0xFE0F:
            continue
        bases.append(base)
    bases = sorted(set(bases))
    ranges = []
    start = prev = None
    for b in bases:
        if start is None:
            start = prev = b
            continue
        if b == prev + 1:
            prev = b
            continue
        ranges.append((start, prev))
        start = prev = b
    if start is not None:
        ranges.append((start, prev))
    return ranges


def main():
    eaw_ranges = parse_east_asian_width(fetch(EAST_ASIAN_WIDTH_URL))
    evs_ranges = parse_emoji_vs16_bases(fetch(EMOJI_VARIATION_SEQUENCES_URL))

    lines = []
    lines.append("// This file is generated from Unicode data files. Do not edit by hand.\n")
    lines.append("struct UnicodeWidthData {\n")
    lines.append("    typealias Range = UnicodeUtil.LH\n\n")
    lines.append("    static let eastAsianWide: [Range] = [\n")
    for lo, hi in eaw_ranges:
        lines.append(f"        Range(lo: 0x{lo:04X}, hi: 0x{hi:04X}),\n")
    lines.append("    ]\n\n")
    lines.append("    static let emojiVs16Base: [Range] = [\n")
    for lo, hi in evs_ranges:
        lines.append(f"        Range(lo: 0x{lo:04X}, hi: 0x{hi:04X}),\n")
    lines.append("    ]\n")
    lines.append("}\n")

    repo_root = Path(__file__).resolve().parents[1]
    out_path = repo_root / "Sources" / "SwiftTerm" / "UnicodeWidthData.swift"
    out_path.write_text("".join(lines), encoding="utf-8")
    print(f"Wrote {out_path} with {len(eaw_ranges)} EAW ranges and {len(evs_ranges)} VS16 ranges")


if __name__ == "__main__":
    main()
