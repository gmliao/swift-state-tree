#!/usr/bin/env python3
"""Replays every record of a `--record-dir` with `ReevaluationRunner --verify` (stdlib only).

  replay.py <ReevaluationRunner binary> <record-dir> <out.json>

The runner must get the cell's `VISIBILITY_TEST_*` environment: it refuses a record made with
other settings (exit 2). The output maps each run's cell suffix to its rooms, each with the
runner's exit code and its `Sync Output` line; a room passes on exit 0 with a `passed` line.
Exits non-zero, after writing the report, if any room didn't pass.
"""
import json, pathlib, re, subprocess, sys


def verdict(binary, record):
    proc = subprocess.run([binary, "--input", str(record), "--verify"], capture_output=True, text=True, encoding="utf-8")
    lines = [l.strip() for l in (proc.stdout + proc.stderr).splitlines()]
    sync = next((l for l in lines if l.startswith("Sync Output:")), None)
    return {
        "exitCode": proc.returncode,
        "syncOutput": sync,
        "passed": proc.returncode == 0 and sync is not None and sync.startswith("Sync Output: passed"),
        "lastLines": lines[-5:] if proc.returncode != 0 else [],
    }


def main(binary, record_dir, out):
    result, failed = {}, []
    runs = sorted(p for p in pathlib.Path(record_dir).iterdir() if p.is_dir())
    if not runs:
        sys.exit(f"{record_dir}: no runs")
    for run in runs:
        match = re.search(r"-visibility-test-(r\d+-p\d+-k\d+-serial)$", run.name)
        if not match:
            sys.exit(f"{run}: not a visibility-test record run")
        records = sorted(run.glob("room-*.sstr"))
        if not records:
            sys.exit(f"{run}: no records")
        rooms = {r.name: verdict(binary, r) for r in records}
        result[match.group(1)] = rooms
        failed += [f"{run.name}/{name}" for name, v in rooms.items() if not v["passed"]]
    pathlib.Path(out).write_text(json.dumps(result, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    if failed:
        sys.exit("replay failed: " + ", ".join(failed))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
