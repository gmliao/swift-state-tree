#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from results/*.json.

Also regenerates the record-format-2.5 re-measurement table from results/batch-2.5-*.json
(`## Re-measurement at record format 2.5`); `--check` compares both sections, and checks that
every 2.5 batch lists the same per-file sha256 (batch-2.5-SHA256SUMS.txt) and that a
summary-only batch has the same totals as the per-recording batch it names.
"""
import argparse
import hashlib
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).parent


BATCH_25_HEADING = "## Re-measurement at record format 2.5"


def load_runs():
    return [json.loads(p.read_text()) for p in sorted((HERE / "results").glob("*.json"))
            if not p.name.startswith("batch-")]


def load_batches_25():
    return [dict(json.loads(p.read_text()), _file=p.name)
            for p in sorted((HERE / "results").glob("batch-2.5-*.json"))]


def batch_totals(b) -> dict:
    """A batch's totals: summed from its recordings, or given (a summary-only batch file)."""
    if "totals" in b:
        return b["totals"]
    recs = b["recordings"]
    return {
        "recordings": len(recs),
        "verified_vs_recorded": sum(1 for r in recs if r["verified_vs_recorded"]),
        "verified_run1_vs_run2": sum(1 for r in recs if r["verified_run1_vs_run2"]),
        "mismatch_ticks": sum(r["mismatch_ticks"] for r in recs),
        "ticks": sum(r["ticks"] for r in recs),
        "ticks_with_state_hash": sum(r["ticks_with_state_hash"] for r in recs),
        "client_events": sum(r["client_events"] for r in recs),
        "actions": sum(r["actions"] for r in recs),
    }


def check_batches_25(batches) -> list:
    """Cross-batch checks: every batch's SHA256SUMS hash equals the committed list's, and a
    summary-only batch names a per-recording batch whose totals equal its own."""
    errors = []
    sums = hashlib.sha256((HERE / "results" / "batch-2.5-SHA256SUMS.txt").read_bytes()).hexdigest()
    by_name = {b["_file"]: b for b in batches}
    for b in batches:
        if b["meta"]["sha256sums_sha256"] != sums:
            errors.append(f"{b['_file']}: sha256sums_sha256 differs from batch-2.5-SHA256SUMS.txt ({sums})")
        ref = b.get("per_recording_identical_to")
        if ref is not None:
            if ref not in by_name:
                errors.append(f"{b['_file']}: per_recording_identical_to {ref} not found")
            elif batch_totals(by_name[ref]) != batch_totals(b):
                errors.append(f"{b['_file']}: totals differ from {ref}")
    return errors


def batch_25_table(batches) -> str:
    """The machine table of the 2.5 re-measurement, one row per batch file."""
    out = ["| machine | arch | swift | build | recordings | verified vs recorded | run1 == run2 | tick mismatches | ticks | client events | actions |",
           "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for b in batches:
        m, t = b["meta"], batch_totals(b)
        n = t["recordings"]
        out.append("| {} | {} | {} | {} | {} | {}/{} | {}/{} | {} | {:,} | {:,} | {} |".format(
            m["host"], m["arch"], m["swift"], m["build"], n,
            t["verified_vs_recorded"], n, t["verified_run1_vs_run2"], n,
            t["mismatch_ticks"], t["ticks"], t["client_events"], t["actions"],
        ))
    return "\n".join(out) + "\n"


def section_table(readme: str, heading: str) -> str:
    """The first Markdown table in the section under `heading`."""
    start = readme.index(heading)
    end = readme.find("\n## ", start + 1)
    lines = readme[start:end if end != -1 else None].split("\n")
    rows = [l for l in lines if l.startswith("|")]
    first = lines.index(rows[0])
    table = []
    for l in lines[first:]:
        if not l.startswith("|"):
            break
        table.append(l)
    return "\n".join(table) + "\n"


def tables(runs) -> str:
    out = []
    recs = sorted((r for r in runs if r["params"].get("workload") == "record-verify"),
                  key=lambda r: (r["params"]["ticks"], r["params"]["players"], r["params"]["move_every"], r["params"]["seed"]))
    perts = [r for r in runs if r["params"].get("workload") == "perturbed-replay"]
    crossarch = sorted((r for r in runs if r["params"].get("recorded_on")),
                       key=lambda r: r["meta"]["arch"])

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

    if crossarch:
        out.append("\n### Cross-architecture verification — replay the arm64-recorded batch elsewhere\n")
        out.append("| arch | host | swift | recordings | pass | fail |")
        out.append("|---|---|---|---:|---:|---:|")
        for r in crossarch:
            m = r["meta"]
            host = ", ".join(p.strip() for p in m["host"].split(",")[:2])
            swift = m["swift_version"].split()[2] if m["swift_version"].startswith("Swift version") else m["swift_version"]
            out.append(f"| {m['arch']} | {host} | {swift} | {r['params']['recordings']} | {r['metrics']['pass']} | {r['metrics']['fail']} |")

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
        batches = load_batches_25()
        if batches:
            readme = (HERE / "README.md").read_text()
            if BATCH_25_HEADING not in readme:
                print("MISMATCH")
                print(f"README.md has no '{BATCH_25_HEADING}' section", file=sys.stderr)
                sys.exit(1)
            if section_table(readme, BATCH_25_HEADING).strip() != batch_25_table(batches).strip():
                print("MISMATCH")
                print(f"README.md {BATCH_25_HEADING} table does not match results/batch-2.5-*.json", file=sys.stderr)
                sys.exit(1)
            errors = check_batches_25(batches)
            if errors:
                print("MISMATCH")
                for e in errors:
                    print(e, file=sys.stderr)
                sys.exit(1)
        print("OK")
    else:
        print(t, end="")
        batches = load_batches_25()
        if batches:
            print(f"\n{BATCH_25_HEADING}\n")
            print(batch_25_table(batches), end="")


if __name__ == "__main__":
    main()
