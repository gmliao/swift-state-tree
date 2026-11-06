#!/usr/bin/env python3
"""Builds results/batch-2.5-<arch>.json and the SHA256SUMS list from a run-batch.sh output dir.

Usage: summarize.py <out-dir> <git-sha> <host> <swift> <arch> <json-out> <sums-out>
"""
import hashlib
import json
import re
import sys

out, git_sha, host, swift, arch, json_out, sums_out = sys.argv[1:8]


def num(text, label):
    m = re.search(rf"{re.escape(label)}: (\d+)", text)
    return int(m.group(1)) if m else None


recs = []
sums = []
for line in open(f"{out}/summary.tsv"):
    seed, players, move_every, ticks, rec_exit, ver_exit, sha = line.rstrip("\n").split("\t")
    log = open(f"{out}/logs/s{seed}.verify.log").read()
    mism = re.search(r"mismatched ticks vs recorded=(\d+)", log)
    recs.append({
        "seed": int(seed), "players": int(players), "move_every": int(move_every),
        "ticks": num(log, "Total Ticks"),
        "ticks_with_state_hash": num(log, "Ticks with State Hash"),
        "actions": num(log, "Actions"),
        "client_events": num(log, "Client Events"),
        "record_exit": int(rec_exit), "verify_exit": int(ver_exit),
        "mismatch_ticks": int(mism.group(1)) if mism else 0,
        "verified_vs_recorded": "computed hashes match recorded ground truth" in log,
        "verified_run1_vs_run2": "identical across two re-evaluation runs" in log,
        "sha256": sha,
    })
    sums.append(f"{sha}  s{seed}.json")

sums.sort(key=lambda l: l.split("  ")[1])  # same order as batch-2.4-SHA256SUMS.txt (name sort)
sums_text = "\n".join(sums) + "\n"
open(sums_out, "w").write(sums_text)
doc = {
    "meta": {
        "record_format": "2.5", "git_sha": git_sha, "host": host, "swift": swift, "arch": arch,
        "build": "release", "sha256sums_sha256": hashlib.sha256(sums_text.encode()).hexdigest(),
    },
    "recordings": sorted(recs, key=lambda r: r["seed"]),
}
open(json_out, "w").write(json.dumps(doc, indent=2, sort_keys=True) + "\n")
print(json.dumps({k: doc["meta"][k] for k in ("sha256sums_sha256",)}),
      "recordings", len(recs),
      "verified", sum(r["verified_vs_recorded"] and r["verified_run1_vs_run2"] for r in recs),
      "mismatches", sum(r["mismatch_ticks"] for r in recs),
      "ticks", sum(r["ticks"] or 0 for r in recs),
      "hashed", sum(r["ticks_with_state_hash"] or 0 for r in recs))
