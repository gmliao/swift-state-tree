#!/usr/bin/env python3
"""Regenerate every table in README.md from results/*.json (stdlib only).

Usage: python3 regenerate.py [--markdown] | python3 regenerate.py --check

Each figure is the median over the repeats of that cell and variant. Before any table is built,
every result must have passed the capture gate (when captured), every decode figure must come
from a verified time-decode run, every cell must have the three measured variants in every repeat
and both B1 variants in every repeat that captured, and a cell's captured projections must be the
same in every variant.

results/state/*.json hold SST's sync state by the counting rule (stateshape.py, from a capture):
each must come from a clean, pinned run with the server environment unset, at a point of the
matrix, with the same figures wherever a point was counted twice, and from a commit whose
Sources and Package.swift trees are those of the measured runs' commit (read with git).
"""
import argparse, json, pathlib, statistics, subprocess, sys

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


def provenance_line(runs):
    """The Results' provenance line (provenance.py): B1's files carry no Swift build, so Swift and
    the build come from the SST-side runs, the commit, dirty flag and Node from every file."""
    metas = provenance.from_results(runs, kind=lambda r: "b1" if r["params"]["variant"] in B1_VARIANTS else "sst")
    sst = ("SST and B2 runs", {"sst"})
    return provenance.line(metas, scopes={"swift": sst, "build": sst})


def load(directory):
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted(directory.glob("*.json"))]


def load_states(directory):
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted((directory / "state").glob("*.json"))]


STATE_FIGURES = ("broadcast_snapshot_bytes", "broadcast_key_table_bytes", "broadcast_key_table_entries",
                 "per_player_snapshot_bytes", "per_player_key_table_bytes", "shared_bytes_per_room", "own_bytes_per_client")


def state_point(s):
    p = s["params"]
    return (p["axis"], p["players"], p["rooms"], p["monster_cap"])


def git_tree(commit, path):
    try:
        return subprocess.run(["git", "-C", str(TOPIC), "rev-parse", f"{commit}:{path}"],
                              capture_output=True, text=True, check=True, encoding="utf-8").stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def check_states(states, runs, matrix=MATRIX, tree=git_tree):
    """Refuse unusable state counts (see the module docstring)."""
    failures, by_point = [], {}
    commits = {r["meta"].get("git_sha") for r in runs}
    want = None
    if states and len(commits) == 1:
        sha = next(iter(commits))
        want = (tree(sha, "Sources"), tree(sha, "Package.swift")) if sha else (None, None)
        if None in want:
            failures.append(f"the measured runs' commit {sha} doesn't resolve to its Sources and Package.swift trees")
    for s in states:
        meta, name = s["meta"], f"state {'/'.join(map(str, state_point(s)))} rep{s['params']['repeat']}"
        if meta.get("git_dirty") is not False:
            failures.append(f"{name}: not from a clean tree (git dirty: {meta.get('git_dirty')})")
        if not meta.get("pin_cpus"):
            failures.append(f"{name}: unpinned")
        if not meta.get("swift_version"):
            failures.append(f"{name}: no Swift version recorded")
        if env := serverenv.failure(name, meta.get("server_env")):
            failures.append(env)
        if state_point(s) not in matrix:
            failures.append(f"{name}: not a cell of the matrix")
        if want is not None and None not in want and (meta.get("sources_tree"), meta.get("package_tree")) != want:
            failures.append(f"{name}: Sources/Package.swift trees {meta.get('sources_tree')}/{meta.get('package_tree')}, "
                            f"the measured runs' are {want[0]}/{want[1]}")
        figures = tuple(s["metrics"].get(k) for k in STATE_FIGURES)
        if by_point.setdefault(state_point(s), figures) != figures:
            failures.append(f"{name}: the counting rule's figures differ from another count of the same cell")
    if failures:
        sys.exit("state counts not usable:\n  " + "\n  ".join(failures))


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
        # B1 is converted from the sst capture, so the sst run's environment covers it.
        if p["variant"] not in B1_VARIANTS and (env := serverenv.failure(name, r["meta"].get("server_env"))):
            failures.append(env)
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
    try:
        provenance_line(runs)
    except provenance.Refused as e:
        failures.append(str(e))
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


def state_of(states, axis, field, value):
    """The state count of a table row (an axis and its varied value), or None."""
    for s in states:
        p = s["params"]
        if p["axis"] == axis and p[field] == value:
            return s["metrics"]
    return None


def tables(runs, states=()):
    if not runs:
        return EMPTY
    repeats = sorted({r["params"]["repeat"] for r in runs})
    out = [provenance_line(runs) + "\n", f"Medians over {len(repeats)} repeat(s) ({', '.join(map(str, repeats))}). B2 is the entity-delta baseline; "
           "SST and B2 run with server events off, `SST events on` is SST as it ships. SST's wire form: "
           "messagepack-pathhash, pathIndex on, fieldMerge on (checked per run)."]
    # Said once, under the first sync-state table, and only while it holds for every cell: a land
    # with per-client fields would show them in the tables.
    no_own_state = bool(states) and all(s["metrics"]["own_bytes_per_client"] == 0 for s in states)
    for axis, title, field, label in AXES:
        values = sorted({r["params"][field] for r in runs if r["params"]["axis"] == axis})
        if not values:
            continue
        get = lambda v, variant, metric: median(runs, axis, field, v, variant, metric)
        out.append(f"\n### {title}\n")
        out.append("Bytes per sync (every recipient of every room, measured window):\n")
        out.append("| Cell | SST events on | SST | B2 | B2 / SST | B2 bit-packed bound | B2 first sync | B2 encoder state (B) | SST sync state (B) |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
        shape = {}
        for v in values:
            sst, b2 = get(v, "sst", "bytes_per_sync"), get(v, "b2", "bytes_per_sync")
            st = state_of(states, axis, field, v)
            rooms = v if field == "rooms" else 1
            players = v if field == "players" else 5
            # B2's figure sums every client of every room; SST's, the same scope: its shared state
            # once per room and its per-client state once per client.
            sst_state = None if st is None else rooms * (st["shared_bytes_per_room"] + players * st["own_bytes_per_client"])
            shape[v] = (st, rooms, players)
            out.append(f"| {label(v)} | {f0(get(v, 'sst-events', 'bytes_per_sync'))} | {f0(sst)} | {f0(b2)} | {ratio(b2, sst)} | "
                       f"{f0(get(v, 'b2', 'bytes_per_sync_bitpacked_bound'))} | {f0(get(v, 'b2', 'first_sync_bytes'))} | "
                       f"{f0(get(v, 'b2', 'encoder_state_bytes'))} | {f0(sst_state)} |")
        if any(st is not None for st, _, _ in shape.values()):
            out.append("\nSync state by one counting rule (bytes; README, Metrics): B2's per-client encoder state, and SST's state "
                       "shared by a room (the broadcast snapshot and its dynamic-key table) and kept per client (the per-player "
                       "snapshot and its table), with the shared part divided over the room's clients:\n")
            out.append("| Cell | B2 per client | SST shared per room | SST per client | SST per client, with its share |")
            out.append("|---|---:|---:|---:|---:|")
            for v in values:
                st, rooms, players = shape[v]
                b2_total = get(v, "b2", "encoder_state_bytes")
                b2_client = None if b2_total is None else b2_total / (rooms * players)
                share = None if st is None else st["own_bytes_per_client"] + st["shared_bytes_per_room"] / players
                out.append(f"| {label(v)} | {f0(b2_client)} | {f0(None if st is None else st['shared_bytes_per_room'])} | "
                           f"{f0(None if st is None else st['own_bytes_per_client'])} | {f0(share)} |")
            if no_own_state:
                no_own_state = False
                out.append("\nSST per client is 0 in these cells because Hero Defense declares only broadcast and serverOnly "
                           "fields; a land with perPlayer, perPlayerSlice or masked fields keeps per-client state as well.")
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
    states = load_states(args.results)
    if states:
        check_states(states, runs)
    md = tables(runs, states)
    if args.check:
        ok = results_section((TOPIC / "README.md").read_text(encoding="utf-8")).strip() == md.strip()
        print("OK" if ok else "MISMATCH")
        sys.exit(0 if ok else 1)
    print(md)


if __name__ == "__main__":
    main()
