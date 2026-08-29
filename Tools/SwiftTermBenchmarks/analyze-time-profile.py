#!/usr/bin/env python3

import argparse
import collections
import xml.etree.ElementTree as ET


def referenced(element, definitions):
    reference = element.get("ref")
    return definitions.get(reference, element) if reference else element


def frame_name(element, definitions):
    return referenced(element, definitions).get("name", "<unknown>")


def main():
    parser = argparse.ArgumentParser(
        description="Summarize an xctrace time-profile XML export.")
    parser.add_argument("xml")
    parser.add_argument(
        "--root",
        default="Terminal.feed",
        help="Keep samples whose stack contains this text. Use an empty value for all samples.")
    parser.add_argument(
        "--callers-of",
        default="",
        help="Show immediate callers of functions whose name contains this text.")
    parser.add_argument("--limit", type=int, default=30)
    options = parser.parse_args()

    document = ET.parse(options.xml)
    root = document.getroot()
    definitions = {
        element.get("id"): element
        for element in root.iter()
        if element.get("id") is not None
    }

    self_weight = collections.Counter()
    inclusive_weight = collections.Counter()
    caller_weight = collections.Counter()
    caller_total_weight = 0
    total_weight = 0
    sample_count = 0

    for row in root.iter("row"):
        backtrace_element = row.find("tagged-backtrace")
        weight_element = row.find("weight")
        if backtrace_element is None or weight_element is None:
            continue

        backtrace = referenced(backtrace_element, definitions)
        weight_node = referenced(weight_element, definitions)
        try:
            weight = int(weight_node.text or "0")
        except ValueError:
            continue

        names = [frame_name(frame, definitions) for frame in backtrace.findall("frame")]
        if not names or (options.root and not any(options.root in name for name in names)):
            continue

        sample_count += 1
        total_weight += weight
        self_weight[names[0]] += weight
        for name in dict.fromkeys(names):
            inclusive_weight[name] += weight
        if options.callers_of:
            matching_indices = [
                index for index, name in enumerate(names)
                if options.callers_of in name
            ]
            if matching_indices:
                caller_total_weight += weight
                for index in matching_indices:
                    caller = names[index + 1] if index + 1 < len(names) else "<root>"
                    caller_weight[caller] += weight

    print(f"samples\t{sample_count}")
    print(f"weight_ms\t{total_weight / 1_000_000:.3f}")
    print("\nself_ms\tself_pct\tfunction")
    for name, weight in self_weight.most_common(options.limit):
        percentage = 100 * weight / total_weight if total_weight else 0
        print(f"{weight / 1_000_000:.3f}\t{percentage:.2f}\t{name}")

    print("\ninclusive_ms\tinclusive_pct\tfunction")
    for name, weight in inclusive_weight.most_common(options.limit):
        percentage = 100 * weight / total_weight if total_weight else 0
        print(f"{weight / 1_000_000:.3f}\t{percentage:.2f}\t{name}")

    if options.callers_of:
        print(f"\ncallers_of\t{options.callers_of}")
        print(f"caller_weight_ms\t{caller_total_weight / 1_000_000:.3f}")
        print("inclusive_ms\tcaller_pct\tcaller")
        for name, weight in caller_weight.most_common(options.limit):
            percentage = 100 * weight / caller_total_weight if caller_total_weight else 0
            print(f"{weight / 1_000_000:.3f}\t{percentage:.2f}\t{name}")


if __name__ == "__main__":
    main()
