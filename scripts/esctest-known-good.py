#!/usr/bin/env python3
"""Writes the esctest allowlist from the logs of full esctest runs.

The allowlist holds each test that passed in every log given, as
`Class.test_name`, one per line. Tests/SwiftTermTests/SwiftTermTests.swift
anchors each name, so a test runs only when its full name is on the list.

To make the logs, run the full suite (each run takes about 40 seconds):

    make clone-esctest
    ESCTEST_REPORT_LOG=/tmp/esctest-1.log swift test --filter testFullSuiteReport
    ESCTEST_REPORT_LOG=/tmp/esctest-2.log swift test --filter testFullSuiteReport
    python3 scripts/esctest-known-good.py /tmp/esctest-1.log /tmp/esctest-2.log

Give two or more logs, so that a test that passes only sometimes stays off
the list.
"""

import os
import re
import sys

HEADER = """\
# esctest tests that SwiftTerm passes. testKnownGood runs each one and fails
# if any of them fails. Regenerate with scripts/esctest-known-good.py.
"""


def passed_tests(path):
    with open(path, encoding="latin-1") as f:
        log = f.read()
    passed = set()
    for block in re.split(r"\nRun test: ", log)[1:]:
        name = block.split("\n", 1)[0].strip()
        if re.search(r"\nPassed\.\n", block):
            passed.add(name)
    return passed


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    logs = sys.argv[1:]
    passed = passed_tests(logs[0])
    for path in logs[1:]:
        passed &= passed_tests(path)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "Tests", "SwiftTermTests", "Fixtures",
                       "esctest-known-good.txt")
    with open(out, "w") as f:
        f.write(HEADER)
        for name in sorted(passed):
            f.write(name + "\n")
    print("%d tests in %s" % (len(passed), os.path.normpath(out)))


if __name__ == "__main__":
    main()
