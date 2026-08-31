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


def pick(runs, **cond):
    out = [r for r in runs if all(r["params"][k] == v for k, v in cond.items())]
    return sorted(out, key=lambda r: (r["params"]["encoding"], r["params"]["players"], r["params"]["monster_cap"]))


def row(r, per_player=False):
    m, p = r["metrics"], r["params"]
    cells = [
        ENCODING_LABEL[p["encoding"]],
        str(p["players"]),
        str(p["monster_cap"]),
        str(m["final_monster_count"]),
        f"{m['bytes_per_sync']:.0f}",
    ]
    if per_player:
        cells.append(f"{m['bytes_per_player_per_sync']:.0f}")
    return "| " + " | ".join(cells) + " |"


HDR = "| Format | players | monster cap | final monsters | bytesPerSync |"
SEP = "|---|---:|---:|---:|---:|"
HDR_PP = HDR + " bytes/player |"
SEP_PP = SEP + "---:|"


def tables(runs) -> str:
    out = []

    out.append("### Monster axis (idle, players = 5)\n")
    out.append(HDR); out.append(SEP)
    out.extend(row(r) for r in pick(runs, workload="idle", players=5))

    out.append("\n### Player axis — idle players (monster cap = 4)\n")
    out.append(HDR_PP); out.append(SEP_PP)
    out.extend(row(r, True) for r in pick(runs, workload="idle", monster_cap=4))

    out.append("\n### Player axis — active players (monster cap = 4)\n")
    out.append(HDR_PP); out.append(SEP_PP)
    out.extend(row(r, True) for r in pick(runs, workload="active", monster_cap=4))

    out.append("\n### Joint cell — active, players and monsters raised together\n")
    out.append(HDR_PP); out.append(SEP_PP)
    joint = pick(runs, workload="active", players=20, monster_cap=4) + \
            pick(runs, workload="active", players=20, monster_cap=20)
    out.extend(row(r, True) for r in sorted(joint, key=lambda r: (r["params"]["encoding"], r["params"]["monster_cap"])))

    out.append("\n### Marginal payload cost per monster (idle, players = 5, cap 4 → 100)\n")
    out.append("| Format | bytes/monster |")
    out.append("|---|---:|")
    by = {(r["params"]["encoding"], r["params"]["monster_cap"]): r["metrics"]["bytes_per_sync"]
          for r in pick(runs, workload="idle", players=5)}
    for enc in ("json-object", "messagepack-pathhash"):
        out.append(f"| {ENCODING_LABEL[enc]} | {(by[(enc, 100)] - by[(enc, 4)]) / 96.0:.1f} |")

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
