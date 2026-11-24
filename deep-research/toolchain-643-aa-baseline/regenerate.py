#!/usr/bin/env python3
"""Regenerate the tables in README.md from results/*.csv (stdlib only).

Usage: python3 regenerate.py [--markdown] | python3 regenerate.py --check

Per op = (instructions(n) - instructions(0)) / n for one rep. A side's value is the mean of its
reps; its spread is (max - min) / mean. B vs A = (B - A) / A. A cell's class:
- "not measurable": |mean| < 1 instruction per op on either side (the loop was optimized away);
- "tight": both spreads and |B vs A| at most 0.05 %;
- "noisy": anything else; its floor is the largest of the two spreads and |B vs A|.
"""
import argparse
import csv
import pathlib
import statistics
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
RESULTS = TOPIC / "results"
README = TOPIC / "README.md"
BEGIN, END = "<!-- BEGIN generated tables -->", "<!-- END generated tables -->"
TIGHT = 0.0005


def load(name):
    with open(RESULTS / name, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def stats(values):
    mean = statistics.mean(values)
    return mean, (max(values) - min(values)) / mean if mean else float("inf")


def classify(a, b):
    (ma, sa), (mb, sb) = a, b
    if abs(ma) < 1 or abs(mb) < 1:
        return "not measurable", None
    delta = (mb - ma) / ma
    floor = max(sa, sb, abs(delta))
    return ("tight" if floor <= TIGHT else "noisy"), floor


def pct(x):
    return f"{x:.3%}"


def per_op_table(rows, bench):
    cells = {}
    for r in rows:
        if r["bench"] != bench:
            continue
        per_op = (int(r["instructions_n"]) - int(r["instructions_0"])) / int(r["n"])
        cells.setdefault((r["cell"], r["impl"]), {}).setdefault(r["side"], []).append(per_op)
    out = [f"| cell | impl | n | A instr/op | A spread | B instr/op | B spread | B vs A | class | floor |",
           "|---|---|---:|---:|---:|---:|---:|---:|---|---:|"]
    ns = {(r["cell"], r["impl"]): r["n"] for r in rows if r["bench"] == bench}
    for (cell, impl), sides in sorted(cells.items()):
        if len(sides.get("A", [])) != 5 or len(sides.get("B", [])) != 5:
            sys.exit(f"regenerate: {bench} {cell} {impl} lacks 5 reps per side")
        a, b = stats(sides["A"]), stats(sides["B"])
        cls, floor = classify(a, b)
        if cls == "not measurable":
            out.append(f"| {cell} | {impl} | {ns[(cell, impl)]} | {a[0]:,.2f} | n/a | {b[0]:,.2f} | n/a | n/a | {cls} | n/a |")
            continue
        delta = (b[0] - a[0]) / a[0]
        out.append(f"| {cell} | {impl} | {ns[(cell, impl)]} | {a[0]:,.2f} | {pct(a[1])} | {b[0]:,.2f} | {pct(b[1])} "
                   f"| {delta:+.3%} | {cls} | {pct(floor)} |")
    return "\n".join(out)


def whole_table(rows):
    out = ["| workload | A instructions | A spread | B instructions | B spread | B vs A | exit codes | detail |",
           "|---|---:|---:|---:|---:|---:|---|---|"]
    for workload in ("EncodingBenchmark", "ServerLoadTest"):
        sel = [r for r in rows if r["workload"] == workload]
        a = stats([int(r["instructions"]) for r in sel if r["side"] == "A"])
        b = stats([int(r["instructions"]) for r in sel if r["side"] == "B"])
        exits = sorted({r["exit"] for r in sel})
        details = sorted({r["detail"] for r in sel})
        label = "bytesPerSync " if workload == "EncodingBenchmark" else ""
        out.append(f"| {workload} | {a[0]:,.0f} | {pct(a[1])} | {b[0]:,.0f} | {pct(b[1])} | {(b[0] - a[0]) / a[0]:+.3%} "
                   f"| {', '.join(exits)} | {label}{', '.join(details)} |")
    return "\n".join(out)


def markdown():
    per_op = load("per-op.csv")
    whole = load("whole-process.csv")
    return "\n\n".join([
        "### TurnsBench (instructions:u per op)", per_op_table(per_op, "TurnsBench"),
        "### TurnsMailboxBench (instructions:u per op)", per_op_table(per_op, "TurnsMailboxBench"),
        "### Whole process (instructions:u per run, 5 runs per side)", whole_table(whole),
    ])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if README.md's tables differ")
    parser.add_argument("--markdown", action="store_true", help="print the tables")
    args = parser.parse_args()
    tables = markdown()
    text = README.read_text(encoding="utf-8")
    start, end = text.find(BEGIN), text.find(END)
    if start < 0 or end < start:
        sys.exit("regenerate: README.md has no generated-tables block")
    current = text[start + len(BEGIN):end].strip("\n")
    if args.check:
        if current != tables:
            sys.exit("regenerate: README.md's tables differ from results/; run regenerate.py")
        print("regenerate: README.md matches results/")
        return
    if args.markdown:
        print(tables)
        return
    README.write_text(text[:start + len(BEGIN)] + "\n" + tables + "\n" + text[end:], encoding="utf-8")
    print("regenerate: README.md updated")


if __name__ == "__main__":
    main()
