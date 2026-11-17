#!/usr/bin/env python3
"""Summarize a cross-verify run: one machine's runner replaying another machine's recordings.

  python3 -I scripts/crossverify_collect.py <logs dir> <records dir> <runner> <json out>
      --arch <arch> --host <host> --swift <`swift --version` first line> --commit <runner's commit>
      --recorded-on <arch of the machine that recorded them>

<records dir> holds the recordings replayed (s<N>.sstr); <logs dir> one `ReevaluationRunner --input
s<N>.sstr --verify` output per recording, s<N>.log, with its exit status in s<N>.exit. <runner> is
the binary that ran them (its sha256 is recorded). A recording passes when the runner exits 0 and
prints both "Verified state hashes" lines (against the recorded hashes, and across two re-evaluation
runs). regenerate.py gates the result against results/batch-<format>-SHA256SUMS.txt.
"""
import argparse
import hashlib
import json
import pathlib
import re

VERIFIED = "Verified state hashes"
RECORD = re.compile(r"Record: (\d+\.\d+), complete")


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    for name in ("logs", "records", "runner", "out"):
        ap.add_argument(name)
    for name in ("arch", "host", "swift", "commit", "recorded-on"):
        ap.add_argument(f"--{name}", required=True)
    a = ap.parse_args()
    logs, records = pathlib.Path(a.logs), pathlib.Path(a.records)
    runs, formats = [], set()
    for rec in sorted(records.glob("s*.sstr"), key=lambda p: int(p.stem[1:])):
        text = (logs / f"{rec.stem}.log").read_text(encoding="utf-8", errors="replace")
        code = int((logs / f"{rec.stem}.exit").read_text(encoding="utf-8").strip())
        formats.update(RECORD.findall(text))
        lines = text.count(VERIFIED)
        runs.append({"seed": int(rec.stem[1:]), "recording_sha256": sha256(rec), "exit": code,
                     "verified_lines": lines, "passed": code == 0 and lines == 2})
    if len(formats) != 1:
        raise SystemExit(f"the logs name {sorted(formats)} record formats, expected one")
    doc = {
        "meta": {"arch": a.arch, "host": a.host, "swift": a.swift, "git_sha": a.commit, "build": "release",
                 "runner_sha256": sha256(a.runner), "record_format": formats.pop(), "recorded_on": a.recorded_on},
        "recordings": runs,
    }
    pathlib.Path(a.out).write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(runs)} recordings ({sum(r['passed'] for r in runs)} passed) to {a.out}")


if __name__ == "__main__":
    main()
