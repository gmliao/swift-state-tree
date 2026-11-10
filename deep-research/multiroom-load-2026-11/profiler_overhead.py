#!/usr/bin/env python3
"""The profiler-overhead pair's gate (stdlib only). Every table's RTT comes from profiled runs, so
the pair (overhead-profiled, overhead-unprofiled: 500 rooms, back to back) must show the profiler
didn't move the tail: the profiled run's steady RTT p99 may exceed the unprofiled run's by at most
max(MIN_EXCESS_MS, MAX_EXCESS_SHARE of the unprofiled p99). The refreeze sweep's pair (archived)
was 5.83 against 1.98 ms, from one 2 s episode in the profiled run; the 2026-11-06 pair was within
0.1 %. Server CPU keeps its own column in the pair's table.

`failure(profiled, unprofiled)` is the one rule, used by run.sh (through `check`: the sweep stops,
failed-profiler-overhead) and regenerate.py (an arm sweep is refused).

Usage: python3 profiler_overhead.py check <profiled summary.json> <unprofiled summary.json> <ws-loadtest dir>
  exit 0: within the bound (prints the two p99s); exit 1: the reason; exit 2: the check couldn't
  read its inputs (the error on stdout).
"""
from __future__ import annotations

import json
import os
import sys

MIN_EXCESS_MS = 1.0
MAX_EXCESS_SHARE = 0.25


def steady_p99(report: dict) -> float | None:
    """The steady phase's RTT p99 (ms), or None."""
    phase = next((p for p in report.get("phases") or [] if p.get("name") == "steady"), None)
    value = ((phase or {}).get("rtt") or {}).get("p99")
    return value if isinstance(value, (int, float)) else None


def allowed_excess(unprofiled_p99: float) -> float:
    """How far over the unprofiled steady RTT p99 the profiled one may be, ms."""
    return max(MIN_EXCESS_MS, MAX_EXCESS_SHARE * unprofiled_p99)


def failure(profiled: dict, unprofiled: dict) -> str | None:
    """Why the pair shows the profiler moved the RTT tail; None when it didn't."""
    return failure_of(steady_p99(profiled), steady_p99(unprofiled))


def failure_of(a: float | None, b: float | None) -> str | None:
    """`failure` on the two steady RTT p99s (ms), profiled then unprofiled."""
    if a is None or b is None:
        return f"profiler overhead not measured: steady RTT p99 {a!r} profiled, {b!r} unprofiled"
    allowed = allowed_excess(b)
    if a - b > allowed:
        return (f"profiler overhead: steady RTT p99 {a:.2f} ms profiled against {b:.2f} ms unprofiled, "
                f"+{a - b:.2f} ms, over the bound of +{allowed:.2f} ms (max(+{MIN_EXCESS_MS:g} ms, +{MAX_EXCESS_SHARE:.0%}))")
    return None


def report_of(summary_path: str, ws: str) -> dict:
    """The one run's report a scalability summary names (run.sh has checked it exists)."""
    path = json.load(open(summary_path))["runs"][0]["reportJson"]
    return json.load(open(path if os.path.isabs(path) else os.path.join(ws, path)))


def main(argv: list[str]) -> int:
    if len(argv) != 4 or argv[0] != "check":
        print(__doc__.split("Usage: ", 1)[1], file=sys.stderr)
        return 2
    _, profiled, unprofiled, ws = argv
    a, b = report_of(profiled, ws), report_of(unprofiled, ws)
    why = failure(a, b)
    print(why or f"steady RTT p99 {steady_p99(a):.2f} ms profiled, {steady_p99(b):.2f} ms unprofiled: within the bound")
    return 1 if why else 0


if __name__ == "__main__":
    # A check that can't read its inputs exits 2 with the error, so run.sh doesn't report it as the
    # rule's verdict (exit 1).
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # noqa: BLE001
        print(f"profiler overhead check failed: {type(e).__name__}: {e}")
        sys.exit(2)
