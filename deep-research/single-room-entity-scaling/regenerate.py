#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from results/*.json and results/pre-refreeze/*.json
(stdlib only).

Usage: python3 regenerate.py [--markdown] | python3 regenerate.py --check

results/ holds the wire-form ablation (run.sh, collect.py): every point of the matrix in five
forms, every repeat. Before any table is built, every result must come from a clean release
build on the measurement host's pinned CPUs with the shipped server environment, in the wire form
its form label declares (deep-research/wireform.py), with the matrix's parameters; every point
needs every form in every repeat, the same bytes in every repeat, a passed verify-views gate, and
off/off bytes that differ from on/on (equal bytes mean the knobs never reached the encoder).
results/pre-refreeze/ holds the 2026-08-31 runs, both knobs off: rendered as that record, under
a heading that names its form, never compared with the ablation.
"""
import argparse, json, pathlib, re, sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC.parent))
import serverenv  # noqa: E402
import wireform  # noqa: E402

RESULTS = TOPIC / "results"
RECORD = RESULTS / "pre-refreeze"
REPEATS = (1, 2)
# The matrix (run.sh's cells): cell -> (players, monster cap, workload) points.
POINTS = {
    **{f"monsters-cap{cap}": [(5, cap, "idle")] for cap in (4, 10, 50, 100)},
    "idle-players": [(p, 4, "idle") for p in (10, 20, 50)],
    "active-players": [(p, 4, "active") for p in (5, 10, 20, 50)],
    "joint": [(20, 20, "active")],
}
# Form label -> (EncodingBenchmark --format, pathIndex, fieldMerge). JSON runs with the shipped
# defaults; the knobs don't change its bytes.
FORMS = {
    "json": ("json-object", True, True),
    "on-on": ("messagepack-pathhash", True, True),
    "on-off": ("messagepack-pathhash", True, False),
    "off-on": ("messagepack-pathhash", False, True),
    "off-off": ("messagepack-pathhash", False, False),
}
FIXED = {"rooms": 1, "iterations": 200, "ticks_per_sync": 2, "parallel": False, "sync_strategy": "delta"}
EMPTY = "_No ablation results yet: the measurement host's run fills this section._"
LABEL = {"json-object": "JSON Object", "messagepack-pathhash": "Opcode MsgPack (PathHash)"}


def load(directory):
    return [json.loads(p.read_text()) for p in sorted(directory.glob("*.json"))]


def point(r):
    p = r["params"]
    return (p["players"], p["monster_cap"], p["workload"])


def check(runs, points=None, repeats=REPEATS):
    """Refuse unusable or partial ablation results (the tests pass a fixture's own points)."""
    points = POINTS if points is None else points
    failures = []
    bytes_by = {}
    gated = set()
    for r in runs:
        p, m, meta = r["params"], r["metrics"], r["meta"]
        name = f"{p['cell']} p{p['players']} {p['form']} rep{p['repeat']}"
        if meta.get("build_config") != "release":
            failures.append(f"{name}: not a release build")
        if meta.get("git_dirty") is not False:
            failures.append(f"{name}: not from a clean tree (git dirty: {meta.get('git_dirty')})")
        if not meta.get("swift_version"):
            failures.append(f"{name}: no Swift version recorded")
        if not meta.get("pin_cpus"):
            failures.append(f"{name}: unpinned (a smoke run off the measurement host)")
        if env := serverenv.failure(name, meta.get("server_env")):
            failures.append(env)
        if meta.get("dynamic_key_compression") is not True:
            failures.append(f"{name}: dynamic key compression {meta.get('dynamic_key_compression')}, not the default (on)")
        for key, want in FIXED.items():
            if p.get(key) != want:
                failures.append(f"{name}: {key} {p.get(key)!r}, the matrix has {want!r}")
        if p["cell"] not in points or point(r) not in points[p["cell"]]:
            failures.append(f"{name}: not a point of the matrix")
            continue
        if p["form"] not in FORMS:
            failures.append(f"{name}: unknown form")
            continue
        encoding, path_index, field_merge = FORMS[p["form"]]
        if p["encoding"] != encoding:
            failures.append(f"{name}: format {p['encoding']}, the form is {encoding}")
        try:
            form = wireform.resolve(meta.get("git_sha"), p["encoding"],
                                    path_index=meta.get("path_index"), field_merge=meta.get("field_merge"))
            want = wireform.WireForm(p["encoding"], path_index, field_merge)
            if form != want:
                failures.append(f"{name}: ran {form.caption()}, its label says {want.caption()}")
        except wireform.MissingWireForm as missing:
            failures.append(f"{name}: wire form missing: {missing}")
        if m.get("gate_passed") is False:
            failures.append(f"{name}: the verify-views gate failed")
        if m.get("gate_passed"):
            gated.add((p["cell"], point(r), p["form"]))
        bytes_by.setdefault((p["cell"], point(r), p["form"]), {}).setdefault(p["repeat"], []).append(m["total_bytes"])
    if runs:
        shas = {r["meta"].get("git_sha") for r in runs}
        if len(shas) != 1:
            failures.append(f"results from {len(shas)} commits {sorted(map(str, shas))}: the ablation is one commit's")
        for cell, pts in points.items():
            for pt in pts:
                for form in FORMS:
                    key = (cell, pt, form)
                    by_repeat = bytes_by.get(key, {})
                    for rep in repeats:
                        if len(by_repeat.get(rep, [])) != 1:
                            failures.append(f"{cell} p{pt[0]} {form}: {len(by_repeat.get(rep, []))} results for repeat {rep}, expected 1")
                    values = {b for bs in by_repeat.values() for b in bs}
                    if len(values) > 1:
                        failures.append(f"{cell} p{pt[0]} {form}: bytes differ between repeats {dict(sorted(by_repeat.items()))}")
                    if by_repeat and key not in gated:
                        failures.append(f"{cell} p{pt[0]} {form}: no repeat passed the verify-views gate")
                # The metadata records the requested modes, not what the encoder did: a knob that
                # reaches the encoder changes the bytes at every point (each has repeated paths to
                # index and parents with several changed fields to merge), so equal bytes with it
                # on and off mean it didn't. No point is exempt.
                got = {f: {b for bs in bytes_by.get((cell, pt, f), {}).values() for b in bs} for f in ("on-on", "off-off", "on-off", "off-on")}
                for other, knob in (("off-off", "the knobs"), ("off-on", "the path index"), ("on-off", "the field merge")):
                    if got["on-on"] and got[other] and got["on-on"] == got[other]:
                        failures.append(f"{cell} p{pt[0]}: {other} bytes equal on-on bytes: {knob} didn't reach the encoder")
    if failures:
        sys.exit("results not usable:\n  " + "\n  ".join(failures))


def check_record(runs):
    """The pre-refreeze record must resolve to both knobs off (its commits predate them)."""
    problems = []
    for r in runs:
        try:
            form = wireform.resolve(r["meta"].get("git_sha"), r["params"]["encoding"],
                                    path_index=r["meta"].get("path_index"), field_merge=r["meta"].get("field_merge"))
        except wireform.MissingWireForm as missing:
            problems.append(f"{r['meta'].get('source_file')}: wire form missing: {missing}")
            continue
        if (form.path_index, form.field_merge) != (False, False):
            problems.append(f"{r['meta'].get('source_file')}: {form.caption()}, the record is both knobs off")
    if problems:
        sys.exit("pre-refreeze record not usable:\n  " + "\n  ".join(problems))


def value(runs, cell, pt, form):
    hits = [r["metrics"]["bytes_per_sync"] for r in runs if r["params"]["cell"] == cell and point(r) == pt and r["params"]["form"] == form]
    return hits[0]


def pct(a, b):
    return f"{(1 - a / b) * 100:.1f}%"


ABLATION_AXES = (
    ("Monster axis (idle, players = 5)", [(f"monsters-cap{c}", (5, c, "idle")) for c in (4, 10, 50, 100)]),
    ("Player axis — idle players (monster cap = 4)",
     [("monsters-cap4", (5, 4, "idle"))] + [("idle-players", (p, 4, "idle")) for p in (10, 20, 50)]),
    ("Player axis — active players (monster cap = 4)", [("active-players", (p, 4, "active")) for p in (5, 10, 20, 50)]),
    ("Joint cell — active, players 20 × monster cap 20", [("joint", (20, 20, "active"))]),
)


def tables(runs):
    if not runs:
        return EMPTY + "\n"
    repeats = sorted({r["params"]["repeat"] for r in runs})
    commit = next(iter({r["meta"]["git_sha"] for r in runs}))
    out = [f"Wire-form ablation at commit {commit[:8]}, the shipped sync path (USE_SNAPSHOT_FOR_SYNC unset), delta "
           f"strategy, serial sync; bytesPerSync per form (identical in repeats {', '.join(map(str, repeats))}). "
           "The MsgPack columns are messagepack-pathhash with the path index (PI) and field merge (FM) on or off; "
           "on/on is the shipped default. JSON Object is the reference (neither knob applies to it). "
           "Saving: on/on against off/off; PI alone and FM alone: that knob on, the other off, against off/off."]
    for title, pts in ABLATION_AXES:
        pts = [(c, pt) for c, pt in pts if any(r["params"]["cell"] == c and point(r) == pt for r in runs)]
        if not pts:
            continue
        out.append(f"\n### {title}\n")
        out.append("| players | monster cap | JSON Object | MsgPack off/off | PI only | FM only | on/on | saving on/on | saving PI alone | saving FM alone |")
        out.append("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for cell, pt in pts:
            v = {f: value(runs, cell, pt, f) for f in FORMS}
            out.append(f"| {pt[0]} | {pt[1]} | {v['json']:,.0f} | {v['off-off']:,.0f} | {v['on-off']:,.0f} | {v['off-on']:,.0f} | "
                       f"{v['on-on']:,.0f} | {pct(v['on-on'], v['off-off'])} | {pct(v['on-off'], v['off-off'])} | {pct(v['off-on'], v['off-off'])} |")
    return "\n".join(out) + "\n"


def pick(runs, **cond):
    out = [r for r in runs if all(r["params"][k] == v for k, v in cond.items())]
    return sorted(out, key=lambda r: (r["params"]["encoding"], r["params"]["players"], r["params"]["monster_cap"]))


def row(r, per_player=False):
    m, p = r["metrics"], r["params"]
    cells = [LABEL[p["encoding"]], str(p["players"]), str(p["monster_cap"]), str(m["final_monster_count"]), f"{m['bytes_per_sync']:.0f}"]
    if per_player:
        cells.append(f"{m['bytes_per_player_per_sync']:.0f}")
    return "| " + " | ".join(cells) + " |"


HDR = "| Format | players | monster cap | final monsters | bytesPerSync |"
SEP = "|---|---:|---:|---:|---:|"
HDR_PP = HDR + " bytes/player |"
SEP_PP = SEP + "---:|"


def record_tables(runs) -> str:
    """The 2026-08-31 tables, unchanged but for their heading level."""
    commits = ", ".join(sorted({r["meta"]["git_sha"] for r in runs}))
    out = [f"### Pre-refreeze record (pathIndex off, fieldMerge off; USE_SNAPSHOT_FOR_SYNC=false; commits {commits})\n",
           "Measured on 2026-08-31 before the path index and field merge existed, on the legacy sync path, on a "
           "development machine (Apple M2, Swift 6.3.2). Kept as the record of that form, not compared with the tables above."]
    out.append("\n#### Monster axis (idle, players = 5)\n")
    out.append(HDR); out.append(SEP)
    out.extend(row(r) for r in pick(runs, workload="idle", players=5))
    out.append("\n#### Player axis — idle players (monster cap = 4)\n")
    out.append(HDR_PP); out.append(SEP_PP)
    out.extend(row(r, True) for r in pick(runs, workload="idle", monster_cap=4))
    out.append("\n#### Player axis — active players (monster cap = 4)\n")
    out.append(HDR_PP); out.append(SEP_PP)
    out.extend(row(r, True) for r in pick(runs, workload="active", monster_cap=4))
    out.append("\n#### Joint cell — active, players and monsters raised together\n")
    out.append(HDR_PP); out.append(SEP_PP)
    joint = pick(runs, workload="active", players=20, monster_cap=4) + pick(runs, workload="active", players=20, monster_cap=20)
    out.extend(row(r, True) for r in sorted(joint, key=lambda r: (r["params"]["encoding"], r["params"]["monster_cap"])))
    out.append("\n#### Marginal payload cost per monster (idle, players = 5, cap 4 → 100)\n")
    out.append("| Format | bytes/monster |")
    out.append("|---|---:|")
    by = {(r["params"]["encoding"], r["params"]["monster_cap"]): r["metrics"]["bytes_per_sync"] for r in pick(runs, workload="idle", players=5)}
    for enc in ("json-object", "messagepack-pathhash"):
        out.append(f"| {LABEL[enc]} | {(by[(enc, 100)] - by[(enc, 4)]) / 96.0:.1f} |")
    return "\n".join(out) + "\n"


def results_markdown():
    runs, record = load(RESULTS), load(RECORD)
    check(runs)
    check_record(record)
    return tables(runs) + ("\n" + record_tables(record) if record else "")


def results_section(readme: str) -> str:
    if "## Results" not in readme:
        sys.exit("README.md has no '## Results' section")
    start = readme.index("## Results")
    end = readme.find("\n## ", start + 1)
    body = readme[start:end if end != -1 else None]
    return body.split("\n", 1)[1].strip() + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--markdown", action="store_true", help="Equivalent to no arguments; kept for explicitness.")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    t = results_markdown()
    if a.check:
        if results_section((TOPIC / "README.md").read_text()).strip() != t.strip():
            print("MISMATCH")
            sys.exit("README.md ## Results does not match regenerated tables")
        print("OK")
    else:
        print(t, end="")


if __name__ == "__main__":
    main()
