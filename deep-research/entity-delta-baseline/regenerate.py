#!/usr/bin/env python3
"""Regenerate every table in README.md from results/*.json (stdlib only).

Usage: python3 regenerate.py [--markdown] | python3 regenerate.py --check

Each figure is the median over the repeats of that cell and variant. Before any table is built,
every result must have passed the capture gate (when captured), every decode figure must come
from a verified time-decode run, every cell must have the three measured variants in every repeat
and both B1 variants in every repeat that captured, and a cell's captured projections must be the
same in every variant.
"""
import argparse, json, pathlib, statistics, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import wireform  # noqa: E402

# The wire form every SST run must have: the path index and field merge on (the defaults since
# #308; the refreeze run is the data). Older runs, with both off, aren't table inputs.
INTENDED_WIRE = (True, True)


def wire_failure(name, run):
    """Why the run isn't in the intended wire form (``deep-research/wireform.py``), or None."""
    try:
        form = wireform.resolve(run["meta"].get("git_sha"), run["params"].get("encoding"),
                                path_index=run["meta"].get("path_index"), field_merge=run["meta"].get("field_merge"))
    except wireform.MissingWireForm as missing:
        return f"{name}: wire form missing: {missing}"
    if (form.path_index, form.field_merge) != INTENDED_WIRE:
        return f"{name}: {form.caption()}, intended pathIndex on, fieldMerge on"
    return None

TOPIC = pathlib.Path(__file__).resolve().parent
RESULTS = TOPIC / "results"
VARIANTS = ("sst-events", "sst", "b2")
# The @colyseus/schema baseline, converted in the sst variant's capture pass: present wherever it captured.
B1_VARIANTS = ("b1", "b1-tuned")
AXES = (
    ("rooms", "Rooms axis (5 players per room, natural spawn)", "rooms", lambda v: f"rooms {v}"),
    ("monsters", "Monster axis (1 room, 5 idle players)", "monster_cap", lambda v: f"monster cap {v}"),
    ("active", "Active-player axis (1 room, monster cap 4, every player moves every tick)", "players", lambda v: f"players {v}"),
)
# The matrix (run.sh's cells): (axis, players, rooms, monster cap), and the repeats every cell needs.
MATRIX = ([("rooms", 5, rooms, None) for rooms in (10, 30, 50, 100, 300, 500)]
          + [("monsters", 5, 1, cap) for cap in (4, 10, 50, 100)]
          + [("active", players, 1, 4) for players in (5, 10, 20, 50)])
REPEATS = (1, 2)
EMPTY = "_No results yet: the measurement host's run fills this section._"


def load(directory):
    return [json.loads(p.read_text()) for p in sorted(directory.glob("*.json"))]


def check(runs, matrix=MATRIX, repeats=REPEATS):
    """Refuse unusable or partial results: every cell of `matrix` needs every repeat in `repeats`
    (the tests pass a fixture's own cells)."""
    failures = []
    cells = {}
    for r in runs:
        p, m = r["params"], r["metrics"]
        name = f"{p['axis']} p{p['players']} r{p['rooms']} cap{p['monster_cap']} {p['variant']} rep{p['repeat']}"
        if p["variant"] not in B1_VARIANTS and not r["meta"].get("swift_version"):
            failures.append(f"{name}: no Swift version recorded")
        if (p["axis"], p["players"], p["rooms"], p["monster_cap"]) not in matrix:
            failures.append(f"{name}: not a cell of the matrix")
        if m.get("gate_passed") is False:
            failures.append(f"{name}: the capture gate failed")
        if "decode_apply_us_per_frame" in m and not m.get("decode_provenance_verified"):
            failures.append(f"{name}: decode figures from an unverified time-decode run")
        if r["meta"].get("git_dirty") is not False:
            failures.append(f"{name}: not from a clean tree (git dirty: {r['meta'].get('git_dirty')})")
        if p["variant"] not in B1_VARIANTS and r["meta"]["build_config"] != "release":
            failures.append(f"{name}: not a release build")
        # The baselines are other encoders: the path index and field merge are SST's.
        if p["variant"] in ("sst", "sst-events") and (wire := wire_failure(name, r)):
            failures.append(wire)
        cells.setdefault((p["axis"], p["players"], p["rooms"], p["monster_cap"], p["repeat"]), set()).add(p["variant"])
    projections = {}
    for r in runs:
        p = r["params"]
        if "projection_sha256" in r["metrics"]:
            projections.setdefault((p["axis"], p["players"], p["rooms"], p["monster_cap"], p["repeat"]), {})[p["variant"]] = r["metrics"]["projection_sha256"]
    for key, by_variant in projections.items():
        if len(set(by_variant.values())) != 1:
            failures.append(f"{key}: the projections differ between variants {sorted(by_variant)} (events switch or baseline changed the state)")
    captured = {(r["params"]["axis"], r["params"]["players"], r["params"]["rooms"], r["params"]["monster_cap"], r["params"]["repeat"])
                for r in runs if r["params"]["variant"] == "sst" and "gate_passed" in r["metrics"]}
    for key, variants in cells.items():
        expected = set(VARIANTS) | (set(B1_VARIANTS) if key in captured else set())
        if variants != expected:
            failures.append(f"{key}: variants {sorted(variants)}, expected {sorted(expected)}")
    if runs:
        present = {key[:4] for key in cells}
        for cell in matrix:
            if cell not in present:
                failures.append(f"{cell}: missing (a partial matrix isn't rendered)")
                continue
            for repeat in repeats:
                if cell + (repeat,) not in cells:
                    failures.append(f"{cell}: no repeat {repeat}")
    if failures:
        sys.exit("results not usable:\n  " + "\n  ".join(failures))


def median(runs, axis, field, value, variant, metric):
    values = [r["metrics"].get(metric) for r in runs
              if r["params"]["axis"] == axis and r["params"][field] == value and r["params"]["variant"] == variant]
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
    out = [f"Medians over {len(repeats)} repeat(s) ({', '.join(map(str, repeats))}). B2 is the entity-delta baseline; "
           "SST and B2 run with server events off, `SST events on` is SST as it ships. SST's wire form: "
           "messagepack-pathhash, pathIndex on, fieldMerge on (checked per run)."]
    for axis, title, field, label in AXES:
        values = sorted({r["params"][field] for r in runs if r["params"]["axis"] == axis})
        if not values:
            continue
        get = lambda v, variant, metric: median(runs, axis, field, v, variant, metric)
        out.append(f"\n### {title}\n")
        out.append("Bytes per sync (every recipient of every room, measured window):\n")
        out.append("| Cell | SST events on | SST | B2 | B2 / SST | B2 bit-packed bound | B2 first sync | B2 encoder state (B) |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for v in values:
            sst, b2 = get(v, "sst", "bytes_per_sync"), get(v, "b2", "bytes_per_sync")
            out.append(f"| {label(v)} | {f0(get(v, 'sst-events', 'bytes_per_sync'))} | {f0(sst)} | {f0(b2)} | {ratio(b2, sst)} | "
                       f"{f0(get(v, 'b2', 'bytes_per_sync_bitpacked_bound'))} | {f0(get(v, 'b2', 'first_sync_bytes'))} | "
                       f"{f0(get(v, 'b2', 'encoder_state_bytes'))} |")
        out.append("\nBytes per room per sync over the same captured rooms, before and after permessage-deflate "
                   "(B1 is `@colyseus/schema`: `number` is every number declared `number`, `tuned` each field the narrowest fixed type "
                   "covering the run's values):\n")
        out.append("| Cell | SST | SST deflate | B2 | B2 deflate | B1 number | B1 number deflate | B1 tuned | B1 tuned deflate |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
        for v in values:
            cols = [f1(get(v, variant, metric)) for variant in ("sst", "b2", "b1", "b1-tuned")
                    for metric in ("bytes_per_room_sync_captured", "bytes_per_room_sync_deflate")]
            out.append(f"| {label(v)} | " + " | ".join(cols) + " |")
        out.append("\nCaptured rooms against every room, per room per sync (whether the captured rooms are representative):\n")
        out.append("| Cell | SST captured | SST all rooms | B2 captured | B2 all rooms |")
        out.append("|---|---:|---:|---:|---:|")
        for v in values:
            rooms = v if field == "rooms" else 1
            row = []
            for variant in ("sst", "b2"):
                all_rooms = get(v, variant, "bytes_per_sync")
                row += [f1(get(v, variant, "bytes_per_room_sync_captured")), f1(None if all_rooms is None else all_rooms / rooms)]
            out.append(f"| {label(v)} | " + " | ".join(row) + " |")
        out.append("\nServer CPU per room per sync (µs, serial; SST: `syncNow()`; B2: projection plus encode):\n")
        out.append("| Cell | SST sync | B2 project | B2 encode per client | B2 total per client | B2 encode shared | B2 total shared |")
        out.append("|---|---:|---:|---:|---:|---:|---:|")
        for v in values:
            out.append(f"| {label(v)} | {f1(get(v, 'sst', 'sync_us_per_room_sync'))} | {f1(get(v, 'b2', 'project_us_per_room_sync'))} | "
                       f"{f1(get(v, 'b2', 'encode_only_us_per_room_sync'))} | {f1(get(v, 'b2', 'encode_us_per_room_sync'))} | "
                       f"{f1(get(v, 'b2', 'encode_shared_only_us_per_room_sync'))} | {f1(get(v, 'b2', 'encode_shared_us_per_room_sync'))} |")
        out.append("\nClient decode per frame (µs, Node; B2's and B1's decoders apply while they parse, so they have decode plus apply only):\n")
        out.append("| Cell | SST decode | SST decode + apply | B2 decode + apply | B1 number decode + apply | B1 tuned decode + apply |")
        out.append("|---|---:|---:|---:|---:|---:|")
        for v in values:
            out.append(f"| {label(v)} | {f2(get(v, 'sst', 'decode_us_per_frame'))} | {f2(get(v, 'sst', 'decode_apply_us_per_frame'))} | "
                       f"{f2(get(v, 'b2', 'decode_apply_us_per_frame'))} | {f2(get(v, 'b1', 'decode_apply_us_per_frame'))} | "
                       f"{f2(get(v, 'b1-tuned', 'decode_apply_us_per_frame'))} |")
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
