#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from results/*.json.

Also regenerates one re-measurement table per record format from results/batch-<format>-*.json
(`## Re-measurement at record format <format>`, e.g. 2.5 and 3.0); `--check` compares every section,
and checks that every batch of a format lists that format's per-file sha256
(batch-<format>-SHA256SUMS.txt), that a summary-only batch has the same totals as the
per-recording batch it names, and that a per-recording batch is complete: all 41 recordings, each
in the format its file name gives, and each second recording (run-batch.sh TWICE=1) identical: by
content (the JSON view's sha256) from the 3.0 batches on, by bytes in the 2.4 and 2.5 batches.

Also regenerates the tables of `## Part B at record format 3.1 (full-state hash)` from
results/perturb-3.1/ (scripts/perturb_collect.py's output); `--check` compares them and refuses a set
that isn't every cell × seeds 1-10 on the 3.1 batch's own recordings (batch-3.1-SHA256SUMS.txt),
with both controls 10/10 and every run read as detected (exit 5) or verified (exit 0).
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
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted((HERE / "results").glob("*.json"))
            if not p.name.startswith(("batch-", "crossverify-"))]


def load_batches(results=None):
    """{format: [batch, ...]} from results/batch-<format>-*.json, in file-name order."""
    by_format = {}
    for p in sorted((results or HERE / "results").glob("batch-*.json")):
        m = re.fullmatch(r"batch-(\d+(?:\.\d+)*)-.+\.json", p.name)
        if m:
            by_format.setdefault(m.group(1), []).append(dict(json.loads(p.read_text(encoding="utf-8")), _file=p.name))
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
            meta = b["meta"]
            if not re.fullmatch(r"[0-9a-f]{7,40}", str(meta.get("git_sha") or "")) or meta.get("git_dirty") is not False:
                errors.append(f"{b['_file']}: commit {meta.get('git_sha')!r}, dirty {meta.get('git_dirty')!r}: "
                              "a batch needs the clean commit run-batch.sh recorded (source.json)")
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
    """The machine table of one format's re-measurement, one row per batch file, with each batch's
    commit and tree as its meta records them (from 3.0 on: source.json, through summarize.py; a
    machine's batch is its own commit, so the rows can differ). "second recording byte-identical"
    counts the recordings whose second recording on the same machine (run-batch.sh TWICE=1) has
    the same bytes, from `second_recording_bytes_identical`; a batch without the field (2.5) shows
    "not recorded"."""
    out = ["| machine | arch | commit | tree | swift | build | recordings | verified vs recorded | run1 == run2 | second recording byte-identical | tick mismatches | ticks | client events | actions |",
           "|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for b in batches:
        m, t = b["meta"], batch_totals(b)
        n = t["recordings"]
        tree = {False: "clean", True: "dirty"}.get(m.get("git_dirty"), "not recorded")
        recs = b.get("recordings") or []
        if recs and all("second_recording_bytes_identical" in r for r in recs):
            same_bytes = f"{sum(1 for r in recs if r['second_recording_bytes_identical'])}/{len(recs)}"
        else:
            same_bytes = "not recorded"
        out.append("| {} | {} | `{}` | {} | {} | {} | {} | {}/{} | {}/{} | {} | {} | {:,} | {:,} | {} |".format(
            m["host"], m["arch"], m.get("git_sha") or "not recorded", tree, m["swift"], m["build"], n,
            t["verified_vs_recorded"], n, t["verified_run1_vs_run2"], n, same_bytes,
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


PERTURB31 = HERE / "results" / "perturb-3.1"
PERTURB31_HEADING = "## Part B at record format 3.1 (full-state hash)"
PERTURB31_SEEDS = list(range(1, 11))
PERTURB31_TICK = 600
# (mode, eps as passed) in table order; the server-only cell is the runner at its own commit.
PERTURB31_CELLS = [("float", "1e-07"), ("fixed", "1.0"), ("fixed", "1000.0"), ("serveronly", "1")]


def load_perturb31(directory=None):
    """(runs, controls) from results/perturb-3.1/ (scripts/perturb_collect.py's output)."""
    d = directory or PERTURB31
    runs = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(d.glob("perturb-*.json"))]
    controls = json.loads((d / "controls.json").read_text(encoding="utf-8"))
    return runs, controls


def recorded_sums(results=None) -> dict:
    """{file name: sha256} from the 3.1 batch's SHA256SUMS: the recordings Part B 3.1 replayed."""
    text = ((results or HERE / "results") / "batch-3.1-SHA256SUMS.txt").read_text(encoding="utf-8")
    return {name: sha for sha, name in (line.split() for line in text.splitlines() if line.strip())}


def check_perturb31(runs, controls, sums, batch_sha) -> list:
    """Every cell × seed once, on the 3.1 batch's own recordings, read by one rule; both controls
    10/10 exit 0 with both verification lines; each run's runner is its control's; the matrix ran
    on the batch's commit and the server-only cell on the other runner."""
    errors = []
    runner_of = {}
    for r in controls["runners"]:
        runner_of[r["git_sha"]] = r["runner_sha256"]
        seeds = sorted(x["seed"] for x in r["runs"])
        if seeds != PERTURB31_SEEDS:
            errors.append(f"control {r['git_sha']}: seeds {seeds}")
        for x in r["runs"]:
            if (x["exit"], x["verified_lines"]) != (0, 2):
                errors.append(f"control {r['git_sha']} s{x['seed']}: exit {x['exit']}, {x['verified_lines']} verification lines")
            if sums.get(f"s{x['seed']}.sstr") != x["recording_sha256"]:
                errors.append(f"control {r['git_sha']} s{x['seed']}: recording isn't the 3.1 batch's")
    if len(runner_of) != 2:
        errors.append(f"controls name {len(runner_of)} runners, expected 2")
    cells = {}
    for r in runs:
        p, m, meta = r["params"], r["metrics"], r["meta"]
        key = (p["mode"], p["eps"])
        cells.setdefault(key, []).append(p["seed"])
        name = f"{p['mode']} {p['eps']} s{p['seed']}"
        if key not in PERTURB31_CELLS:
            errors.append(f"{name}: not a cell of the table")
        if runner_of.get(meta["git_sha"]) != meta["runner_sha256"]:
            errors.append(f"{name}: runner {meta['runner_sha256'][:12]} isn't its control's at {meta['git_sha']}")
        if sums.get(f"s{p['seed']}.sstr") != p["recording_sha256"]:
            errors.append(f"{name}: recording isn't the 3.1 batch's")
        if p["perturb_tick"] != PERTURB31_TICK:
            errors.append(f"{name}: perturb tick {p['perturb_tick']}")
        if m["exit"] == 0:
            if m["detected"] or m["verified_lines"] != 2:
                errors.append(f"{name}: exit 0 needs both verification lines and no detection")
        elif m["exit"] == 5:
            if not m["detected"] or m["detection_latency_ticks"] != m["first_mismatch_tick"] - PERTURB31_TICK \
                    or not m["mismatch_ticks"]:
                errors.append(f"{name}: exit 5 needs a first mismatching tick and a mismatch count")
        else:
            errors.append(f"{name}: exit {m['exit']} is neither detected (5) nor verified (0)")
    for key in PERTURB31_CELLS:
        if sorted(cells.get(key, [])) != PERTURB31_SEEDS:
            errors.append(f"{key[0]} {key[1]}: seeds {sorted(cells.get(key, []))}")
    commits = {key: {r["meta"]["git_sha"] for r in runs if (r["params"]["mode"], r["params"]["eps"]) == key}
               for key in PERTURB31_CELLS}
    if any(len(c) != 1 for c in commits.values()):
        errors.append(f"a cell ran on more than one runner: {commits}")
    else:
        matrix = {c for key, cs in commits.items() if key[0] != "serveronly" for c in cs}
        serveronly = commits[("serveronly", "1")]
        if matrix != {batch_sha}:
            errors.append(f"the matrix ran at {sorted(matrix)}, the 3.1 batch at {batch_sha}")
        if serveronly & matrix:
            errors.append("the server-only cell ran on the matrix's runner")
    return errors


def perturb31_tables(runs, controls) -> list:
    """The section's tables, in order: the summary in the 2026-08-31 shape plus mismatch ticks and
    the runner's commit, the controls, and every run."""
    def span(values):
        return f"{min(values)} / {max(values)}" if values else "—"

    summary = ["| mode | eps | runner | detected | detection latency (ticks) min / max | mismatch ticks min / max |",
               "|---|---|---|---:|---|---|"]
    for mode, eps in PERTURB31_CELLS:
        cell = [r for r in runs if (r["params"]["mode"], r["params"]["eps"]) == (mode, eps)]
        det = [r["metrics"] for r in cell if r["metrics"]["detected"]]
        summary.append(f"| {mode} | {eps} | `{cell[0]['meta']['git_sha']}` | {len(det)}/{len(cell)} | "
                       f"{span([m['detection_latency_ticks'] for m in det])} | {span([m['mismatch_ticks'] for m in det])} |")

    ctl = ["| runner | runner sha256 | recordings | exit 0 with both verification lines |", "|---|---|---:|---:|"]
    for r in controls["runners"]:
        ok = sum(1 for x in r["runs"] if (x["exit"], x["verified_lines"]) == (0, 2))
        ctl.append(f"| `{r['git_sha']}` | `{r['runner_sha256']}` | {len(r['runs'])} | {ok}/{len(r['runs'])} |")

    order = {key: i for i, key in enumerate(PERTURB31_CELLS)}
    per_run = ["| seed | mode | eps | runner | exit | detected | first mismatch tick | latency (ticks) | mismatch ticks |",
               "|---:|---|---|---|---:|---|---:|---:|---:|"]
    for r in sorted(runs, key=lambda r: (order[(r["params"]["mode"], r["params"]["eps"])], r["params"]["seed"])):
        p, m = r["params"], r["metrics"]
        dash = lambda v: "—" if v is None else v  # noqa: E731
        per_run.append(f"| {p['seed']} | {p['mode']} | {p['eps']} | `{r['meta']['git_sha']}` | {m['exit']} | "
                       f"{'yes' if m['detected'] else 'no'} | {dash(m['first_mismatch_tick'])} | "
                       f"{dash(m['detection_latency_ticks'])} | {dash(m['mismatch_ticks'])} |")
    return ["\n".join(t) + "\n" for t in (summary, ctl, per_run)]


CROSSARCH31_HEADING = "## Cross-architecture at record format 3.1"


def load_crossverify31(results=None) -> list:
    """results/crossverify-3.1-<runner arch>.json (scripts/crossverify_collect.py): one machine's
    runner replaying the other machine's 3.1 recordings."""
    return [json.loads(p.read_text(encoding="utf-8"))
            for p in sorted((results or HERE / "results").glob("crossverify-3.1-*.json"))]


def check_crossarch31(batches, verifies) -> list:
    """The 3.1 batches: one per architecture, each complete, all at one commit. A cross-verify: at
    that commit, in the batch's record format, replaying every recording that another machine's
    batch recorded (by seed, by sha256), with one entry per seed."""
    errors = []
    by_arch = {b["meta"]["arch"]: b for b in batches}
    if len(by_arch) != len(batches) or len(by_arch) < 2:
        return [f"3.1 batches: {sorted(b['meta']['arch'] for b in batches)}, expected one per architecture, at least two"]
    commits = {b["meta"]["git_sha"] for b in batches}
    if len(commits) != 1:
        errors.append(f"3.1 batches at {sorted(commits)}, expected one commit")
    for v in verifies:
        m = v["meta"]
        name = f"crossverify-3.1-{m['arch']}.json"
        source = by_arch.get(m["recorded_on"])
        if source is None or m["recorded_on"] == m["arch"]:
            errors.append(f"{name}: recorded_on {m['recorded_on']!r} is not another architecture's batch")
            continue
        if m["git_sha"] not in commits or m["record_format"] != "3.1":
            errors.append(f"{name}: commit {m['git_sha']}, format {m['record_format']}; the batches are {sorted(commits)}, 3.1")
        want = {r["seed"]: r["sha256"] for r in source["recordings"]}
        got = {r["seed"]: r["recording_sha256"] for r in v["recordings"]}
        if len(got) != len(v["recordings"]) or got != want:
            errors.append(f"{name}: its recordings are not {m['recorded_on']}'s batch (by seed and sha256)")
    return errors


def crossarch31_tables(batches, verifies) -> list:
    """The cross-verify (each runner on the other machine's recordings), the byte and content
    comparison, and the per-recording comparison."""
    by_arch = {b["meta"]["arch"]: b for b in batches}
    arches = sorted(by_arch)
    out = ["| runner | host | swift | commit | runner sha256 | recordings recorded on | recordings | exit 0 with both verification lines |\n"
           "|---|---|---|---|---|---|---:|---:|\n" + "".join(
               f"| {m['arch']} | {m['host']} | {m['swift']} | `{m['git_sha']}` | `{m['runner_sha256']}` | {m['recorded_on']} | "
               f"{len(v['recordings'])} | {sum(r['passed'] for r in v['recordings'])}/{len(v['recordings'])} |\n"
               for v in verifies for m in [v["meta"]])]
    a, b = (by_arch[x]["recordings"] for x in arches)
    pairs = list(zip(sorted(a, key=lambda r: r["seed"]), sorted(b, key=lambda r: r["seed"])))
    n = len(pairs)
    split = " / ".join(str(sum(1 for r in by_arch[x]["recordings"] if any(r["split_ticks"]))) for x in arches)
    out.append(f"| comparison ({arches[0]} vs {arches[1]}) | recordings |\n|---|---:|\n"
               f"| byte-identical (file sha256) | {sum(x['sha256'] == y['sha256'] for x, y in pairs)}/{n} |\n"
               f"| content-identical (sha256 of the `--convert` JSON view) | {sum(x['content_sha256'] == y['content_sha256'] for x, y in pairs)}/{n} |\n"
               f"| with split ticks, {arches[0]} / {arches[1]} | {split} |\n")
    rows = [f"| seed | players | move every | ticks | sha256 ({arches[0]}) | sha256 ({arches[1]}) | bytes | content |",
            "|---:|---:|---:|---:|---|---|---|---|"]
    for x, y in pairs:
        rows.append(f"| {x['seed']} | {x['players']} | {x['move_every']} | {x['ticks']} | `{x['sha256'][:12]}` | `{y['sha256'][:12]}` | "
                    f"{'same' if x['sha256'] == y['sha256'] else 'DIFFER'} | {'same' if x['content_sha256'] == y['content_sha256'] else 'DIFFER'} |")
    out.append("\n".join(rows) + "\n")
    return out


def section_tables(readme: str, heading: str) -> list:
    """Every Markdown table in the section under `heading`, in order."""
    start = readme.index(heading)
    end = readme.find("\n## ", start + 1)
    tables, current = [], []
    for line in readme[start:end if end != -1 else None].split("\n"):
        if line.startswith("|"):
            current.append(line)
        elif current:
            tables.append("\n".join(current) + "\n")
            current = []
    if current:
        tables.append("\n".join(current) + "\n")
    return tables


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
        current = results_section((HERE / "README.md").read_text(encoding="utf-8"))
        if current.strip() != t.strip():
            print("MISMATCH")
            print("README.md ## Results does not match regenerated tables", file=sys.stderr)
            sys.exit(1)
        readme = (HERE / "README.md").read_text(encoding="utf-8")
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
        if PERTURB31_HEADING not in readme:
            print("MISMATCH")
            print(f"README.md has no '{PERTURB31_HEADING}' section", file=sys.stderr)
            sys.exit(1)
        runs, controls = load_perturb31()
        errors = check_perturb31(runs, controls, recorded_sums(), load_batches()["3.1"][0]["meta"]["git_sha"])
        if errors:
            print("MISMATCH")
            for e in errors:
                print(e, file=sys.stderr)
            sys.exit(1)
        if [x.strip() for x in section_tables(readme, PERTURB31_HEADING)] != [x.strip() for x in perturb31_tables(runs, controls)]:
            print("MISMATCH")
            print(f"README.md {PERTURB31_HEADING} tables do not match results/perturb-3.1/", file=sys.stderr)
            sys.exit(1)
        batches31, verifies = load_batches()["3.1"], load_crossverify31()
        errors = check_crossarch31(batches31, verifies)
        if errors:
            print("MISMATCH")
            for e in errors:
                print(e, file=sys.stderr)
            sys.exit(1)
        if CROSSARCH31_HEADING not in readme or [x.strip() for x in section_tables(readme, CROSSARCH31_HEADING)] != [
                x.strip() for x in crossarch31_tables(batches31, verifies)]:
            print("MISMATCH")
            print(f"README.md {CROSSARCH31_HEADING} tables do not match results/batch-3.1-*.json and crossverify-3.1-*.json", file=sys.stderr)
            sys.exit(1)
        print("OK")
    else:
        print(t, end="")
        for fmt, batches in load_batches().items():
            print(f"\n{batch_heading(fmt)}\n")
            print(batch_table(batches), end="")
        print(f"\n{PERTURB31_HEADING}\n")
        print("\n".join(perturb31_tables(*load_perturb31())), end="")
        print(f"\n{CROSSARCH31_HEADING}\n")
        print("\n".join(crossarch31_tables(load_batches()["3.1"], load_crossverify31())), end="")


if __name__ == "__main__":
    main()
