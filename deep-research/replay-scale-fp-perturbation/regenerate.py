#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from results/*.json."""
import argparse
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).parent


def load_runs():
    return [json.loads(p.read_text()) for p in sorted((HERE / "results").glob("*.json"))]


def tables(runs) -> str:
    out = []
    recs = sorted((r for r in runs if r["params"]["workload"] == "record-verify"),
                  key=lambda r: (r["params"]["ticks"], r["params"]["players"], r["params"]["move_every"], r["params"]["seed"]))
    perts = [r for r in runs if r["params"]["workload"] == "perturbed-replay"]

    out.append("### Part A — replay verification at scale (aggregate)\n")
    out.append("| recordings | total ticks | total actions | total client events | hash mismatches | verified vs recorded | run1 == run2 |")
    out.append("|---:|---:|---:|---:|---:|---:|---:|")
    out.append("| {} | {} | {} | {} | {} | {}/{} | {}/{} |".format(
        len(recs),
        sum(r["metrics"]["total_ticks"] for r in recs),
        sum(r["metrics"]["total_actions"] for r in recs),
        sum(r["metrics"]["total_client_events"] for r in recs),
        sum(r["metrics"]["mismatch_ticks"] for r in recs),
        sum(1 for r in recs if r["metrics"]["verified_vs_recorded"]), len(recs),
        sum(1 for r in recs if r["metrics"]["verified_run1_vs_run2"]), len(recs),
    ))

    out.append("\n### Part A — per recording\n")
    out.append("| seed | players | move every | ticks | actions | client events | hash mismatches | verified |")
    out.append("|---:|---:|---:|---:|---:|---:|---:|---|")
    for r in recs:
        m, q = r["metrics"], r["params"]
        ok = "yes" if (m["verified_vs_recorded"] and m["verified_run1_vs_run2"]) else "NO"
        out.append(f"| {q['seed']} | {q['players']} | {q['move_every']} | {m['total_ticks']} | {m['total_actions']} | {m['total_client_events']} | {m['mismatch_ticks']} | {ok} |")

    out.append("\n### Part B — perturbation sensitivity (perturb at tick 600, 10 recordings each)\n")
    out.append("| mode | eps | detected | detection latency (ticks) |")
    out.append("|---|---|---:|---|")
    for mode, eps, label in (("float", 1e-7, "float +1e-7 (sub-LSB, pre-quantization)"),
                             ("fixed", 1.0, "fixed +1 LSB (0.001 world units)"),
                             ("fixed", 1000.0, "fixed +1000 LSB (1.0 world unit)")):
        cell = [r for r in perts if r["params"]["mode"] == mode and r["params"]["eps"] == eps]
        det = [r for r in cell if r["metrics"]["detected"]]
        lat = sorted(r["metrics"]["detection_latency_ticks"] for r in det)
        lat_s = f"min {lat[0]} / max {lat[-1]}" if lat else "—"
        out.append(f"| {label} | {eps:g} | {len(det)}/{len(cell)} | {lat_s} |")

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
