#!/usr/bin/env python3
"""Whether the sweep stops after a run (design § 8), read from regenerate.py's own tables
(stdlib only).

  stopcheck.py <run-id> [--results <dir>]     exit 0: go on; exit 1: stop, with the reasons

After each run's ingest, `run.sh` asks this. The sweep stops when, in any table row of the run:
- a cell reads as missing ("fail (missing: ...)"): an input the analysis needs isn't there, so
  later runs would lose the same input;
- the run is a P0 and a hard criterion failed (any verdict starting with "fail"), criterion 3's
  convergence included: the controls every other cell is judged against aren't usable.

"fail (no control)" doesn't stop it: early in the sweep a run's P0 controls haven't all run yet.

A P0 run's per-session verdict (session_rows, the § 5 null check) is report-only here: it is
printed as `P0 per-session: <pass|fail> (report-only; judged by regenerate)` and doesn't stop the
sweep. A missing input in it still stops. regenerate.py's verdicts and --check are unchanged.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import clientload  # noqa: E402
import regenerate  # noqa: E402

# The tables whose rows start with the run id.
ROW_TABLES = ("session_rows", "close_rows", "match_rows", "convergence_rows", "quiet_rows", "profile_rows",
              "memory_rows", "client_bound_rows", "isolation_rows")
NO_CONTROL = "fail (no control)"
# A P0 run's rows in these tables are reported, not stopped on (a missing input still stops).
REPORT_ONLY_P0 = ("session_rows",)


def report(runs: dict[str, dict], rid: str) -> list[str]:
    """A P0 run's per-session verdict per group, for the log: it doesn't stop the sweep."""
    run = runs.get(rid)
    if run is None or run["params"].get("profile") != "P0":
        return []
    return [f"P0 per-session: {row[2]}: {row[-1]} (report-only; judged by regenerate)"
            for row in regenerate.session_rows(runs) if row and row[0] == rid]


def reasons(runs: dict[str, dict], rid: str) -> list[str]:
    run = runs.get(rid)
    if run is None:
        return [f"{rid}: no results (ingest didn't write results/{rid}.json)"]
    is_p0 = run["params"].get("profile") == "P0"
    out = []
    dirty = ((run.get("meta") or {}).get("git") or {}).get("dirty")
    if dirty is not False:
        out.append(f"not from a clean tree (git dirty: {dirty})")
    # The client must not be the bottleneck: the same rule regenerate.py refuses a run by.
    out.extend(clientload.failures(run.get("meta") or {}))
    backlog = (run.get("meta") or {}).get("sendBacklogEnv")
    if backlog is None or any(backlog.values()):
        out.append(f"send-backlog settings {backlog}: the sweep runs the shipped defaults, recorded and unset")
    for table in ROW_TABLES:
        for row in getattr(regenerate, table)(runs):
            if not row or row[0] != rid:
                continue
            for value in row[1:]:
                text = str(value)
                # "fail (no control)" names no input, so it never reads as missing.
                if "missing" in text:
                    out.append(f"{table}: {text}")
                elif is_p0 and table not in REPORT_ONLY_P0 and text.startswith("fail") and not text.startswith(NO_CONTROL):
                    out.append(f"{table}: P0 hard failure: {text}")
    return sorted(set(out))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id")
    ap.add_argument("--results", type=pathlib.Path, default=TOPIC / "results")
    ap.add_argument("--run-file", type=pathlib.Path,
                    help="the run's ingested result when it isn't in results/ (a smoke run's data/<run-id>/result.json)")
    args = ap.parse_args(argv)
    runs = {p.stem: json.loads(p.read_text()) for p in sorted(args.results.glob("*.json"))}
    if args.run_file is not None:
        runs[args.run_id] = json.loads(args.run_file.read_text())
    found = reasons(runs, args.run_id)
    for line in report(runs, args.run_id):
        print(f"{args.run_id}: {line}")
    if found:
        print(f"stop after {args.run_id}:")
        for r in found:
            print(f"  {r}")
        return 1
    print(f"{args.run_id}: go on")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
