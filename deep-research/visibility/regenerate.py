#!/usr/bin/env python3
"""Regenerate every table in README.md from results/*.json (stdlib only).

Usage: python3 regenerate.py [--markdown] | python3 regenerate.py --check

Each figure is the median over the repeats of that cell and variant (the captured figures over
the repeats that captured). Before any table is built, every result must:
  - come from a release build of a clean tree, with its Swift version recorded;
  - have the cell's parameters (entity count, radius, viewers, ticks per sync) and the matrix
    constants (10 rooms, 200 iterations, messagepack-pathhash, delta, serial, server events off);
and every cell must have both variants in every repeat and at least one captured repeat, in which
both variants passed the gate (verify-views) and the replay (`ReevaluationRunner --verify`), the
cell passed the radius/all consistency check, and the decode figures come from a verified
time-decode run.
"""
import argparse, json, pathlib, statistics, sys

TOPIC = pathlib.Path(__file__).resolve().parent
RESULTS = TOPIC / "results"
VARIANTS = ("radius", "all", "broadcast")
# The matrix (run.sh's CELL_TABLE): entity count, view radius, viewers per room, ticks per sync.
CELLS = {
    "default": (40, 15.0, 4, 1),
    "radius8": (40, 8.0, 4, 1),
    "radius30": (40, 30.0, 4, 1),
    "entities160": (160, 15.0, 4, 1),
    "entities640": (640, 15.0, 4, 1),
    "viewers16": (40, 15.0, 16, 1),
    "tps2": (40, 15.0, 4, 2),
}
CONSTANTS = {"rooms": 10, "iterations": 200, "encoding": "messagepack-pathhash", "sync_strategy": "delta",
             "parallel": "false", "server_events": False}
AXES = (
    ("View radius (40 entities, 4 viewers, 1 tick per sync)", ("radius8", "default", "radius30"), lambda c: f"radius {CELLS[c][1]:g}"),
    ("Entity count (radius 15, 4 viewers, 1 tick per sync)", ("default", "entities160", "entities640"), lambda c: f"{CELLS[c][0]} entities"),
    ("Viewers per room (radius 15, 40 entities, 1 tick per sync)", ("default", "viewers16"), lambda c: f"{CELLS[c][2]} viewers"),
    ("Ticks per sync (radius 15, 40 entities, 4 viewers)", ("default", "tps2"), lambda c: f"{CELLS[c][3]} tick(s) per sync"),
)
EMPTY = "_No results yet: the measurement host's run fills this section._"


def load(directory):
    return [json.loads(p.read_text()) for p in sorted(directory.glob("*.json"))]


def check(runs):
    failures = []
    seen, captured = {}, {}
    for r in runs:
        p, m, meta = r["params"], r["metrics"], r["meta"]
        name = f"{p['cell']} {p['variant']} rep{p['repeat']}"
        if meta["build_config"] != "release":
            failures.append(f"{name}: not a release build")
        if meta.get("git_dirty") is not False:
            failures.append(f"{name}: not from a clean tree (git dirty: {meta.get('git_dirty')})")
        if not meta.get("swift_version"):
            failures.append(f"{name}: no Swift version recorded")
        if p["cell"] not in CELLS:
            failures.append(f"{name}: not a cell of the matrix")
            continue
        if p["variant"] not in VARIANTS:
            failures.append(f"{name}: unknown variant")
            continue
        expected = CELLS[p["cell"]]
        got = (p["entity_count"], p["view_radius"], p["players"], p["ticks_per_sync"])
        if got != expected:
            failures.append(f"{name}: parameters {got}, the matrix has {expected}")
        for key, value in CONSTANTS.items():
            if p.get(key) != value:
                failures.append(f"{name}: {key} {p.get(key)!r}, the matrix has {value!r}")
        seen.setdefault((p["cell"], p["repeat"]), set()).add(p["variant"])
        if "gate_passed" in m:
            captured.setdefault(p["cell"], set()).add((p["repeat"], p["variant"]))
            for gate in ("gate_passed", "replay_passed", "consistency_passed"):
                if m.get(gate) is not True:
                    failures.append(f"{name}: {gate} is {m.get(gate)!r}")
            if not m.get("decode_provenance_verified"):
                failures.append(f"{name}: decode figures from an unverified time-decode run")
    for (cell, repeat), variants in sorted(seen.items()):
        if variants != set(VARIANTS):
            failures.append(f"{cell} rep{repeat}: variants {sorted(variants)}, expected {sorted(VARIANTS)}")
    for cell in sorted({c for c, _ in seen}):
        repeats = {repeat for repeat, _ in captured.get(cell, set())}
        if not repeats:
            failures.append(f"{cell}: no captured repeat (gate, replay and consistency never ran)")
        for repeat in repeats:
            if {v for rep, v in captured[cell] if rep == repeat} != set(VARIANTS):
                failures.append(f"{cell} rep{repeat}: captured only {sorted(v for rep, v in captured[cell] if rep == repeat)}")
    if failures:
        sys.exit("results not usable:\n  " + "\n  ".join(failures))


def median(runs, cell, variant, metric):
    values = [r["metrics"].get(metric) for r in runs if r["params"]["cell"] == cell and r["params"]["variant"] == variant]
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def f0(v):
    return "–" if v is None else f"{v:,.0f}"


def f1(v):
    return "–" if v is None else f"{v:,.1f}"


def f2(v):
    return "–" if v is None else f"{v:,.2f}"


def ratio(a, b):
    return "–" if a is None or b is None or b == 0 else f"{a / b:.2f}"


def tables(runs):
    if not runs:
        return EMPTY
    repeats = sorted({r["params"]["repeat"] for r in runs})
    present = {r["params"]["cell"] for r in runs}
    out = [f"Medians over {len(repeats)} repeat(s) ({', '.join(map(str, repeats))}). `radius` sends each player the "
           "entities within its view; `all` is the control, the same per-player path sending every entity; `broadcast` is "
           "the twin state with its entities in one broadcast field, the same entities, motion and visibility work as `all` "
           "without the per-player projection."]
    for title, cells, label in AXES:
        cells = [c for c in cells if c in present]
        if not cells:
            continue
        get = lambda c, variant, metric: median(runs, c, variant, metric)
        out.append(f"\n### {title}\n")
        out.append("Bytes per recipient per sync (every room, measured window), and over the captured rooms after permessage-deflate:\n")
        out.append("| Cell | Visible per recipient | View changes per recipient per sync | radius | all | broadcast | radius / all | radius deflate | all deflate | broadcast deflate | radius / all deflate |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for c in cells:
            rb, ab = get(c, "radius", "bytes_per_recipient_sync"), get(c, "all", "bytes_per_recipient_sync")
            rd, ad = get(c, "radius", "bytes_per_recipient_sync_deflate"), get(c, "all", "bytes_per_recipient_sync_deflate")
            out.append(f"| {label(c)} | {f1(get(c, 'radius', 'visible_per_recipient'))} | "
                       f"{f2(get(c, 'radius', 'view_changes_per_recipient_sync'))} | {f1(rb)} | {f1(ab)} | "
                       f"{f1(get(c, 'broadcast', 'bytes_per_recipient_sync'))} | {ratio(rb, ab)} | "
                       f"{f1(rd)} | {f1(ad)} | {f1(get(c, 'broadcast', 'bytes_per_recipient_sync_deflate'))} | {ratio(rd, ad)} |")
        out.append("\nServer time per room (µs, serial; sync: `syncNow()`, tick: `stepTickOnce`, which computes visibility; never summed). "
                   "`all / broadcast` is what the per-player projection itself costs at the same entities and motion:\n")
        out.append("| Cell | radius sync | all sync | broadcast sync | sync all / broadcast | radius tick | all tick | broadcast tick | tick radius / all |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
        for c in cells:
            rt, at = get(c, "radius", "tick_us_per_room_tick"), get(c, "all", "tick_us_per_room_tick")
            asy, bsy = get(c, "all", "sync_us_per_room_sync"), get(c, "broadcast", "sync_us_per_room_sync")
            out.append(f"| {label(c)} | {f1(get(c, 'radius', 'sync_us_per_room_sync'))} | {f1(asy)} | {f1(bsy)} | {ratio(asy, bsy)} | "
                       f"{f1(rt)} | {f1(at)} | {f1(get(c, 'broadcast', 'tick_us_per_room_tick'))} | {ratio(rt, at)} |")
        out.append("\nChecks over the captured rooms (every one passed; the counts say how much was checked):\n")
        out.append("| Cell | Gate comparisons radius | Gate comparisons all | Gate comparisons broadcast | Replayed rooms | Consistency checks radius | Consistency checks broadcast |")
        out.append("|---|---:|---:|---:|---:|---:|---:|")
        for c in cells:
            replayed = sum(get(c, v, "replay_rooms") or 0 for v in VARIANTS)
            out.append(f"| {label(c)} | {f0(get(c, 'radius', 'gate_comparisons'))} | {f0(get(c, 'all', 'gate_comparisons'))} | "
                       f"{f0(get(c, 'broadcast', 'gate_comparisons'))} | {f0(replayed)} | {f0(get(c, 'radius', 'consistency_checks'))} | "
                       f"{f0(get(c, 'broadcast', 'consistency_checks'))} |")
        out.append("\nClient decode per frame (µs, Node, SDK; apply after #303):\n")
        out.append("| Cell | radius decode | radius decode + apply | all decode | all decode + apply | broadcast decode | broadcast decode + apply |")
        out.append("|---|---:|---:|---:|---:|---:|---:|")
        for c in cells:
            out.append(f"| {label(c)} | {f2(get(c, 'radius', 'decode_us_per_frame'))} | {f2(get(c, 'radius', 'decode_apply_us_per_frame'))} | "
                       f"{f2(get(c, 'all', 'decode_us_per_frame'))} | {f2(get(c, 'all', 'decode_apply_us_per_frame'))} | "
                       f"{f2(get(c, 'broadcast', 'decode_us_per_frame'))} | {f2(get(c, 'broadcast', 'decode_apply_us_per_frame'))} |")
    return "\n".join(out)


def results_section(readme):
    marker = "## Results"
    if marker not in readme:
        sys.exit("README.md has no '## Results' section")
    body = readme.split(marker, 1)[1]
    nxt = body.find("\n## ")
    return body[:nxt] if nxt != -1 else body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--results", type=pathlib.Path, default=RESULTS)
    args = ap.parse_args()
    runs = load(args.results)
    check(runs)
    md = tables(runs)
    if args.check:
        ok = results_section((TOPIC / "README.md").read_text()).strip() == md.strip()
        print("OK" if ok else "MISMATCH")
        sys.exit(0 if ok else 1)
    print(md)


if __name__ == "__main__":
    main()
