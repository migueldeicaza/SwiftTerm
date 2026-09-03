#!/usr/bin/env python3

import argparse
import collections
import xml.etree.ElementTree as ET


def resolve(element, definitions):
    seen = set()
    while element is not None and element.get("ref"):
        reference = element.get("ref")
        if reference in seen:
            break
        seen.add(reference)
        element = definitions.get(reference)
    return element


def text(element, definitions):
    resolved = resolve(element, definitions)
    return (resolved.text or "") if resolved is not None else ""


def main():
    parser = argparse.ArgumentParser(
        description="Summarize an xctrace CPU Counters MetricTable XML export.")
    parser.add_argument("xml")
    options = parser.parse_args()

    root = ET.parse(options.xml).getroot()
    definitions = {
        element.get("id"): element
        for element in root.iter()
        if element.get("id") is not None
    }

    node = next(
        (candidate for candidate in root.iter("node")
         if (candidate.find("schema") is not None
             and candidate.find("schema").get("name") == "MetricTable")),
        None)
    if node is None:
        parser.error("the XML does not contain a MetricTable export")

    schema = node.find("schema")
    columns = [column.findtext("mnemonic", "") for column in schema.findall("col")]
    required = ["duration", "metric-display-name", "metric-value", "is-ratio"]
    missing = [name for name in required if name not in columns]
    if missing:
        parser.error("the MetricTable is missing columns: " + ", ".join(missing))
    column_index = {name: columns.index(name) for name in required}

    metrics = collections.defaultdict(list)
    for row in node.findall("row"):
        values = list(row)
        try:
            duration = int(text(values[column_index["duration"]], definitions))
            name = text(values[column_index["metric-display-name"]], definitions)
            value = float(text(values[column_index["metric-value"]], definitions))
            is_ratio = text(values[column_index["is-ratio"]], definitions) == "1"
        except (IndexError, TypeError, ValueError):
            continue
        metrics[name].append((value, duration, is_ratio))

    print("metric\tvalue\tunit\trows")
    for name in sorted(metrics):
        samples = metrics[name]
        if all(is_ratio for _, _, is_ratio in samples):
            duration = sum(sample_duration for _, sample_duration, _ in samples)
            value = (sum(sample * sample_duration
                         for sample, sample_duration, _ in samples) / duration
                     if duration else 0)
            print(f"{name}\t{value * 100:.3f}\tpercent\t{len(samples)}")
        else:
            value = sum(sample for sample, _, _ in samples)
            print(f"{name}\t{value:.0f}\tcount\t{len(samples)}")


if __name__ == "__main__":
    main()
