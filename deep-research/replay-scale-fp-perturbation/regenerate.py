#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from results/*.json.

Also regenerates one re-measurement table per record format from results/batch-<format>-*.json
(`## Re-measurement at record format <format>`, e.g. 2.5 and 3.0); `--check` compares every section,
and checks that every batch of a format lists that format's per-file sha256
(batch-<format>-SHA256SUMS.txt), that a summary-only batch has the same totals as the
per-recording batch it names, and that a per-recording batch is complete: all 41 recordings, each
in the format its file name gives, and each second recording (run-batch.sh TWICE=1) byte-identical.
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).parent


BATCH_RECORDINGS = 41  # scripts/run-batch.sh's seeds


def batch_heading(fmt):
    return f"## Re-measurement at record format {fmt}"


def load_runs():
    return [json.loads(p.read_text()) for p in sorted((HERE / "results").glob("*.json"))
            if not p.name.startswith("batch-")]


def load_batches(results=None):
    """{format: [batch, ...]} from results/batch-<format>-*.json, in file-name order."""
    by_format = {}
    for p in sorted((results or HERE / "results").glob("batch-*.json")):
        m = re.fullmatch(r"batch-(\d+(?:\.\d+)*)-.+\.json", p.name)
        if m:
            by_format.setdefault(m.group(1), []).append(dict(json.loads(p.read_text()), _file=p.name))
    return by_format


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


def check_batches(fmt, batches, results=None) -> list:
    """Cross-batch checks for one format: every batch's SHA256SUMS hash equals the committed
    list's, a summary-only batch names a per-recording batch whose totals equal its own, and a
    per-recording batch is complete (see the module docstring)."""
    errors = []
    sums_file = (results or HERE / "results") / f"batch-{fmt}-SHA256SUMS.txt"
    if not sums_file.exists():
        return [f"{sums_file.name} missing"]
    sums = hashlib.sha256(sums_file.read_bytes()).hexdigest()
    by_name = {b["_file"]: b for b in batches}
    for b in batches:
        if b["meta"].get("record_format") != fmt:
            errors.append(f"{b['_file']}: record_format {b['meta'].get('record_format')}, its name says {fmt}")
        if "recordings" in b and fmt != "2.5":  # the 2.5 batch predates these fields
            recs = b["recordings"]
            if len(recs) != BATCH_RECORDINGS:
                errors.append(f"{b['_file']}: {len(recs)} recordings, the batch is {BATCH_RECORDINGS}")
            for key, text in (("record_exit", "record exit"), ("verify_exit", "verify exit")):
                bad = [r["seed"] for r in recs if r[key] != 0]
                if bad:
                    errors.append(f"{b['_file']}: nonzero {text} for seeds {bad}")
            unchecked = [r["seed"] for r in recs if "second_recording_identical" not in r]
            if unchecked:
                errors.append(f"{b['_file']}: no second recording for seeds {unchecked} (run-batch.sh TWICE=1)")
            differ = [r["seed"] for r in recs if r.get("second_recording_identical") is False]
            if differ:
                errors.append(f"{b['_file']}: second recording differs for seeds {differ}")
        if b["meta"]["sha256sums_sha256"] != sums:
            errors.append(f"{b['_file']}: sha256sums_sha256 differs from {sums_file.name} ({sums})")
        ref = b.get("per_recording_identical_to")
        if ref is not None:
            if ref not in by_name:
                errors.append(f"{b['_file']}: per_recording_identical_to {ref} not found")
            elif batch_totals(by_name[ref]) != batch_totals(b):
                errors.append(f"{b['_file']}: totals differ from {ref}")
    return errors


def batch_table(batches) -> str:
    """The machine table of one format's re-measurement, one row per batch file."""
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
        readme = (HERE / "README.md").read_text()
        for fmt, batches in load_batches().items():
            heading = batch_heading(fmt)
            if heading not in readme:
                print("MISMATCH")
                print(f"README.md has no '{heading}' section", file=sys.stderr)
                sys.exit(1)
            if section_table(readme, heading).strip() != batch_table(batches).strip():
                print("MISMATCH")
                print(f"README.md {heading} table does not match results/batch-{fmt}-*.json", file=sys.stderr)
                sys.exit(1)
            errors = check_batches(fmt, batches)
            if errors:
                print("MISMATCH")
                for e in errors:
                    print(e, file=sys.stderr)
                sys.exit(1)
        print("OK")
    else:
        print(t, end="")
        for fmt, batches in load_batches().items():
            print(f"\n{batch_heading(fmt)}\n")
            print(batch_table(batches), end="")


if __name__ == "__main__":
    main()
