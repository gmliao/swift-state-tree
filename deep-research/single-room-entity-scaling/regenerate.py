#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from results/*.json."""
import argparse
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).parent

ENCODING_LABEL = {
    "json-object": "JSON Object",
    "messagepack-pathhash": "Opcode MsgPack (PathHash)",
}


def load_runs():
    return [json.loads(p.read_text()) for p in sorted((HERE / "results").glob("*.json"))]


def fmt_row(r):
    m = r["metrics"]
    return (
        f"| {ENCODING_LABEL[r['params']['encoding']]} "
        f"| {r['params']['players']} "
        f"| {r['params']['monster_cap']} "
        f"| {m['final_monster_count']} "
        f"| {m['bytes_per_sync']:.0f} "
        f"| {m['bytes_per_sync_serial']:.0f} |"
    )


HEADER = (
    "| Format | players | monster cap | final monsters | bytesPerSync (parallel) | bytesPerSync (serial) |\n"
    "|---|---:|---:|---:|---:|---:|"
)


def tables(runs) -> str:
    out = []

    out.append("### Monster axis (players = 5)\n")
    out.append(HEADER)
    rows = [r for r in runs if r["params"]["players"] == 5]
    rows.sort(key=lambda r: (r["params"]["encoding"], r["params"]["monster_cap"]))
    out.extend(fmt_row(r) for r in rows)

    out.append("\n### Player axis (monster cap = 4)\n")
    out.append(HEADER)
    rows = [r for r in runs if r["params"]["monster_cap"] == 4]
    rows.sort(key=lambda r: (r["params"]["encoding"], r["params"]["players"]))
    out.extend(fmt_row(r) for r in rows)

    out.append("\n### Marginal payload cost per monster (parallel, relative to cap=4)\n")
    out.append("| Format | cap range | bytes/monster |")
    out.append("|---|---|---:|")
    by = {}
    for r in runs:
        if r["params"]["players"] == 5:
            by[(r["params"]["encoding"], r["params"]["monster_cap"])] = r["metrics"]["bytes_per_sync"]
    for enc in ("json-object", "messagepack-pathhash"):
        lo, hi = by[(enc, 4)], by[(enc, 100)]
        out.append(f"| {ENCODING_LABEL[enc]} | 4 → 100 | {(hi - lo) / 96.0:.1f} |")

    return "\n".join(out) + "\n"


def results_section(readme: str) -> str:
    if "## Results" not in readme:
        print("README.md has no '## Results' section", file=sys.stderr)
        sys.exit(1)
    start = readme.index("## Results")
    end = readme.find("\n## ", start + 1)
    body = readme[start:end if end != -1 else None]
    return body.split("\n", 1)[1].strip() + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--markdown", action="store_true", help="Equivalent to no arguments; kept for explicitness.")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    t = tables(load_runs())
    if a.check:
        current = results_section((HERE / "README.md").read_text())
        if current.strip() != t.strip():
            print("MISMATCH")
            print("README.md ## Results does not match regenerated tables", file=sys.stderr)
            sys.exit(1)
        print("OK")
    else:
        print(t, end="")


if __name__ == "__main__":
    main()
