#!/usr/bin/env python3
"""Regenerate the Results section of README.md from results/ (stdlib only, plus git for gate 5).

Usage: python3 regenerate.py [--markdown] | python3 regenerate.py --check

results/*.json are the measured runs (collect.py: one per point, form and repeat) and
results/capture/*.json the capture block (one per point and form). Before any table is built,
every result must pass the README's gates:
  1. dirty tracking on and off give the same bytes, in every repeat and in the captured frames;
  2. the knobs reached the run: the recorded modes are the form's, and dynamic-key off gives more
     bytes than on at every point, in every repeat;
  3. every cell's capture passed verify-views, under deterministic hashing;
  4. every cell has the same bytes in all four repeats;
  5. mp-dt-dk's bytes equal single-room-entity-scaling's on-on form at the same point, with the
     same parameters and the same Sources tree (read from git);
  6. the run: pinned, release, clean tree, the pinned Swift, every serverenv.py variable unset,
     75222b87's Sources and Package.swift trees, one commit (provenance.py).
"""
import argparse, json, pathlib, statistics, subprocess, sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC.parent))
import provenance  # noqa: E402
import serverenv  # noqa: E402

RESULTS = TOPIC / "results"
SINGLE_ROOM_RESULTS = TOPIC.parent / "single-room-entity-scaling" / "results"
# The rerun's commit (75222b87) has these trees; the numbers sit beside the rerun's only with them.
SOURCES_TREE = "cf82bd38ae6c5c8c10a457d8422500594746902e"
PACKAGE_TREE = "ee126eb9958be962986822585e1bc929b1b89d52"
PINNED_SWIFT = "6.2.4"
REPEATS = (1, 2, 3, 4)
ORDER = {1: "forward", 2: "reverse", 3: "reverse", 4: "forward"}
# single-room-entity-scaling's matrix: cell -> (players, monster cap, workload) points.
POINTS = {
    **{f"monsters-cap{cap}": [(5, cap, "idle")] for cap in (4, 10, 50, 100)},
    "idle-players": [(p, 4, "idle") for p in (10, 20, 50)],
    "active-players": [(p, 4, "active") for p in (5, 10, 20, 50)],
    "joint": [(20, 20, "active")],
}
# Form -> (EncodingBenchmark --format, dirty tracking, dynamic-key compression); path index and
# field merge are on in every form.
FORMS = {
    "mp-dt-dk": ("messagepack-pathhash", "on", True),
    "mp-dt-nodk": ("messagepack-pathhash", "on", False),
    "mp-nodt-dk": ("messagepack-pathhash", "off", True),
    "mp-nodt-nodk": ("messagepack-pathhash", "off", False),
    "oj-dk": ("opcode-json-pathhash", "on", True),
    "oj-nodk": ("opcode-json-pathhash", "on", False),
}
FIXED = {"rooms": 1, "iterations": 200, "ticks_per_sync": 2, "parallel": "false", "sync_strategy": "delta"}
EMPTY = "_No results yet: the measurement host's run fills this section._"


def load(directory):
    runs = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(directory.glob("*.json"))]
    captures = [json.loads(p.read_text(encoding="utf-8")) for p in sorted((directory / "capture").glob("*.json"))]
    return runs, captures


def point(r):
    p = r["params"]
    return (p["players"], p["monster_cap"], p["workload"])


def run_failures(name, meta):
    """Gate 6 for one result's run record."""
    out = []
    if meta.get("git_dirty") is not False:
        out.append(f"{name}: not from a clean tree (git dirty: {meta.get('git_dirty')})")
    if PINNED_SWIFT not in (meta.get("swift_version") or ""):
        out.append(f"{name}: Swift {meta.get('swift_version')!r}, not the pinned {PINNED_SWIFT}")
    if not meta.get("pin_cpus"):
        out.append(f"{name}: unpinned (a smoke run off the measurement host)")
    if env := serverenv.failure(name, meta.get("server_env")):
        out.append(env)
    if (meta.get("sources_tree"), meta.get("package_tree")) != (SOURCES_TREE, PACKAGE_TREE):
        out.append(f"{name}: Sources/Package.swift trees {meta.get('sources_tree')}/{meta.get('package_tree')}, "
                   f"not 75222b87's {SOURCES_TREE}/{PACKAGE_TREE}")
    return out


def check(runs, captures, points=None):
    """Gates 1-4 and 6; exits naming every failure. The tests pass a fixture's own points."""
    points = POINTS if points is None else points
    failures, bytes_by = [], {}
    for r in runs:
        p, m, meta = r["params"], r["metrics"], r["meta"]
        name = f"{p['cell']} p{p['players']} {p['form']} rep{p['repeat']}"
        failures += run_failures(name, meta)
        if meta.get("build_config") != "release":
            failures.append(f"{name}: not a release build")
        for key, want in FIXED.items():
            if p.get(key) != want:
                failures.append(f"{name}: {key} {p.get(key)!r}, the matrix has {want!r}")
        if p["form"] not in FORMS:
            failures.append(f"{name}: unknown form")
            continue
        if p["cell"] not in points or point(r) not in points[p["cell"]]:
            failures.append(f"{name}: not a point of the matrix")
            continue
        encoding, dt, dk = FORMS[p["form"]]
        if p["encoding"] != encoding:
            failures.append(f"{name}: format {p['encoding']}, the form is {encoding}")
        if (meta.get("dirty_tracking"), meta.get("dynamic_key_compression")) != (dt, dk):
            failures.append(f"{name}: ran dirty tracking {meta.get('dirty_tracking')!r}, dynamic keys "
                            f"{meta.get('dynamic_key_compression')!r}; the form is {dt!r}, {dk!r}")
        if (meta.get("path_index"), meta.get("field_merge")) != (True, True):
            failures.append(f"{name}: path index {meta.get('path_index')!r}, field merge {meta.get('field_merge')!r}; both must be on")
        if p.get("order") != ORDER.get(p["repeat"]):
            failures.append(f"{name}: ran {p.get('order')!r} order, repeat {p['repeat']} is {ORDER.get(p['repeat'])!r}")
        if m.get("sync_ms_per_sync") is None:
            failures.append(f"{name}: no syncMs (the serial run's sync time)")
        bytes_by.setdefault((p["cell"], point(r), p["form"]), {}).setdefault(p["repeat"], []).append(m["total_bytes"])
    capture_by = {}
    for c in captures:
        p, m, meta = c["params"], c["metrics"], c["meta"]
        name = f"capture {p['cell']} p{p['players']} {p['form']}"
        failures += run_failures(name, meta)
        if meta.get("deterministic_hashing") is not True:
            failures.append(f"{name}: not run under deterministic hashing")
        if not m.get("gate_passed"):
            failures.append(f"{name}: the verify-views gate failed")
        key = (p["cell"], point(c), p["form"])
        if key in capture_by:
            failures.append(f"{name}: captured twice")
        capture_by[key] = m
    if runs or captures:
        try:
            provenance.line(provenance.from_results(runs + captures))
        except provenance.Refused as e:
            failures.append(str(e))
    for cell, pts in points.items():
        for pt in pts:
            where = f"{cell} p{pt[0]}"
            got = {}
            for form in FORMS:
                by_repeat = bytes_by.get((cell, pt, form), {})
                for rep in REPEATS:
                    if len(by_repeat.get(rep, [])) != 1:
                        failures.append(f"{where} {form}: {len(by_repeat.get(rep, []))} results for repeat {rep}, expected 1")
                values = {b for bs in by_repeat.values() for b in bs}
                if len(values) > 1:  # gate 4
                    failures.append(f"{where} {form}: bytes differ between repeats {dict(sorted(by_repeat.items()))}")
                got[form] = by_repeat
                if (cell, pt, form) not in capture_by:
                    failures.append(f"{where} {form}: no capture (gate 3)")
            for dk in ("dk", "nodk"):  # gate 1
                on, off = got[f"mp-dt-{dk}"], got[f"mp-nodt-{dk}"]
                for rep in REPEATS:
                    if on.get(rep) and off.get(rep) and on[rep] != off[rep]:
                        failures.append(f"{where} {dk}: dirty tracking changed the bytes in repeat {rep}: on {on[rep]}, off {off[rep]} (a finding)")
                a, b = capture_by.get((cell, pt, f"mp-dt-{dk}")), capture_by.get((cell, pt, f"mp-nodt-{dk}"))
                if a and b and (a["frames"], a["syncs"]) != (b["frames"], b["syncs"]):
                    failures.append(f"{where} {dk}: dirty tracking changed the captured frames: {a['frames']} frames in {a['syncs']} syncs "
                                    f"with it on, {b['frames']} in {b['syncs']} off (a finding)")
                elif a and b and a["frames_sha256"] != b["frames_sha256"]:
                    failures.append(f"{where} {dk}: dirty tracking changed the captured frames: the same counts "
                                    f"({a['frames']} frames in {a['syncs']} syncs), other bytes, targets, order or syncs (a finding)")
            for on_form, off_form in (("mp-dt-dk", "mp-dt-nodk"), ("mp-nodt-dk", "mp-nodt-nodk"), ("oj-dk", "oj-nodk")):  # gate 2
                for rep in REPEATS:
                    on, off = got[on_form].get(rep), got[off_form].get(rep)
                    if on and off and not off[0] > on[0]:
                        failures.append(f"{where} rep{rep}: {off_form} {off[0]} bytes not more than {on_form} {on[0]}: dynamic-key compression didn't reach the encoder")
    if failures:
        sys.exit("results not usable:\n  " + "\n  ".join(failures))


def git_tree(commit, path):
    try:
        return subprocess.run(["git", "-C", str(TOPIC), "rev-parse", f"{commit}:{path}"],
                              capture_output=True, text=True, check=True, encoding="utf-8").stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def cross_check(runs, single_room=SINGLE_ROOM_RESULTS, tree=git_tree, points=None):
    """Gate 5: mp-dt-dk against single-room-entity-scaling's on-on at every point."""
    points = POINTS if points is None else points
    failures = []
    ours = {(r["params"]["cell"], point(r)): r for r in runs if r["params"]["form"] == "mp-dt-dk" and r["params"]["repeat"] == 1}
    for cell, pts in points.items():
        for pt in pts:
            where = f"{cell} p{pt[0]}"
            path = single_room / f"{cell}-p{pt[0]}-on-on-rep1.json"
            mine = ours.get((cell, pt))
            if mine is None:
                failures.append(f"{where}: no mp-dt-dk repeat 1 result")
                continue
            if not path.exists():
                failures.append(f"{where}: single-room-entity-scaling/results/{path.name} missing (single-room-entity-scaling's rerun results aren't committed)")
                continue
            other = json.loads(path.read_text(encoding="utf-8"))
            sha = other["meta"].get("git_sha")
            trees = (tree(sha, "Sources"), tree(sha, "Package.swift")) if sha else (None, None)
            if trees != (SOURCES_TREE, PACKAGE_TREE):
                failures.append(f"{where}: single-room's result is at {sha}, whose trees are {trees[0]}/{trees[1]}, not 75222b87's")
            op, mp = other["params"], mine["params"]
            for key in ("players", "monster_cap", "workload", "rooms", "iterations", "ticks_per_sync", "encoding", "sync_strategy"):
                if op.get(key) != mp.get(key):
                    failures.append(f"{where}: {key} {op.get(key)!r} in single-room, {mp.get(key)!r} here")
            if op.get("parallel") is not False:
                failures.append(f"{where}: single-room's run isn't serial ({op.get('parallel')!r})")
            om = other["meta"]
            if (om.get("path_index"), om.get("field_merge"), om.get("dynamic_key_compression")) != (True, True, True):
                failures.append(f"{where}: single-room's on-on ran path index {om.get('path_index')!r}, field merge "
                                f"{om.get('field_merge')!r}, dynamic keys {om.get('dynamic_key_compression')!r}")
            if other["metrics"]["total_bytes"] != mine["metrics"]["total_bytes"]:
                failures.append(f"{where}: {mine['metrics']['total_bytes']} bytes here, {other['metrics']['total_bytes']} in single-room's on-on")
    if failures:
        sys.exit("results not usable (gate 5, the cross-check with single-room-entity-scaling):\n  " + "\n  ".join(failures))


def stats(runs, cell, pt, form, key):
    values = [r["metrics"][key] for r in runs if r["params"]["cell"] == cell and point(r) == pt
              and r["params"]["form"] == form and r["metrics"].get(key) is not None]
    return (statistics.median(values), min(values), max(values)) if values else None


def fmt_range(s, digits=3):
    return "–" if s is None else f"{s[0]:.{digits}f} [{s[1]:.{digits}f}–{s[2]:.{digits}f}]"


def change(a, b):
    return "–" if a is None or b is None or a[0] == 0 else f"{(b[0] - a[0]) / a[0] * 100:+.1f} %"


def label(cell, pt):
    players, cap, workload = pt
    return f"{cell} p{players}" if cell in ("idle-players", "active-players") else f"{cell} ({players} {workload})"


def tables(runs, points=None):
    points = POINTS if points is None else points
    if not runs:
        return EMPTY + "\n"
    line = provenance.line(provenance.from_results(runs))
    out = [line, "", f"Sources tree `{SOURCES_TREE[:8]}` and Package.swift `{PACKAGE_TREE[:8]}`, those of the rerun's commit 75222b87. "
           "One room, 200 syncs of 2 ticks, serial; each figure is the median of 4 repeats with their min–max (ABBA order).", ""]
    out += ["### Bytes per sync", "",
            "Dirty tracking on and off sent identical bytes and frames at every point (gate 1), so only dirty tracking on is shown.", "",
            "| Point | MsgPack, dynamic keys on | MsgPack, off | Off vs on | Opcode JSON, dynamic keys on | Opcode JSON, off | Off vs on |",
            "|---|---:|---:|---:|---:|---:|---:|"]
    for cell, pts in points.items():
        for pt in pts:
            b = {f: stats(runs, cell, pt, f, "bytes_per_sync") for f in ("mp-dt-dk", "mp-dt-nodk", "oj-dk", "oj-nodk")}
            out.append(f"| {label(cell, pt)} | {b['mp-dt-dk'][0]:,.1f} | {b['mp-dt-nodk'][0]:,.1f} | {change(b['mp-dt-dk'], b['mp-dt-nodk'])} | "
                       f"{b['oj-dk'][0]:,.1f} | {b['oj-nodk'][0]:,.1f} | {change(b['oj-dk'], b['oj-nodk'])} |")
    out += ["", "### Sync time per sync, dirty tracking on vs off (ms)", "",
            "`syncMs` over the syncs: the extraction, the diff, the encode and the hand-off inside `syncNow()`. "
            "The dirty-key marking on every write is paid in both forms and isn't in this comparison.", "",
            "| Point | Dynamic keys on: tracking on | Tracking off | Off vs on | Dynamic keys off: tracking on | Tracking off | Off vs on |",
            "|---|---:|---:|---:|---:|---:|---:|"]
    for cell, pts in points.items():
        for pt in pts:
            t = {f: stats(runs, cell, pt, f, "sync_ms_per_sync") for f in ("mp-dt-dk", "mp-nodt-dk", "mp-dt-nodk", "mp-nodt-nodk")}
            out.append(f"| {label(cell, pt)} | {fmt_range(t['mp-dt-dk'])} | {fmt_range(t['mp-nodt-dk'])} | {change(t['mp-dt-dk'], t['mp-nodt-dk'])} | "
                       f"{fmt_range(t['mp-dt-nodk'])} | {fmt_range(t['mp-nodt-nodk'])} | {change(t['mp-dt-nodk'], t['mp-nodt-nodk'])} |")
    out += ["", "### Whole-iteration CPU per sync (ms, context)", "",
            "`cpuMs` over the syncs: process CPU over the ticks, the move injection and the sync. Context for the table above, not tracking's overhead.", "",
            "| Point | Tracking on | Tracking off |", "|---|---:|---:|"]
    for cell, pts in points.items():
        for pt in pts:
            out.append(f"| {label(cell, pt)} | {fmt_range(stats(runs, cell, pt, 'mp-dt-dk', 'iteration_cpu_ms'))} | "
                       f"{fmt_range(stats(runs, cell, pt, 'mp-nodt-dk', 'iteration_cpu_ms'))} |")
    return "\n".join(out) + "\n"


def results_section(readme):
    if "## Results" not in readme:
        sys.exit("README.md has no '## Results' section")
    start = readme.index("## Results")
    end = readme.find("\n## ", start + 1)
    body = readme[start:end if end != -1 else None]
    return body.split("\n", 1)[1].strip() + "\n"


def results_markdown(results=RESULTS):
    runs, captures = load(results)
    if runs or captures:
        check(runs, captures)
        cross_check(runs)
    return tables(runs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--markdown", action="store_true", help="Equivalent to no arguments; kept for explicitness.")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    t = results_markdown()
    if a.check:
        if results_section((TOPIC / "README.md").read_text(encoding="utf-8")).strip() != t.strip():
            print("MISMATCH")
            sys.exit("README.md ## Results does not match regenerated tables")
        print("OK")
    else:
        print(t, end="")


if __name__ == "__main__":
    main()
