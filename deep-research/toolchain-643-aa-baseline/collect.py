#!/usr/bin/env python3
"""Collect the raw A/A run into results/per-op.csv and results/whole-process.csv (stdlib only).

Usage: python3 collect.py <raw dir>

The raw dir is the run's output (turns/, mailbox/, encoding/, loadtest/), as aa-run.sh writes it.
Each perf stat CSV holds one `instructions:u` row; per-op rows pair a cell's n run with its 0 run.
"""
import csv
import glob
import json
import os
import pathlib
import re
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
RESULTS = TOPIC / "results"
BENCH_DIRS = {"turns": ("TurnsBench", ("turn", "direct")), "mailbox": ("TurnsMailboxBench", ("mailbox", "mailboxoff"))}


def count(path):
    """The instructions:u count in one `perf stat -x,` file, or None."""
    with open(path, encoding="utf-8", errors="replace") as f:
        for row in csv.reader(f):
            if len(row) > 2 and row[2].startswith("instructions") and row[0].isdigit():
                return int(row[0])
    return None


def per_op_rows(raw):
    rows = []
    for folder, (bench, impls) in BENCH_DIRS.items():
        pattern = re.compile(r"^(A|B)-(.+)-(" + "|".join(impls) + r")-(\d+)-(\d+)\.csv$")
        runs = {}
        for path in glob.glob(os.path.join(raw, folder, "*.csv")):
            m = pattern.match(os.path.basename(path))
            if m:
                side, cell, impl, iters, rep = m.groups()
                runs.setdefault((cell, impl, side, int(rep)), {})[int(iters)] = count(path)
        for (cell, impl, side, rep), by_iters in sorted(runs.items()):
            n = max(by_iters)
            if n == 0 or by_iters.get(n) is None or by_iters.get(0) is None:
                sys.exit(f"collect: {bench} {cell} {impl} {side} rep {rep} lacks its n or 0 run")
            rows.append([bench, cell, impl, side, rep, n, by_iters[n], by_iters[0]])
    return rows


def whole_rows(raw):
    rows = []
    for folder, workload in (("encoding", "EncodingBenchmark"), ("loadtest", "ServerLoadTest")):
        for d in sorted(glob.glob(os.path.join(raw, folder, "*-*"))):
            side, rep = os.path.basename(d).split("-")
            rc = open(os.path.join(d, "rc.txt"), encoding="utf-8").read().strip().removeprefix("rc=")
            extra = ""
            if workload == "EncodingBenchmark":
                extra = str(json.load(open(os.path.join(d, "out.json"), encoding="utf-8"))["bytesPerSync"])
            else:
                files = glob.glob(os.path.join(d, "server-loadtest-*.json"))
                if len(files) != 1:
                    sys.exit(f"collect: {d} has {len(files)} results files")
                build = json.load(open(files[0], encoding="utf-8"))["metadata"]["build"]
                extra = build["swiftVersion"].splitlines()[0]
            rows.append([workload, side, int(rep), int(rc), count(os.path.join(d, "perf.csv")), extra])
    return rows


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    raw = sys.argv[1]
    RESULTS.mkdir(exist_ok=True)
    with open(RESULTS / "per-op.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["bench", "cell", "impl", "side", "rep", "n", "instructions_n", "instructions_0"])
        w.writerows(per_op_rows(raw))
    with open(RESULTS / "whole-process.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["workload", "side", "rep", "exit", "instructions", "detail"])
        w.writerows(whole_rows(raw))


if __name__ == "__main__":
    main()
