#!/usr/bin/env python3
"""Regenerate every table in README.md from results/*.json (stdlib only).

Usage: python3 regenerate.py [--markdown] | python3 regenerate.py --check
"""
import argparse, json, pathlib, sys

TOPIC = pathlib.Path(__file__).parent
RESULTS = TOPIC / "results"
ARCHIVE = TOPIC.parent / "single-room-entity-scaling" / "results"


def load(directory):
    return [json.load(open(p)) for p in sorted(directory.glob("*.json"))]


def pick(runs, **cond):
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
          "delta avgCostPerSyncMs | full avgCostPerSyncMs |\n|---|---:|---:|---:|---:|---:|---:|")


def tables(runs):
    out = []
    out.append("### Rooms axis (RQ1 workload: players 5 per room, natural spawn)\n")
    out.append(HEADER)
    for rooms in (10, 30, 50):
        d = pick(runs, axis="rooms", rooms=rooms, sync_strategy="delta", encoding="messagepack-pathhash")
        f = pick(runs, axis="rooms", rooms=rooms, sync_strategy="full-snapshot", encoding="messagepack-pathhash")
        out.append(pair_row(f"rooms {rooms} (players {5 * rooms})", d, f))
    out.append("\n### Table VI replacement (all rows measured at the same commit)\n")
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
    out.append("\n### Table IX replacement (100/300/500 rooms, same commit)\n")
    out.append("| Format / Strategy | Rooms | Total Players | bytesPerSync |\n|---|---:|---:|---:|")
    for label, enc, strat in (("JSON Object, delta", "json-object", "delta"),
                              ("Opcode MsgPack (PathHash), delta", "messagepack-pathhash", "delta"),
                              ("Opcode MsgPack (PathHash), full-snapshot", "messagepack-pathhash", "full-snapshot")):
        for rooms in (100, 300, 500):
            r = pick(runs, axis="rooms-large", rooms=rooms, sync_strategy=strat, encoding=enc)
            out.append(f"| {label} | {rooms} | {5 * rooms} | {fmt(r['metrics']['bytes_per_sync'])} |")
    # Drift check against the archived single-room-entity-scaling delta cells.
    out.append("\n### Drift check: re-run delta cells vs archived `single-room-entity-scaling`\n")
    out.append("| Cell | archived bytesPerSync | re-run bytesPerSync | drift |\n|---|---:|---:|---:|")
    if ARCHIVE.exists():
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
    out.append("\n### Rooms axis vs the paper's archived RQ1 tables (per-room bytesPerSync)\n")
    out.append("| Format | archived Table VI (2026-01-25, 10 rooms) | archived Table IX (2026-02-06, 100 rooms) | this topic (10 rooms) | this topic (100 rooms) |\n|---|---:|---:|---:|---:|")
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
    runs = load(RESULTS)
    check_invariants(runs)
    md = tables(runs)
    if args.check:
        readme = (TOPIC / "README.md").read_text()
        ok = results_section(readme).strip() == md.strip()
        print("OK" if ok else "MISMATCH")
        sys.exit(0 if ok else 1)
    print(md)


if __name__ == "__main__":
    main()
