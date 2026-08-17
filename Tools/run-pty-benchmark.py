#!/usr/bin/env python3
"""Build and run paired MacTerminal PTY benchmarks."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shlex
import statistics
import subprocess
import sys
import tempfile
from typing import TextIO


# A repetition this far from its (case, build) population median is flagged.
# Same-build spread with the per-case byte budgets is about 2 %; the outlier
# that motivated the flag sat 23 % out. Ten percent separates the two with
# room on both sides.
OUTLIER_THRESHOLD_PCT = 10.0

DELTA_FIELDS = (
    "elapsed_s",
    "mb_s",
    "lock_wait_parse_total",
    "frame_refresh_p99",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build A and B in alternating order and print paired PTY benchmark deltas."
    )
    parser.add_argument("--a-tree", type=Path, required=True, help="Checkout for build A.")
    parser.add_argument("--b-tree", type=Path, required=True, help="Checkout for build B.")
    parser.add_argument("--pairs", type=int, default=5, help="Number of A/B pairs. Default: 5.")
    parser.add_argument("--repeat", type=int, default=1, help="Measured repeats per case and launch.")
    parser.add_argument(
        "--case",
        default="all",
        help="Benchmark case, 'all', or 'quick' (the five scrolling cases "
        "plus unicode, ~19 s — enough for most A/B work). Default: all.",
    )
    parser.add_argument("--label-a", default="A", help="Machine-output label for A.")
    parser.add_argument("--label-b", default="B", help="Machine-output label for B.")
    parser.add_argument(
        "--case-timeout",
        type=float,
        default=45.0,
        help="Watchdog limit for each repetition. Default: 45 seconds.",
    )
    parser.add_argument(
        "--renderer",
        choices=("metal", "cg"),
        default="metal",
        help="Renderer for both builds. Default: metal.",
    )
    parser.add_argument(
        "--derived-data-root",
        type=Path,
        help="Keep DerivedData below this directory. The default is temporary storage.",
    )
    return parser.parse_args()


def validate(options: argparse.Namespace) -> None:
    if options.pairs <= 0:
        raise ValueError("--pairs must be positive")
    if options.repeat <= 0:
        raise ValueError("--repeat must be positive")
    if options.case_timeout <= 0:
        raise ValueError("--case-timeout must be positive")
    for name, tree in (("A", options.a_tree), ("B", options.b_tree)):
        project = tree.resolve() / "TerminalApp" / "MacTerminal.xcodeproj"
        if not project.is_dir():
            raise ValueError(f"{name} project does not exist: {project}")


def run_and_tee(command: list[str], cwd: Path, output: TextIO | None = None) -> int:
    process = subprocess.Popen(
        command,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
        if output is not None:
            output.write(line)
    return process.wait()


def parse_result(line: str) -> dict[str, str] | None:
    if not line.startswith("PTYBENCH "):
        return None
    result: dict[str, str] = {}
    for field in shlex.split(line)[1:]:
        key, separator, value = field.partition("=")
        if separator:
            result[key] = value
    return result


def build_and_run(
    tree: Path,
    derived_data: Path,
    label: str,
    options: argparse.Namespace,
    log_path: Path,
) -> list[dict[str, str]]:
    tree = tree.resolve()
    project = tree / "TerminalApp" / "MacTerminal.xcodeproj"
    build = [
        "xcodebuild",
        "-project",
        str(project),
        "-scheme",
        "MacTerminal",
        "-configuration",
        "Release",
        "-derivedDataPath",
        str(derived_data),
        "CODE_SIGNING_ALLOWED=NO",
        "build",
    ]
    print(f"PTYBENCH_DRIVER build={label} tree={tree}", flush=True)
    if run_and_tee(build, tree) != 0:
        raise RuntimeError(f"Build {label} failed")

    executable = (
        derived_data
        / "Build"
        / "Products"
        / "Release"
        / "MacTerminal.app"
        / "Contents"
        / "MacOS"
        / "MacTerminal"
    )
    if not executable.is_file():
        raise RuntimeError(f"Built executable does not exist: {executable}")

    environment = os.environ.copy()
    environment.update(
        {
            "SWIFTTERM_PROFILE_STATS": "1",
            "SWIFTTERM_BASELINE": options.case,
            "SWIFTTERM_BASELINE_REPEAT": str(options.repeat),
            "SWIFTTERM_BASELINE_LABEL": label,
            "SWIFTTERM_BASELINE_TIMEOUT": str(options.case_timeout),
            "SWIFTTERM_METAL": "1" if options.renderer == "metal" else "0",
        }
    )
    print(f"PTYBENCH_DRIVER launch={label} executable={executable}", flush=True)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            [str(executable)],
            cwd=tree,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        results: list[dict[str, str]] = []
        for line in process.stdout:
            sys.stdout.write(line)
            log.write(line)
            parsed = parse_result(line.rstrip("\n"))
            if parsed is not None:
                results.append(parsed)
        status = process.wait()
    if status != 0:
        raise RuntimeError(f"Benchmark {label} exited with status {status}")
    if not results:
        raise RuntimeError(f"Benchmark {label} did not emit a PTYBENCH line")
    return results


def result_key(result: dict[str, str]) -> tuple[str, str]:
    return result.get("case", ""), result.get("repeat", "")


def percent_delta(before: dict[str, str], after: dict[str, str], field: str) -> str:
    try:
        a = float(before[field])
        b = float(after[field])
    except (KeyError, ValueError):
        return "na"
    if a == 0:
        return "na"
    return f"{(b - a) * 100.0 / a:+.2f}"


def print_deltas(
    pair: int,
    a_results: list[dict[str, str]],
    b_results: list[dict[str, str]],
) -> int:
    a_by_key = {result_key(result): result for result in a_results}
    b_by_key = {result_key(result): result for result in b_results}
    if a_by_key.keys() != b_by_key.keys():
        missing_a = sorted(b_by_key.keys() - a_by_key.keys())
        missing_b = sorted(a_by_key.keys() - b_by_key.keys())
        raise RuntimeError(f"Unpaired results: missing_A={missing_a} missing_B={missing_b}")

    valid_count = 0
    for key in sorted(a_by_key):
        case, repeat = key
        status_a = a_by_key[key].get("status")
        status_b = b_by_key[key].get("status")
        if status_a is not None or status_b is not None:
            print(
                f"PTYBENCH_DISCARD pair={pair} case={case} repeat={repeat} "
                f"status_A={status_a or 'ok'} status_B={status_b or 'ok'}",
                flush=True,
            )
            continue

        fields = " ".join(
            f"{field}_pct={percent_delta(a_by_key[key], b_by_key[key], field)}"
            for field in DELTA_FIELDS
        )
        print(
            f"PTYBENCH_DELTA pair={pair} case={case} repeat={repeat} "
            f"direction=B_vs_A {fields}",
            flush=True,
        )
        valid_count += 1
    return valid_count


def report_outliers(history: list[tuple[int, str, list[dict[str, str]]]]) -> int:
    """Flag repetitions far outside their (case, build) population.

    The population spans every pair of the run, because that is where the
    hazard lives: one 4.350 s repetition against a 3.43-3.58 s population
    reads as a 23 % regression in its own pair and as noise in every other.
    Measurements are flagged, never discarded — a flagged delta is a reason
    to re-run, not a number to silently drop.
    """
    populations: dict[tuple[str, str], list[tuple[int, str, float]]] = {}
    for pair, label, results in history:
        for result in results:
            if result.get("status"):
                continue
            try:
                elapsed = float(result["elapsed_s"])
            except (KeyError, ValueError):
                continue
            key = (result.get("case", ""), label)
            populations.setdefault(key, []).append(
                (pair, result.get("repeat", ""), elapsed))

    flagged = 0
    for (case, label), values in sorted(populations.items()):
        if len(values) < 3:
            continue
        median = statistics.median(elapsed for _, _, elapsed in values)
        for pair, repeat, elapsed in values:
            deviation = (elapsed - median) * 100.0 / median
            if abs(deviation) > OUTLIER_THRESHOLD_PCT:
                print(
                    f"PTYBENCH_OUTLIER build={label} case={case} pair={pair} "
                    f"repeat={repeat} elapsed_s={elapsed:.3f} "
                    f"median_s={median:.3f} deviation_pct={deviation:+.1f}",
                    flush=True,
                )
                flagged += 1
    if flagged:
        print(
            f"PTYBENCH_DRIVER outliers={flagged} "
            "(re-run the affected pairs before trusting their deltas)",
            flush=True,
        )
    return flagged


def main() -> int:
    options = arguments()
    try:
        validate(options)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    temporary: tempfile.TemporaryDirectory[str] | None = None
    if options.derived_data_root is None:
        temporary = tempfile.TemporaryDirectory(prefix="swiftterm-ptybench-driver-")
        work_root = Path(temporary.name)
    else:
        work_root = options.derived_data_root.resolve()
        work_root.mkdir(parents=True, exist_ok=True)

    try:
        history: list[tuple[int, str, list[dict[str, str]]]] = []
        for pair in range(1, options.pairs + 1):
            print(f"PTYBENCH_DRIVER pair={pair}/{options.pairs}", flush=True)
            a_results = build_and_run(
                options.a_tree,
                work_root / "DerivedData-A",
                options.label_a,
                options,
                work_root / f"pair-{pair}-A.log",
            )
            b_results = build_and_run(
                options.b_tree,
                work_root / "DerivedData-B",
                options.label_b,
                options,
                work_root / f"pair-{pair}-B.log",
            )
            history.append((pair, options.label_a, a_results))
            history.append((pair, options.label_b, b_results))
            valid_count = print_deltas(pair, a_results, b_results)
            if valid_count == 0:
                raise RuntimeError(f"Pair {pair} has no valid paired results")
        report_outliers(history)
    except (OSError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    finally:
        if temporary is not None:
            temporary.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
