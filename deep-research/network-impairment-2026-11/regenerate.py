#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from results/*.json.

No arguments (or --markdown): print the tables. --check: print OK or MISMATCH against README's
## Results section, exit 0 or 1. Stdlib only. The tables use analysis.py's definitions (§ 5 of
Notes/plans/2026-11-07-network-impairment-experiment-design.md).
"""
import argparse
import json
import pathlib
import statistics
import sys

import analysis as a

HERE = pathlib.Path(__file__).parent


def load_runs() -> dict[str, dict]:
    return {p.stem: json.loads(p.read_text()) for p in sorted((HERE / "results").glob("*.json"))}


def cell_of(run: dict) -> tuple:
    """Runs of one cell share a load point and a population; P0's repeats are its control."""
    return (run["params"]["rooms"], run["params"]["population"])


def quiet_windows(run: dict, group: str) -> list[dict]:
    """P0's quiet windows for the band: its baseline and impaired segments."""
    return [w for w in run["groups"][group]["windows"] if w["segment"] in ("baseline", "impaired")]


def group_recovery(run: dict, group: str, edges: dict) -> int | None:
    g = run["groups"][group]
    recovery = [w for w in g["windows"] if w["segment"] == "recovery"]
    send_target = (g.get("sendTargetPerS") or 0) * a.WINDOW_MS / 1000
    states = [a.health(w, g["target"], send_target, edges) for w in recovery]
    return a.recovery_ms(states, [w["start"] for w in recovery], run["timeline"]["liftedAt"])


def recovery_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per cell, profile and group: recoveryMs per repeat against the cell's P0 band. A P0
    repeat is tested against the other two (leave-one-out): the false-positive control."""
    rows = []
    cells = sorted({cell_of(r) for r in runs.values()})
    for cell in cells:
        in_cell = {rid: r for rid, r in runs.items() if cell_of(r) == cell}
        p0 = {rid: r for rid, r in in_cell.items() if r["params"]["profile"] == "P0"}
        groups = sorted({g for r in in_cell.values() for g in r["groups"]})
        for profile in sorted({r["params"]["profile"] for r in in_cell.values()}):
            for group in groups:
                values = []
                for rid, run in sorted(in_cell.items()):
                    if run["params"]["profile"] != profile or group not in run["groups"]:
                        continue
                    controls = [quiet_windows(r, group) for cid, r in sorted(p0.items()) if cid != rid and group in r["groups"]]
                    if not controls:
                        values.append("no P0 band")
                        continue
                    values.append(group_recovery(run, group, a.band(controls)))
                rows.append((cell, profile, group, values))
    return rows


def fmt_recovery(values: list) -> str:
    finite = [v for v in values if isinstance(v, int)]
    shown = ", ".join("not recovered" if v is None else str(v) for v in values)
    median = f"{statistics.median(finite):.0f}" if finite and len(finite) == len(values) else "–"
    return f"{median} | {shown}"


def tables(runs: dict[str, dict]) -> str:
    if not runs:
        return "_No runs yet._\n"
    out = [
        "### Recovery (recoveryMs, from the lift)",
        "",
        "| rooms | population | profile | group | median | per repeat |",
        "|---|---|---|---|---|---|",
    ]
    for (rooms, population), profile, group, values in recovery_rows(runs):
        out.append(f"| {rooms} | {population} | {profile} | {group} | {fmt_recovery(values)} |")
    return "\n".join(out) + "\n"


def results_section(readme: str) -> str:
    if "## Results" not in readme:
        print("README.md has no '## Results' section", file=sys.stderr)
        sys.exit(1)
    body = readme.split("## Results", 1)[1]
    body = body.split("\n## ", 1)[0]
    return body.strip("\n") + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--markdown", action="store_true")
    args = parser.parse_args()
    generated = tables(load_runs())
    if args.check:
        readme = (HERE / "README.md").read_text()
        ok = results_section(readme) == generated
        print("OK" if ok else "MISMATCH")
        return 0 if ok else 1
    sys.stdout.write(generated)
    return 0


if __name__ == "__main__":
    sys.exit(main())
