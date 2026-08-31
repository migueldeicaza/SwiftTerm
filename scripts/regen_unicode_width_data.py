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
# One byte per scalar, holding only what the grapheme pair test in UnicodeUtil
# reads on the hot path. General_Category=Mc and ccc=9 stay out of it: they
# answer a width question that only a completed combination asks, so they ship
# as range tables instead.
#
# Bits 0 to 2 hold one mutually exclusive Grapheme_Cluster_Break class. The
# Hangul classes come first so that `hangul_join_rows` can index them directly;
# Control is last and joins nothing.
HANGUL_CLASSES = ("L", "V", "T", "LV", "LVT")
PROPERTY_CLASS_MASK = 0x07
PROPERTY_CLASS_CONTROL = len(HANGUL_CLASSES) + 1
PROPERTY_PREPEND = 1 << 3
PROPERTY_EXTEND = 1 << 4
PROPERTY_SPACING_MARK = 1 << 5
PROPERTY_INCB_CONSONANT = 1 << 6
PROPERTY_INCB_LINKER = 2 << 6
PROPERTY_INCB_EXTEND = 3 << 6
PROPERTY_INCB_MASK = 3 << 6

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
    "emoji-data.txt": (
        f"{UNICODE_BASE_URL}/emoji/emoji-data.txt",
        "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b",
    ),
    "GraphemeBreakProperty.txt": (
        f"{UNICODE_BASE_URL}/auxiliary/GraphemeBreakProperty.txt",
        "d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89",
    ),
    "DerivedCoreProperties.txt": (
        f"{UNICODE_BASE_URL}/DerivedCoreProperties.txt",
        "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08",
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


def parse_combining_class(text, target_class):
    ranges = []
    range_start = None
    range_combining = None
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
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
            if combining == target_class:
                ranges.append((range_start, value))
            range_start = None
            range_combining = None
        elif combining == target_class:
            ranges.append((value, value))

    if range_start is not None:
        raise RuntimeError("Unterminated UnicodeData range")
    return merge_ranges(ranges)


def ranges_for_category(categories, category):
    ranges = []
    start = None
    for value, current in enumerate(categories):
        if current == category:
            if start is None:
                start = value
        elif start is not None:
            ranges.append((start, value - 1))
            start = None
    if start is not None:
        ranges.append((start, MAX_SCALAR))
    return ranges


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


def parse_grapheme_break_property(text, property_name):
    ranges = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 2 or fields[1] != property_name:
            continue
        code_range = fields[0]
        if ".." in code_range:
            lo, hi = code_range.split("..")
        else:
            lo = hi = code_range
        ranges.append((int(lo, 16), int(hi, 16)))
    return merge_ranges(ranges)


def parse_emoji_property(text, property_name):
    ranges = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 2 or fields[1] != property_name:
            continue
        code_range = fields[0]
        if ".." in code_range:
            lo, hi = code_range.split("..")
        else:
            lo = hi = code_range
        ranges.append((int(lo, 16), int(hi, 16)))
    return merge_ranges(ranges)


def parse_indic_conjunct_break(text, property_value):
    ranges = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 3 or fields[1] != "InCB" or fields[2] != property_value:
            continue
        code_range = fields[0]
        if ".." in code_range:
            lo, hi = code_range.split("..")
        else:
            lo = hi = code_range
        ranges.append((int(lo, 16), int(hi, 16)))
    return merge_ranges(ranges)


def terminal_width(value, categories, east_asian_wide, grapheme_prepend,
                   incb_linker):
    if value == 0:
        return 0
    if value < 0x20:
        return -1
    if value < 0x7F:
        return 1
    if value < 0xA0:
        return -1

    category = categories[value]
    if grapheme_prepend[value]:
        return 1
    if incb_linker[value]:
        return 0
    if category in ("Mn", "Mc", "Me"):
        return 0
    if category == "Cf":
        return 1 if value == 0x00AD else 0
    if category in ("Zl", "Zp"):
        return 0
    if category == "Sk":
        if 0x1F3FB <= value <= 0x1F3FF:
            return 2
        if value in (0xFF3E, 0xFF40, 0xFFE3):
            return 2

    if 0x1160 <= value <= 0x11FF or 0xD7B0 <= value <= 0xD7FF:
        return 0
    if 0x1F1E6 <= value <= 0x1F1FF:
        return 2
    if east_asian_wide[value]:
        return 2
    return 1


def make_width_pages(categories, east_asian_ranges, grapheme_prepend_ranges,
                     incb_linker_ranges):
    wide = bytearray(MAX_SCALAR + 1)
    for lo, hi in east_asian_ranges:
        wide[lo : hi + 1] = bytes([1]) * (hi - lo + 1)

    grapheme_prepend = bytearray(MAX_SCALAR + 1)
    for lo, hi in grapheme_prepend_ranges:
        grapheme_prepend[lo : hi + 1] = bytes([1]) * (hi - lo + 1)

    incb_linker = bytearray(MAX_SCALAR + 1)
    for lo, hi in incb_linker_ranges:
        incb_linker[lo : hi + 1] = bytes([1]) * (hi - lo + 1)

    page_indices = []
    pages = []
    known_pages = {}
    for page_start in range(0, MAX_SCALAR + 1, PAGE_SIZE):
        encoded = [
            terminal_width(value, categories, wide, grapheme_prepend,
                           incb_linker) + 1
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


def make_grapheme_property_pages(grapheme_prepend_ranges,
                                 grapheme_extend_ranges,
                                 spacing_mark_ranges, incb_consonant_ranges,
                                 incb_linker_ranges, incb_extend_ranges,
                                 hangul_class_ranges, control_ranges):
    properties = bytearray(MAX_SCALAR + 1)

    def apply_ranges(ranges, value, mask=0):
        for lo, hi in ranges:
            for scalar in range(lo, hi + 1):
                properties[scalar] = (properties[scalar] & ~mask) | value

    apply_ranges(grapheme_prepend_ranges, PROPERTY_PREPEND)
    apply_ranges(grapheme_extend_ranges, PROPERTY_EXTEND)
    apply_ranges(spacing_mark_ranges, PROPERTY_SPACING_MARK)
    apply_ranges(incb_consonant_ranges, PROPERTY_INCB_CONSONANT,
                 PROPERTY_INCB_MASK)
    apply_ranges(incb_linker_ranges, PROPERTY_INCB_LINKER,
                 PROPERTY_INCB_MASK)
    apply_ranges(incb_extend_ranges, PROPERTY_INCB_EXTEND,
                 PROPERTY_INCB_MASK)
    for index, name in enumerate(HANGUL_CLASSES):
        apply_ranges(hangul_class_ranges[name], index + 1, PROPERTY_CLASS_MASK)
    apply_ranges(control_ranges, PROPERTY_CLASS_CONTROL, PROPERTY_CLASS_MASK)

    # Page zero is the all-zero page, so `graphemeProperties` can answer from
    # the index alone for the scalars that carry no break property at all.
    empty_page = bytes(PAGE_SIZE)
    page_indices = []
    pages = [empty_page]
    known_pages = {empty_page: 0}
    for page_start in range(0, MAX_SCALAR + 1, PAGE_SIZE):
        page = bytes(properties[page_start : page_start + PAGE_SIZE])
        page_index = known_pages.get(page)
        if page_index is None:
            page_index = len(pages)
            if page_index > 0xFF:
                raise RuntimeError("The grapheme page index no longer fits in UInt8")
            known_pages[page] = page_index
            pages.append(page)
        page_indices.append(page_index)
    return page_indices, b"".join(pages), len(pages)


def hangul_join_rows():
    """Packs UAX #29 GB6, GB7 and GB8 into one byte per left-hand class."""
    index = {name: position + 1 for position, name in enumerate(HANGUL_CLASSES)}
    joins = {
        "L": ("L", "V", "LV", "LVT"),
        "V": ("V", "T"),
        "T": ("T",),
        "LV": ("V", "T"),
        "LVT": ("T",),
    }
    rows = 0
    for left, rights in joins.items():
        row = 0
        for right in rights:
            row |= 1 << index[right]
        rows |= row << (index[left] * 8)
    return rows


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


def generate(source_text, generator_checksum):
    categories = parse_unicode_categories(source_text["UnicodeData.txt"])
    combining_ranges = parse_nonzero_combining_class(source_text["UnicodeData.txt"])
    virama_ranges = parse_combining_class(source_text["UnicodeData.txt"], 9)
    east_asian_ranges = parse_east_asian_width(source_text["EastAsianWidth.txt"])
    emoji_vs16_ranges = parse_emoji_vs16_bases(source_text["emoji-variation-sequences.txt"])
    emoji_modifier_base_ranges = parse_emoji_property(
        source_text["emoji-data.txt"], "Emoji_Modifier_Base")
    grapheme_prepend_ranges = parse_grapheme_break_property(
        source_text["GraphemeBreakProperty.txt"], "Prepend")
    # UAX #29 GB9 joins Extend and ZWJ alike, so they share one bit.
    grapheme_extend_ranges = merge_ranges(
        parse_grapheme_break_property(
            source_text["GraphemeBreakProperty.txt"], "Extend") +
        parse_grapheme_break_property(
            source_text["GraphemeBreakProperty.txt"], "ZWJ"))
    grapheme_spacing_mark_ranges = parse_grapheme_break_property(
        source_text["GraphemeBreakProperty.txt"], "SpacingMark")
    # UAX #29 GB4 and GB5 break on both sides of a control character, ahead of
    # every rule that a property bit below could otherwise satisfy.
    grapheme_control_ranges = merge_ranges(
        parse_grapheme_break_property(
            source_text["GraphemeBreakProperty.txt"], "Control") +
        parse_grapheme_break_property(
            source_text["GraphemeBreakProperty.txt"], "CR") +
        parse_grapheme_break_property(
            source_text["GraphemeBreakProperty.txt"], "LF"))
    # wcwidth widens terminal graphemes that contain an Mc scalar. This is a
    # terminal-width policy. It is not Grapheme_Cluster_Break=SpacingMark.
    spacing_mark_width_ranges = ranges_for_category(categories, "Mc")
    incb_consonant_ranges = parse_indic_conjunct_break(
        source_text["DerivedCoreProperties.txt"], "Consonant")
    incb_linker_ranges = parse_indic_conjunct_break(
        source_text["DerivedCoreProperties.txt"], "Linker")
    incb_extend_ranges = parse_indic_conjunct_break(
        source_text["DerivedCoreProperties.txt"], "Extend")
    hangul_class_ranges = {
        name: parse_grapheme_break_property(
            source_text["GraphemeBreakProperty.txt"], name)
        for name in HANGUL_CLASSES
    }
    page_indices, packed_pages, page_count = make_width_pages(
        categories, east_asian_ranges, grapheme_prepend_ranges,
        incb_linker_ranges)
    property_page_indices, property_pages, property_page_count = \
        make_grapheme_property_pages(
            grapheme_prepend_ranges, grapheme_extend_ranges,
            grapheme_spacing_mark_ranges, incb_consonant_ranges,
            incb_linker_ranges, incb_extend_ranges, hangul_class_ranges,
            grapheme_control_ranges)

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
            f"// Grapheme table: {len(property_page_indices)} page indices, "
            f"{property_page_count} unique pages, "
            f"{len(property_page_indices) + len(property_pages)} bytes.\n",
            "struct UnicodeWidthData {\n",
            "    typealias Range = UnicodeUtil.LH\n\n",
            "    private static let pageBits = 8\n",
            "    private static let packedPageBits = 6\n\n",
        ]
    )
    append_byte_array(lines, "widthPageIndices", page_indices)
    append_byte_array(lines, "packedWidthPages", packed_pages)
    append_byte_array(lines, "graphemePageIndices", property_page_indices)
    append_byte_array(lines, "graphemePropertyPages", property_pages)
    append_ranges(lines, "eastAsianWide", east_asian_ranges)
    append_ranges(lines, "emojiVs16Base", emoji_vs16_ranges)
    append_ranges(lines, "emojiModifierBase", emoji_modifier_base_ranges)
    append_ranges(lines, "nonzeroCombiningClass", combining_ranges)
    append_ranges(lines, "spacingMarkWidth", spacing_mark_width_ranges)
    append_ranges(lines, "virama", virama_ranges)
    lines.extend(
        [
            f"    static let graphemePrependMask: UInt8 = 0x{PROPERTY_PREPEND:02X}\n",
            f"    static let graphemeExtendMask: UInt8 = 0x{PROPERTY_EXTEND:02X}\n",
            f"    static let graphemeSpacingMarkMask: UInt8 = 0x{PROPERTY_SPACING_MARK:02X}\n",
            f"    static let incbMask: UInt8 = 0x{PROPERTY_INCB_MASK:02X}\n",
            f"    static let incbConsonantValue: UInt8 = 0x{PROPERTY_INCB_CONSONANT:02X}\n",
            f"    static let incbLinkerValue: UInt8 = 0x{PROPERTY_INCB_LINKER:02X}\n",
            f"    static let incbExtendValue: UInt8 = 0x{PROPERTY_INCB_EXTEND:02X}\n",
            f"    static let graphemeClassMask: UInt8 = 0x{PROPERTY_CLASS_MASK:02X}\n",
            f"    static let graphemeClassHangulMax: UInt8 = {len(HANGUL_CLASSES)}\n",
            f"    static let graphemeClassControl: UInt8 = {PROPERTY_CLASS_CONTROL}\n",
            "    /// Grapheme_Cluster_Break Hangul joins (UAX #29 GB6, GB7 and\n",
            "    /// GB8), as one row of eight bits per left-hand class. Bit *i*\n",
            "    /// of row *j* is set when class *j* joins class *i*. The class\n",
            "    /// order is none, L, V, T, LV and LVT.\n",
            f"    static let hangulJoinRows: UInt64 = 0x{hangul_join_rows():016X}\n\n",
            "    @inline(__always)\n",
            "    static func columnWidth (_ value: UInt32) -> Int\n",
            "    {\n",
            "        let scalar = Int (value)\n",
            "        let page = Int (widthPageIndices [scalar >> pageBits])\n",
            "        let packed = packedWidthPages [(page << packedPageBits) | ((scalar & 0xFF) >> 2)]\n",
            "        let shift = UInt8 ((scalar & 3) << 1)\n",
            "        return Int ((packed >> shift) & 3) - 1\n",
            "    }\n",
            "\n",
            "    @inline(__always)\n",
            "    static func graphemeProperties (_ value: UInt32) -> UInt8\n",
            "    {\n",
            "        let scalar = Int (value)\n",
            "        let page = Int (graphemePageIndices [scalar >> pageBits])\n",
            "        // Page zero holds only zeros. Most text lands there, and\n",
            "        // stopping here keeps the 256-byte pages out of the way.\n",
            "        if page == 0 {\n",
            "            return 0\n",
            "        }\n",
            "        return graphemePropertyPages [(page << pageBits) | (scalar & 0xFF)]\n",
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
