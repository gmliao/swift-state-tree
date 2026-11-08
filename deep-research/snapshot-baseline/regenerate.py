#!/usr/bin/env python3
"""Regenerate every table in README.md from results/*.json (stdlib only).

Usage: python3 regenerate.py [--markdown] | python3 regenerate.py --check
"""
import argparse, importlib.util, json, math, pathlib, re, statistics, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import provenance  # noqa: E402
import serverenv  # noqa: E402
import wireform  # noqa: E402

TOPIC = pathlib.Path(__file__).parent
RESULTS = TOPIC / "results"
# The 2026-08-31 single-room runs, both wire knobs off like this topic's record (that topic's own
# results/ now holds its wire-form ablation).
ARCHIVE = TOPIC.parent / "single-room-entity-scaling" / "results" / "pre-refreeze"
# That topic's wire-form ablation (one commit, every form): its off-off and on-on forms at the
# re-run's commit split the intended form's drift into code changes (archived -> off/off) and the wire
# form (off/off -> on/on). Re-running that topic means re-running this one: the split needs both at
# one commit.
SINGLE_ROOM = TOPIC.parent / "single-room-entity-scaling"
ABLATION = SINGLE_ROOM / "results"
# (label, point (players, monster cap, workload), single-room cell, this topic's cell).
DRIFT_CELLS = [("monster cap", (5, cap, "idle"), f"monsters-cap{cap}", dict(axis="monsters", monster_cap=cap))
               for cap in (4, 10, 50, 100)] + \
              [("active players", (p, 4, "active"), "active-players", dict(axis="active", players=p))
               for p in (5, 10, 20, 50)]
DRIFT_CAPTION = (
    "The archived cells were measured at {archived}, before the path index and field merge; the "
    "pre-refreeze record below reproduces them. The re-run differs from them by more than the wire form. "
    "Among the changes between the two, #178 stopped sending players' server-only fields (monster cap 4: "
    "828 → 818 B), #271 and #278 send positions and rotations as arrays of their leaves instead of keyed "
    "maps, and #210 encodes identifiers as strings; at the path index's base, the form with neither the "
    "index nor the merge measured 587 B at monster cap 4 (#297). How 818 → 587 splits among the changes "
    "was not measured. The columns therefore separate the two: *code changes* is archived → off/off, both "
    "knobs off at the re-run's commit (`single-room-entity-scaling`'s ablation, {offoff}); *wire form* is "
    "that ablation's off/off → on/on, the path index and field merge alone. The archived and re-run "
    "columns are EncodingBenchmark's `bytesPerSync`, truncated to whole bytes; off/off is "
    "`totalBytes / iterations` (shown rounded), and the wire-form column compares the ablation's two forms "
    "at that precision. The archive's truncation (under 1 B) moves the code-changes column by at most "
    "{bound:.2f} percentage points. The table shows that the archive and the re-run differ by a measured amount; "
    "only the wire-form column measures the wire form.\n")


# The tables' wire form: the path index and field merge on (the defaults since #308; they change
# the -pathhash format's bytes, not JSON's). Runs with both off are the pre-refreeze record: shown
# under their own heading, never in the tables. Any other form, or one that can't be told, is refused.
INTENDED = (True, True)
RECORD = (False, False)


def flags(form):
    return (form.path_index, form.field_merge)


def caption(path_index, field_merge):
    on = lambda v: "on" if v else "off"
    return f"pathIndex {on(path_index)}, fieldMerge {on(field_merge)}"


def partition(runs):
    """(runs in the intended form, runs in the pre-refreeze record's form); exits on any other."""
    current, record, problems = [], [], []
    for r in runs:
        try:
            form = wireform.resolve(r["meta"].get("git_sha"), r["params"]["encoding"],
                                    path_index=r["meta"].get("path_index"), field_merge=r["meta"].get("field_merge"))
        except wireform.MissingWireForm as missing:
            problems.append(f"{r['meta'].get('source_file')}: wire form missing: {missing}")
            continue
        if flags(form) == INTENDED:
            # The intended form's tables are the shipped sync path; the record ran the legacy one.
            if env := serverenv.failure(r["meta"].get("source_file"), r["meta"].get("server_env")):
                problems.append(env)
            else:
                current.append(r)
        elif flags(form) == RECORD:
            record.append(r)
        else:
            problems.append(f"{r['meta'].get('source_file')}: {form.caption()}, intended {caption(*INTENDED)}")
    if problems:
        sys.exit("results not usable:\n  " + "\n  ".join(problems))
    return current, record


def load(directory):
    return [json.load(open(p)) for p in sorted(directory.glob("*.json"))]


# The intended form's tables are per-cell medians over these repeats (run.sh REPEAT=1..3, the
# order alternating); the pre-refreeze record is one unrepeated sweep.
REPEATS = (1, 2, 3)
SWEEP_KEYS = ("repeat", "order", "sweep")


def merge_repeats(runs):
    """One run per cell, its metrics the median over REPEATS. Exits on a run outside REPEATS,
    a cell missing a repeat or holding one twice, or repeats from different commits."""
    cells, problems = {}, []
    for r in runs:
        repeat = r["params"].get("repeat")
        if repeat not in REPEATS:
            problems.append(f"{r['meta'].get('source_file')}: repeat {repeat}, expected one of {list(REPEATS)}")
            continue
        key = tuple(sorted((k, v) for k, v in r["params"].items() if k not in SWEEP_KEYS))
        cells.setdefault(key, {}).setdefault(repeat, []).append(r)
    merged = []
    for key, by_repeat in sorted(cells.items(), key=lambda kv: str(kv[0])):
        name = ", ".join(f"{k}={v}" for k, v in key if v is not None)
        missing = [n for n in REPEATS if n not in by_repeat]
        twice = [n for n, rs in sorted(by_repeat.items()) if len(rs) > 1]
        if missing or twice:
            problems.append(f"{name}: " + "; ".join(([f"repeat(s) {missing} missing"] if missing else [])
                                                    + ([f"repeat(s) {twice} more than once"] if twice else [])))
            continue
        rs = [by_repeat[n][0] for n in REPEATS]
        commits = sorted({r["meta"].get("git_sha") for r in rs}, key=str)
        if len(commits) != 1:
            problems.append(f"{name}: repeats from different commits {commits}")
            continue
        metrics = {m: statistics.median(r["metrics"][m] for r in rs)
                   for m in rs[0]["metrics"] if all(isinstance(r["metrics"].get(m), (int, float)) for r in rs)}
        merged.append({"params": dict(key), "metrics": metrics, "meta": dict(rs[0]["meta"])})
    if problems:
        sys.exit("repeats not usable:\n  " + "\n  ".join(problems))
    return merged


def pick(runs, **cond):
    # Merged cells (merge_repeats) and the unrepeated record carry no repeat.
    cond.setdefault("repeat", None)
    out = [r for r in runs if all(r["params"].get(k) == v for k, v in cond.items())]
    if len(out) != 1:
        sys.exit(f"expected exactly one run for {cond}, found {len(out)}")
    return out[0]


def fmt(n):
    return f"{n:,.0f}"


def pair_row(label, d, f):
    db, fb = d["metrics"]["bytes_per_sync"], f["metrics"]["bytes_per_sync"]
    saving = 1 - db / fb
    return (f"| {label} | {fmt(db)} | {fmt(fb)} | {fb / db:.2f}× | {saving * 100:.1f}% | "
            f"{d['metrics']['avg_cost_per_sync_ms']:.3f} | {f['metrics']['avg_cost_per_sync_ms']:.3f} |")


HEADER = ("| Cell | delta bytesPerSync | full-snapshot bytesPerSync | full/delta | delta saving | "
          "delta avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) | "
          "full avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms) |\n|---|---:|---:|---:|---:|---:|---:|")


def single_room():
    """single-room-entity-scaling's regenerate.py, for its gates (check) and its reader (value)."""
    spec = importlib.util.spec_from_file_location("single_room_regenerate", SINGLE_ROOM / "regenerate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def same_commit(a, b):
    """Two spellings of one commit: a common prefix of at least 7 hex digits."""
    if not (isinstance(a, str) and isinstance(b, str) and min(len(a), len(b)) >= 7):
        return False
    if not re.fullmatch(r"[0-9a-f]+", a) or not re.fullmatch(r"[0-9a-f]+", b):
        return False
    return a.startswith(b) or b.startswith(a)


def drift_commit(runs):
    """The one commit of the intended form's drift cells (merged); exits on none or several."""
    shas = {pick(runs, sync_strategy="delta", **cond)["meta"].get("git_sha") for _, _, _, cond in DRIFT_CELLS}
    if len(shas) != 1:
        sys.exit(f"drift cells from {len(shas)} commits {sorted(map(str, shas))}: the split needs one")
    return shas.pop()


def off_off(runs, commit, directory=None):
    """The split's input from single-room-entity-scaling's ablation at `commit`: (its commit,
    {point: (off-off, on-on) bytes per sync}). The ablation passes that topic's own gates first."""
    directory = ABLATION if directory is None else directory
    sr = single_room()
    ablation = sr.load(directory)
    if not ablation:
        sys.exit(f"drift split not usable: no single-room-entity-scaling results in {directory}")
    sr.check(ablation)  # every gate of that topic: form, repeats, build, server env, verify-views
    sha = ablation[0]["meta"]["git_sha"]  # check() refuses more than one commit
    problems, out = [], {}
    if not same_commit(sha, commit):
        problems.append(f"single-room ablation at {sha}, the re-run at {commit}: the split needs one commit")
    for label, pt, cell, cond in DRIFT_CELLS:
        forms = {r["params"]["form"] for r in ablation if r["params"]["cell"] == cell and sr.point(r) == pt}
        if not {"off-off", "on-on"} <= forms:
            problems.append(f"{label} {pt}: single-room has forms {sorted(forms)}, the split needs off-off and on-on")
            continue
        offoff, onon = sr.value(ablation, cell, pt, "off-off"), sr.value(ablation, cell, pt, "on-on")
        # One measurement, two precisions: EncodingBenchmark's bytesPerSync is the integer division
        # totalBytes / iterations (BenchmarkExecution.swift), which this topic's collect.py records;
        # single-room's collect.py records totalBytes / iterations unrounded. So the identity is
        # exactly the floor, with no other tolerance.
        rerun = pick(runs, sync_strategy="delta", **cond)["metrics"]["bytes_per_sync"]
        if math.floor(onon) != rerun:
            problems.append(f"{label} {pt}: single-room on-on {onon} isn't this topic's re-run {rerun} "
                            f"(floor {math.floor(onon)}): not the same measurement")
        out[pt] = (offoff, onon)
    if problems:
        sys.exit("drift split not usable (single-room-entity-scaling):\n  " + "\n  ".join(problems))
    return sha, out


def pct(a, b):
    return f"{(b - a) / a * 100:+.1f}%"


def tables(runs, offoff=None):
    """The topic's tables. `offoff` (off_off()) is given for the intended form: its drift table splits
    the drift into code changes and the wire form; the record's (None) compares with the archive alone."""
    out = []
    out.append("### Rooms axis (RQ1 workload: players 5 per room, natural spawn)\n")
    out.append(HEADER)
    for rooms in (10, 30, 50):
        d = pick(runs, axis="rooms", rooms=rooms, sync_strategy="delta", encoding="messagepack-pathhash")
        f = pick(runs, axis="rooms", rooms=rooms, sync_strategy="full-snapshot", encoding="messagepack-pathhash")
        out.append(pair_row(f"rooms {rooms} (players {5 * rooms})", d, f))
    out.append("\n### 10/30/50-room re-measurement (all rows measured at the same commit)\n")
    out.append("| Format / Strategy | Rooms | Total Players | bytesPerSync |\n|---|---:|---:|---:|")
    for label, enc, strat in (("JSON Object, delta", "json-object", "delta"),
                              ("Opcode MsgPack (PathHash), delta", "messagepack-pathhash", "delta"),
                              ("Opcode MsgPack (PathHash), full-snapshot", "messagepack-pathhash", "full-snapshot")):
        for rooms in (10, 30, 50):
            r = pick(runs, axis="rooms", rooms=rooms, sync_strategy=strat, encoding=enc)
            out.append(f"| {label} | {rooms} | {5 * rooms} | {fmt(r['metrics']['bytes_per_sync'])} |")
    out.append("\n### Monster axis (rooms 1, players 5 idle, |ΔSt| ↑)\n")
    out.append(HEADER)
    for cap in (4, 10, 50, 100):
        d = pick(runs, axis="monsters", monster_cap=cap, sync_strategy="delta")
        f = pick(runs, axis="monsters", monster_cap=cap, sync_strategy="full-snapshot")
        out.append(pair_row(f"monster cap {cap}", d, f))
    out.append("\n### Active-player axis (rooms 1, monster cap 4, every player moves every tick, |ΔSt| ≈ |R| = n)\n")
    out.append(HEADER)
    for p in (5, 10, 20, 50):
        d = pick(runs, axis="active", players=p, sync_strategy="delta")
        f = pick(runs, axis="active", players=p, sync_strategy="full-snapshot")
        out.append(pair_row(f"players {p}", d, f))
    out.append("\n### 100/300/500-room re-measurement (same commit)\n")
    out.append("| Format / Strategy | Rooms | Total Players | bytesPerSync |\n|---|---:|---:|---:|")
    for label, enc, strat in (("JSON Object, delta", "json-object", "delta"),
                              ("Opcode MsgPack (PathHash), delta", "messagepack-pathhash", "delta"),
                              ("Opcode MsgPack (PathHash), full-snapshot", "messagepack-pathhash", "full-snapshot")):
        for rooms in (100, 300, 500):
            r = pick(runs, axis="rooms-large", rooms=rooms, sync_strategy=strat, encoding=enc)
            out.append(f"| {label} | {rooms} | {5 * rooms} | {fmt(r['metrics']['bytes_per_sync'])} |")
    # Drift check against the archived single-room-entity-scaling delta cells.
    out.append("\n### Drift check: re-run delta cells vs archived `single-room-entity-scaling`\n")
    if offoff is not None:
        arch = load(ARCHIVE)
        sha, split = offoff
        cells = [(label, pt, pick(arch, players=pt[0], monster_cap=pt[1], encoding="messagepack-pathhash", workload=pt[2]),
                  pick(runs, sync_strategy="delta", **cond)) for label, pt, _, cond in DRIFT_CELLS]
        archived = ", ".join(f"`{c}`" for c in sorted({a["meta"]["git_sha"][:7] for _, _, a, _ in cells}))
        # code changes = off/off / archived - 1; an archived value short by under 1 B moves it by under
        # off/off / archived² (in percentage points, x100), largest where archived is smallest.
        bound = max(100 * split[pt][0] / a["metrics"]["bytes_per_sync"] ** 2 for _, pt, a, _ in cells)
        out.append(DRIFT_CAPTION.format(archived=archived, offoff=f"`{sha[:7]}`", bound=bound))
        out.append("| Cell | archived | off/off, same commit | re-run (on/on) | code changes | wire form |\n"
                   "|---|---:|---:|---:|---:|---:|")
        for label, pt, a, r in cells:
            (ob, onb), ab, rb = split[pt], a["metrics"]["bytes_per_sync"], r["metrics"]["bytes_per_sync"]
            num = pt[1] if pt[2] == "idle" else pt[0]
            out.append(f"| {label} {num} | {fmt(ab)} | {fmt(ob)} | {fmt(rb)} | {pct(ab, ob)} | {pct(ob, onb)} |")
    else:
        out.append("| Cell | archived bytesPerSync | re-run bytesPerSync | drift |\n|---|---:|---:|---:|")
    if offoff is None and ARCHIVE.exists():
        arch = load(ARCHIVE)
        for cap in (4, 10, 50, 100):
            a = pick(arch, players=5, monster_cap=cap, encoding="messagepack-pathhash", workload="idle")
            r = pick(runs, axis="monsters", monster_cap=cap, sync_strategy="delta")
            ab, rb = a["metrics"]["bytes_per_sync"], r["metrics"]["bytes_per_sync"]
            out.append(f"| monster cap {cap} | {fmt(ab)} | {fmt(rb)} | {(rb - ab) / ab * 100:+.1f}% |")
        for p in (5, 10, 20, 50):
            a = pick(arch, players=p, monster_cap=4, encoding="messagepack-pathhash", workload="active")
            r = pick(runs, axis="active", players=p, sync_strategy="delta")
            ab, rb = a["metrics"]["bytes_per_sync"], r["metrics"]["bytes_per_sync"]
            out.append(f"| active players {p} | {fmt(ab)} | {fmt(rb)} | {(rb - ab) / ab * 100:+.1f}% |")
    out.append("\n### Rooms axis vs the archived 2026-01/02 payload tables (per-room bytesPerSync)\n")
    out.append("| Format | archived 2026-01-25 (10 rooms) | archived 2026-02-06 (100 rooms) | this topic (10 rooms) | this topic (100 rooms) |\n|---|---:|---:|---:|---:|")
    archive_vi = {"json-object": 17627, "messagepack-pathhash": 4572}
    archive_ix = {"json-object": 175471, "messagepack-pathhash": 49851}
    for label, enc in (("JSON Object", "json-object"), ("Opcode MsgPack (PathHash)", "messagepack-pathhash")):
        r10 = pick(runs, axis="rooms", rooms=10, sync_strategy="delta", encoding=enc)
        r100 = pick(runs, axis="rooms-large", rooms=100, sync_strategy="delta", encoding=enc)
        out.append(f"| {label} | {archive_vi[enc] / 10:,.1f} | {archive_ix[enc] / 100:,.1f} | "
                   f"{r10['metrics']['bytes_per_sync'] / 10:,.1f} | {r100['metrics']['bytes_per_sync'] / 100:,.1f} |")
    return "\n".join(out) + "\n"


def check_invariants(runs):
    for r in runs:
        if r["params"]["sync_strategy"] != "delta":
            continue
        if r["params"]["encoding"] != "messagepack-pathhash":
            continue
        cond = {k: r["params"][k] for k in ("axis", "players", "rooms", "monster_cap", "encoding")}
        f = pick(runs, sync_strategy="full-snapshot", **cond)
        if f["metrics"]["bytes_per_sync"] < r["metrics"]["bytes_per_sync"]:
            sys.exit(f"invariant violated: full < delta for {cond}")


ROOM_BOUND = 0.005  # per-room bytesPerSync, 10 vs 100 rooms


def mean_index_digits(rooms):
    """Mean number of decimal digits in the room indices 0..rooms-1."""
    return sum(len(str(i)) for i in range(rooms)) / rooms


def id_length_term(players, rooms):
    """Bytes per room per sync that a full snapshot spends on room-index digits in IDs.

    The benchmark's player IDs carry the room index (`room<i>-player-<j>`), and a full
    snapshot resends every player's ID as a string key in every recipient's snapshot each
    sync: players x players occurrences per room, one byte each per index digit. Delta
    sends a slot number after the first use, so its rows don't carry this term."""
    return players * players * mean_index_digits(rooms)


def check_room_consistency(runs, bound=ROOM_BOUND):
    """Per-room bytesPerSync must agree between 10 and 100 rooms within ``bound``, per sweep
    repeat and per row. Delta rows are compared as measured. Full-snapshot rows are compared
    after removing the identifier-length term, which grows with the room count by design."""
    rows = {}
    for r in runs:
        p = r["params"]
        if (p["axis"], p["rooms"]) not in (("rooms", 10), ("rooms-large", 100)):
            continue
        key = (p.get("repeat"), p["encoding"], p["sync_strategy"])
        rows.setdefault(key, {})[p["rooms"]] = r
    failures = []
    for (repeat, encoding, strategy), by_rooms in sorted(rows.items(), key=lambda kv: str(kv[0])):
        if set(by_rooms) != {10, 100}:
            continue
        per_room = {}
        for rooms, r in by_rooms.items():
            value = r["metrics"]["bytes_per_sync"] / rooms
            if strategy == "full-snapshot":
                value -= id_length_term(r["params"]["players"], rooms)
            elif strategy != "delta":
                sys.exit(f"room consistency: no rule for sync strategy {strategy!r}")
            per_room[rooms] = value
        diff = (per_room[100] - per_room[10]) / per_room[10]
        if abs(diff) > bound:
            failures.append(f"repeat {repeat}, {encoding} {strategy}: per-room bytes 10 vs 100 rooms "
                            f"{per_room[10]:.2f} vs {per_room[100]:.2f} ({diff * 100:+.3f} %)")
    if failures:
        sys.exit("room consistency violated (bound %.1f %%):\n  " % (bound * 100) + "\n  ".join(failures))


def results_section(readme):
    marker = "## Results"
    if marker not in readme:
        print("README.md has no '## Results' section", file=sys.stderr)
        sys.exit(1)
    body = readme.split(marker, 1)[1]
    nxt = body.find("\n## ")
    return body[:nxt] if nxt != -1 else body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    current, record = partition(load(RESULTS))
    parts = [f"Wire form of these tables: {caption(*INTENDED)}, checked per run.\n"]
    if current:
        check_room_consistency(current)  # per repeat, before the medians
        current = merge_repeats(current)
        check_invariants(current)
        try:
            # The pre-refreeze record spans three commits by design, so only the repeats get the line.
            head = provenance.line(provenance.from_results(current), node=False)
        except provenance.Refused as e:
            sys.exit(f"results not usable:\n  {e}")
        parts.append(f"{head}\n")
        parts.append(f"Each value is the median over repeats {REPEATS[0]}–{REPEATS[-1]} of its cell.\n")
        parts.append(tables(current, offoff=off_off(current, drift_commit(current))))
    else:
        parts.append("No runs in this form yet.\n")
    if record:
        check_invariants(record)
        check_room_consistency(record)
        commits = ", ".join(sorted({r["meta"]["git_sha"] for r in record}))
        parts.append(f"### Pre-refreeze record ({caption(*RECORD)}; commit {commits})\n\n"
                     "Measured before the path index and field merge existed. Kept as the record of that form, "
                     "not compared with the tables above.\n")
        parts.append(re.sub(r"(?m)^### ", "#### ", tables(record)))
    md = "\n".join(parts)
    if args.check:
        readme = (TOPIC / "README.md").read_text()
        ok = results_section(readme).strip() == md.strip()
        print("OK" if ok else "MISMATCH")
        sys.exit(0 if ok else 1)
    print(md)


if __name__ == "__main__":
    main()
