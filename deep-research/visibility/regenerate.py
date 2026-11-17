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

The full views and partial outputs come from sync-marks.json (sync_marks.py, deep-research/syncmarks.py,
from the captured runs' replay reports): one entry per result with replayed rooms, with its rooms
and players per room. The broadcast and per-player scopes' compared, unverifiable and skipped counts
come from the same entries (the same replay report and sha256), each scope present, at least one
comparison each, their skipped and unverifiable within the entry's totals, and per-player compared
equal to broadcast compared × seeds / rooms (once per output, and once per output and seeded player).
"""
import argparse, json, pathlib, statistics, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import provenance  # noqa: E402
import serverenv  # noqa: E402
import wireform  # noqa: E402

# The wire form every SST run must have: the path index and field merge on (the defaults since
# #308; the refreeze run is the data). Older runs, with both off, aren't table inputs.
INTENDED_WIRE = (True, True)


def wire_failure(name, run):
    """Why the run isn't in the intended wire form (``deep-research/wireform.py``), or None."""
    try:
        form = wireform.resolve(run["meta"].get("git_sha"), run["params"].get("encoding"),
                                path_index=run["meta"].get("path_index"), field_merge=run["meta"].get("field_merge"),
                                # EncodingBenchmark's local path: rows need joins through a router.
                                row_addressing=False)
    except wireform.MissingWireForm as missing:
        return f"{name}: wire form missing: {missing}"
    if (form.path_index, form.field_merge) != INTENDED_WIRE:
        return f"{name}: {form.caption()}, intended pathIndex on, fieldMerge on"
    return None

TOPIC = pathlib.Path(__file__).resolve().parent
RESULTS = TOPIC / "results"
VARIANTS = ("radius", "all", "broadcast")
# run.sh's ORDER values; over a cell's repeats each must appear, so every variant runs in every position.
ORDERS = ("radius-first", "all-first", "broadcast-first")
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
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted(directory.glob("*.json"))]


# Every cell needs these repeats (README: three repeats, the first captures).
REPEATS = (1, 2, 3)


def check(runs, cells=tuple(CELLS), repeats=REPEATS):
    """Refuse unusable or partial results: every cell in `cells` needs every repeat in `repeats`
    (the tests pass a fixture's own cells)."""
    failures = []
    seen, captured, orders = {}, {}, {}
    for r in runs:
        p, m, meta = r["params"], r["metrics"], r["meta"]
        name = f"{p['cell']} {p['variant']} rep{p['repeat']}"
        if meta["build_config"] != "release":
            failures.append(f"{name}: not a release build")
        if meta.get("git_dirty") is not False:
            failures.append(f"{name}: not from a clean tree (git dirty: {meta.get('git_dirty')})")
        if not meta.get("swift_version"):
            failures.append(f"{name}: no Swift version recorded")
        if wire := wire_failure(name, r):
            failures.append(wire)
        if env := serverenv.failure(name, meta.get("server_env")):
            failures.append(env)
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
        orders.setdefault(p["cell"], set()).add(p.get("order"))
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
    if runs:
        present = {cell for cell, _ in seen}
        for cell in cells:
            if cell not in present:
                failures.append(f"{cell}: missing (a partial matrix isn't rendered)")
                continue
            for repeat in repeats:
                if (cell, repeat) not in seen:
                    failures.append(f"{cell}: no repeat {repeat}")
    for cell, got in sorted(orders.items()):
        if not set(ORDERS) <= got:
            failures.append(f"{cell}: orders {sorted(o or '?' for o in got)} over the repeats, every one of {list(ORDERS)} is needed")
    for cell in sorted({c for c, _ in seen}):
        repeats = {repeat for repeat, _ in captured.get(cell, set())}
        if not repeats:
            failures.append(f"{cell}: no captured repeat (gate, replay and consistency never ran)")
        for repeat in repeats:
            if {v for rep, v in captured[cell] if rep == repeat} != set(VARIANTS):
                failures.append(f"{cell} rep{repeat}: captured only {sorted(v for rep, v in captured[cell] if rep == repeat)}")
    try:
        provenance.line(provenance.from_results(runs))
    except provenance.Refused as e:
        failures.append(str(e))
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
    out = [provenance.line(provenance.from_results(runs)) + "\n", f"Medians over {len(repeats)} repeat(s) ({', '.join(map(str, repeats))}). `radius` sends each player the "
           "entities within its view; `all` is the control, the same per-player path sending every entity; `broadcast` is "
           "the twin state with its entities in one broadcast field, the same entities, motion and visibility work as `all` "
           "without the per-player projection. Wire form: messagepack-pathhash, pathIndex on, fieldMerge on (checked per run)."]
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


SYNC_MARKS = TOPIC / "sync-marks.json"


SCOPES = ("broadcast", "per_player")
SCOPE_COLUMNS = ("compared", "unverifiable", "skipped")


def sync_marks(runs, path=SYNC_MARKS):
    """{result name: summary} from sync-marks.json, after its gate; exits naming every failure.
    Expected: one entry per result with replayed rooms."""
    entries = json.loads(path.read_text(encoding="utf-8"))["runs"]
    names = {f"{r['params']['cell']}-{r['params']['variant']}-rep{r['params']['repeat']}": r
             for r in runs if r["metrics"].get("replay_rooms")}
    failures = []
    if set(entries) != set(names):
        failures.append(f"sync-marks.json lists {sorted(set(entries) ^ set(names))} unlike the results with replayed rooms")
    for name, r in names.items():
        e = entries.get(name)
        if e is None:
            continue
        if e["rooms"] != r["metrics"]["replay_rooms"] or e["players_per_room"] != r["params"]["players"]:
            failures.append(f"{name}: {e['rooms']} rooms of {e['players_per_room']} players; the run replayed "
                            f"{r['metrics']['replay_rooms']} of {r['params']['players']}")
        if e["source"].split("/")[0] != r["meta"]["source_file"].split("/")[0]:
            failures.append(f"{name}: sync marks from {e['source']}, the result from {r['meta']['source_file']}")
        if e["seeds"] != e["rooms"] * e["players_per_room"] + e["seeds_later_derived"]:
            failures.append(f"{name}: seeds don't add up")
        scopes = [e.get(k) for k in SCOPES]
        if not all(isinstance(s, dict) and all(isinstance(s.get(c), int) and s[c] >= 0 for c in SCOPE_COLUMNS) for s in scopes):
            failures.append(f"{name}: no broadcast and per-player scope counts")
        elif any(sum(s[c] for s in scopes) > e[c] for c in ("skipped", "unverifiable")) or not all(s["compared"] for s in scopes):
            failures.append(f"{name}: scope counts don't fit the room totals")
        elif e["per_player"]["compared"] * e["rooms"] != e["broadcast"]["compared"] * e["seeds"]:
            failures.append(f"{name}: per-player compared {e['per_player']['compared']} isn't broadcast compared "
                            f"{e['broadcast']['compared']} × seeds {e['seeds']} / rooms {e['rooms']}")
    if failures:
        sys.exit("sync marks not usable:\n  " + "\n  ".join(failures))
    return entries


def sync_marks_table(runs, entries):
    keys = ("rooms", "seeds", "seeds_later_derived", "rooms_seeds_not_players", "key_scope_resets", "skipped", "unverifiable")
    total = lambda es: {k: sum(e[k] for e in es) for k in keys}
    variant = {name: r["params"]["variant"] for r in runs for name in
               [f"{r['params']['cell']}-{r['params']['variant']}-rep{r['params']['repeat']}"]}
    out = ["\n### Full views and partial outputs in the replayed rooms\n",
           "The records aren't kept, so these counts come from each replayed room's \"Sync Output:\" line "
           "(`sync-marks.json`, from each captured run's replay report). A full view sent to a player is a `seed` "
           "(its first view, a rejoin, or a resync in place). Each player has exactly one first seed, so later "
           "seeds are derived: a room's seeds minus its players. A key scope reset is an output that types every "
           "recipient's update `.firstSync`; it carries a diff, not a full view. Skipped and unverifiable are the "
           "comparisons of partial outputs the record marks (not committed, not sent, dropped, or a view that isn't "
           "verifiable), over every scope. The format writes nothing for a sync phase that planned nothing (skipped or "
           "deferred in the live run), so those aren't in any record. Summed over the cells:\n",
           "| Variant | Replayed rooms | Seeds | Later seeds (derived) | Rooms with seeds ≠ players | Key scope resets | Skipped | Unverifiable |",
           "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for v in VARIANTS:
        s = total([e for name, e in entries.items() if variant.get(name) == v])
        out.append(f"| {v} | " + " | ".join(f"{s[k]:,}" for k in keys) + " |")
    s = total(list(entries.values()))
    out.append("| **All** | " + " | ".join(f"{s[k]:,}" for k in keys) + " |")
    cols = [(scope, c) for scope in SCOPES for c in SCOPE_COLUMNS]
    scoped = lambda es: [sum(e[scope][c] for e in es) for scope, c in cols]
    out += ["", "The same lines give each scope's comparisons at re-evaluation (`SyncOutputVerifier`): the broadcast scope "
            "is compared once per output, the per-player scope once per output for each player that has a view, so "
            "per-player compared is broadcast compared × seeds / rooms in every entry (`regenerate.py` checks it). "
            "These counts depend only on the outputs and the seeded players, so they are the same in every variant; "
            "what is compared differs. Compared / unverifiable / skipped, summed over the cells:\n",
            "| Variant | Replayed rooms | Broadcast compared | Broadcast unverifiable | Broadcast skipped | "
            "Per-player compared | Per-player unverifiable | Per-player skipped |",
            "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for v in VARIANTS:
        es = [e for name, e in entries.items() if variant.get(name) == v]
        out.append(f"| {v} | {sum(e['rooms'] for e in es):,} | " + " | ".join(f"{n:,}" for n in scoped(es)) + " |")
    es = list(entries.values())
    out.append(f"| **All** | {sum(e['rooms'] for e in es):,} | " + " | ".join(f"{n:,}" for n in scoped(es)) + " |")
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
    if runs:
        md += "\n" + sync_marks_table(runs, sync_marks(runs))
    if args.check:
        ok = results_section((TOPIC / "README.md").read_text(encoding="utf-8")).strip() == md.strip()
        print("OK" if ok else "MISMATCH")
        sys.exit(0 if ok else 1)
    print(md)


if __name__ == "__main__":
    main()
