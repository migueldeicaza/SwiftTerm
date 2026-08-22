#!/usr/bin/env python3
"""Generate the terminal-width lookup.

Update procedure:
1. Change UNICODE_VERSION and the source checksums.
2. Run this script to regenerate UnicodeWidthData.swift.
3. Run this script with --check.
4. Run the exhaustive Unicode width parity test.
5. Review all width changes before you commit them.

The default action is the only action that uses the network. The --check action
checks the generated content and generator fingerprints without network access.
"""

import argparse
import hashlib
import ssl
import urllib.error
import urllib.request
from pathlib import Path


UNICODE_VERSION = "17.0.0"
UNICODE_BASE_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd"
MAX_SCALAR = 0x10FFFF
PAGE_BITS = 8
PAGE_SIZE = 1 << PAGE_BITS
PACKED_PAGE_SIZE = PAGE_SIZE // 4

SOURCES = {
    "UnicodeData.txt": (
        f"{UNICODE_BASE_URL}/UnicodeData.txt",
        "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c",
    ),
    "EastAsianWidth.txt": (
        f"{UNICODE_BASE_URL}/EastAsianWidth.txt",
        "ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33",
    ),
    "emoji-variation-sequences.txt": (
        f"{UNICODE_BASE_URL}/emoji/emoji-variation-sequences.txt",
        "bb3d09ef03f206012c7532dd52dc0a21c9efddba0135ea4cf0d9201b8b9bba7e",
    ),
}


def fetch(url):
    try:
        with urllib.request.urlopen(url) as response:
            return response.read()
    except urllib.error.URLError as error:
        # Python.org macOS installs do not always have a configured CA file.
        system_ca_file = Path("/etc/ssl/cert.pem")
        if not isinstance(error.reason, ssl.SSLCertVerificationError) or not system_ca_file.exists():
            raise
        context = ssl.create_default_context(cafile=system_ca_file)
        with urllib.request.urlopen(url, context=context) as response:
            return response.read()


def fetch_sources():
    result = {}
    for name, (url, expected_checksum) in SOURCES.items():
        data = fetch(url)
        actual_checksum = hashlib.sha256(data).hexdigest()
        if actual_checksum != expected_checksum:
            raise RuntimeError(
                f"Checksum mismatch for {name}: expected {expected_checksum}, got {actual_checksum}"
            )
        result[name] = data.decode("utf-8")
    return result


def merge_ranges(ranges):
    ranges = sorted(ranges)
    if not ranges:
        return []
    merged = [list(ranges[0])]
    for lo, hi in ranges[1:]:
        current = merged[-1]
        if lo <= current[1] + 1:
            current[1] = max(current[1], hi)
        else:
            merged.append([lo, hi])
    return [tuple(value) for value in merged]


def parse_unicode_categories(text):
    categories = ["Cn"] * (MAX_SCALAR + 1)
    range_start = None
    range_category = None

    for line in text.splitlines():
        fields = line.split(";")
        if len(fields) < 3:
            continue
        value = int(fields[0], 16)
        name = fields[1]
        category = fields[2]
        if name.endswith(", First>"):
            range_start = value
            range_category = category
        elif name.endswith(", Last>"):
            if range_start is None or range_category != category:
                raise RuntimeError(f"Invalid UnicodeData range at U+{value:04X}")
            categories[range_start : value + 1] = [category] * (value - range_start + 1)
            range_start = None
            range_category = None
        else:
            categories[value] = category

    if range_start is not None:
        raise RuntimeError("Unterminated UnicodeData range")
    return categories


def parse_nonzero_combining_class(text):
    ranges = []
    range_start = None
    range_combining = None

    for line in text.splitlines():
        fields = line.split(";")
        if len(fields) < 4:
            continue
        value = int(fields[0], 16)
        name = fields[1]
        combining = int(fields[3])
        if name.endswith(", First>"):
            range_start = value
            range_combining = combining
        elif name.endswith(", Last>"):
            if range_start is None or range_combining != combining:
                raise RuntimeError(f"Invalid UnicodeData range at U+{value:04X}")
            if combining != 0:
                ranges.append((range_start, value))
            range_start = None
            range_combining = None
        elif combining != 0:
            ranges.append((value, value))

    if range_start is not None:
        raise RuntimeError("Unterminated UnicodeData range")
    return merge_ranges(ranges)


def parse_east_asian_width(text):
    ranges = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        code_range, width = [field.strip() for field in line.split(";", 1)]
        if width not in ("W", "F"):
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
        fields = [field.strip() for field in line.split(";")]
        sequence, style = fields[0], fields[1]
        parts = sequence.split()
        if style == "emoji style" and len(parts) == 2 and int(parts[1], 16) == 0xFE0F:
            bases.append(int(parts[0], 16))
    return merge_ranges((value, value) for value in sorted(set(bases)))


def in_ranges(value, ranges):
    for low, high in ranges:
        if low <= value <= high:
            return True
    return False


def terminal_width(value, categories, east_asian_wide, nonzero_combining):
    if value == 0:
        return 0
    if value < 0x20:
        return -1
    if value < 0x7F:
        return 1
    if value < 0xA0:
        return -1

    category = categories[value]
    # Mn (nonspacing) and Me (enclosing) never occupy a column.
    #
    # Mc — spacing combining mark — does, and this is where the Indic scripts were
    # being lost: Devanagari, Bengali, Tamil, Telugu, Kannada, Malayalam, Odia,
    # Gujarati and Gurmukhi all write their dependent vowel signs as Mc, and giving
    # them zero width makes the glyph overprint its base consonant instead of
    # following it.
    #
    # The exception is an Mc with a nonzero canonical combining class — viramas and
    # the like, which conjoin the surrounding consonants rather than advancing. Those
    # stay zero-width, which also preserves handlePrint's invariant that a scalar with
    # a nonzero combining class is always zero-width.
    if category in ("Mn", "Me"):
        return 0
    if category == "Mc":
        return 0 if in_ranges(value, nonzero_combining) else 1
    if category == "Cf":
        return 1 if value == 0x00AD else 0
    if category in ("Zl", "Zp"):
        return 0
    if category == "Sk":
        if 0x1F3FB <= value <= 0x1F3FF:
            return 0
        if value in (0xFF3E, 0xFF40, 0xFFE3):
            return 2

    if 0x1160 <= value <= 0x11FF or 0xD7B0 <= value <= 0xD7FF:
        return 0
    if 0x1F1E6 <= value <= 0x1F1FF:
        return 2
    if east_asian_wide[value]:
        return 2
    return 1


def make_width_pages(categories, east_asian_ranges, nonzero_combining):
    wide = bytearray(MAX_SCALAR + 1)
    for lo, hi in east_asian_ranges:
        wide[lo : hi + 1] = bytes([1]) * (hi - lo + 1)

    page_indices = []
    pages = []
    known_pages = {}
    for page_start in range(0, MAX_SCALAR + 1, PAGE_SIZE):
        encoded = [
            terminal_width(value, categories, wide, nonzero_combining) + 1
            for value in range(page_start, page_start + PAGE_SIZE)
        ]
        packed = bytes(
            encoded[offset]
            | (encoded[offset + 1] << 2)
            | (encoded[offset + 2] << 4)
            | (encoded[offset + 3] << 6)
            for offset in range(0, PAGE_SIZE, 4)
        )
        page_index = known_pages.get(packed)
        if page_index is None:
            page_index = len(pages)
            if page_index > 0xFF:
                raise RuntimeError("The page index no longer fits in UInt8")
            known_pages[packed] = page_index
            pages.append(packed)
        page_indices.append(page_index)
    return page_indices, b"".join(pages), len(pages)


def append_byte_array(lines, name, values):
    lines.append(f"    static let {name}: [UInt8] = [\n")
    for offset in range(0, len(values), 16):
        chunk = values[offset : offset + 16]
        lines.append("        " + ", ".join(f"0x{value:02X}" for value in chunk) + ",\n")
    lines.append("    ]\n\n")


def append_ranges(lines, name, ranges):
    lines.append(f"    static let {name}: [Range] = [\n")
    for lo, hi in ranges:
        lines.append(f"        Range(lo: 0x{lo:04X}, hi: 0x{hi:04X}),\n")
    lines.append("    ]\n\n")


def parse_spacing_marks(categories, nonzero_combining):
    """Mc that advances the cursor: a spacing combining mark whose canonical
    combining class is zero.

    A grapheme cluster may hold several of these — TAMIL VOWEL SIGN O decomposes to
    two — and the cluster still occupies one column for all of them together, so the
    terminal has to be able to ask whether it has seen one already.
    """
    marks = [
        value
        for value in range(len(categories))
        if categories[value] == "Mc" and not in_ranges(value, nonzero_combining)
    ]
    return merge_ranges((value, value) for value in sorted(marks))


def generate(source_text, generator_checksum):
    categories = parse_unicode_categories(source_text["UnicodeData.txt"])
    combining_ranges = parse_nonzero_combining_class(source_text["UnicodeData.txt"])
    east_asian_ranges = parse_east_asian_width(source_text["EastAsianWidth.txt"])
    emoji_vs16_ranges = parse_emoji_vs16_bases(source_text["emoji-variation-sequences.txt"])
    spacing_mark_ranges = parse_spacing_marks(categories, combining_ranges)
    page_indices, packed_pages, page_count = make_width_pages(
        categories, east_asian_ranges, combining_ranges
    )

    table_bytes = len(page_indices) + len(packed_pages)
    lines = [
        "// This file is generated. Do not edit it by hand.\n",
        f"// Unicode version: {UNICODE_VERSION}\n",
        f"// Generator SHA-256: {generator_checksum}\n",
    ]
    for name, (url, checksum) in SOURCES.items():
        lines.append(f"// Source: {url}\n")
        lines.append(f"// Source SHA-256 ({name}): {checksum}\n")
    lines.extend(
        [
            f"// Width table: {len(page_indices)} page indices, {page_count} unique pages, "
            f"{table_bytes} bytes.\n",
            "struct UnicodeWidthData {\n",
            "    typealias Range = UnicodeUtil.LH\n\n",
            "    private static let pageBits = 8\n",
            "    private static let packedPageBits = 6\n\n",
        ]
    )
    append_byte_array(lines, "widthPageIndices", page_indices)
    append_byte_array(lines, "packedWidthPages", packed_pages)
    append_ranges(lines, "eastAsianWide", east_asian_ranges)
    append_ranges(lines, "emojiVs16Base", emoji_vs16_ranges)
    append_ranges(lines, "nonzeroCombiningClass", combining_ranges)
    append_ranges(lines, "spacingMark", spacing_mark_ranges)
    lines.extend(
        [
            "    @inline(__always)\n",
            "    static func columnWidth (_ value: UInt32) -> Int\n",
            "    {\n",
            "        let scalar = Int (value)\n",
            "        let page = Int (widthPageIndices [scalar >> pageBits])\n",
            "        let packed = packedWidthPages [(page << packedPageBits) | ((scalar & 0xFF) >> 2)]\n",
            "        let shift = UInt8 ((scalar & 3) << 1)\n",
            "        return Int ((packed >> shift) & 3) - 1\n",
            "    }\n",
            "}\n",
        ]
    )
    content = "".join(lines)
    content_checksum = hashlib.sha256(content.encode("utf-8")).hexdigest()
    return content + f"// Generated content SHA-256: {content_checksum}\n"


def check_generated(script_path, output_path):
    if not output_path.exists():
        raise RuntimeError(f"Missing generated file: {output_path}")
    content = output_path.read_text(encoding="utf-8")
    checksum_prefix = "// Generated content SHA-256: "
    body, separator, checksum_line = content.rpartition(checksum_prefix)
    if not separator:
        raise RuntimeError("The generated content checksum is missing")
    expected_content_checksum = checksum_line.strip()
    actual_content_checksum = hashlib.sha256(body.encode("utf-8")).hexdigest()
    if actual_content_checksum != expected_content_checksum:
        raise RuntimeError("UnicodeWidthData.swift was edited after generation")

    generator_checksum = hashlib.sha256(script_path.read_bytes()).hexdigest()
    marker = f"// Generator SHA-256: {generator_checksum}\n"
    if marker not in body:
        raise RuntimeError("UnicodeWidthData.swift is stale; run the generator")
    print(f"Checked {output_path}: generated data is current")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="check the generated file without network access",
    )
    arguments = parser.parse_args()

    script_path = Path(__file__).resolve()
    repo_root = script_path.parents[1]
    output_path = repo_root / "Sources" / "SwiftTerm" / "UnicodeWidthData.swift"
    if arguments.check:
        check_generated(script_path, output_path)
        return

    source_text = fetch_sources()
    generator_checksum = hashlib.sha256(script_path.read_bytes()).hexdigest()
    content = generate(source_text, generator_checksum)
    output_path.write_text(content, encoding="utf-8")
    print(f"Wrote {output_path}")


if __name__ == "__main__":
    main()
