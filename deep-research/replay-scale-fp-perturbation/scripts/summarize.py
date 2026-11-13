#!/usr/bin/env python3
"""Builds results/batch-<format>-<arch>.json and the SHA256SUMS list from a run-batch.sh output dir.

Usage: summarize.py <out-dir> <host> <swift> <arch> <json-out> <sums-out>

The commit is the batch's own: run-batch.sh's source.json (`git rev-parse HEAD` and the dirty flag,
read before it built the runner, and again after the last seed). A batch without it, not built by
run-batch.sh, from a dirty tree, or whose commit or tree changed while it ran, is refused.

The record format is read from each verify log (`Record: <version>, complete`), never assumed: every
recording of a batch must name the same one. The SHA256SUMS list names each file as run-batch.sh
wrote it (`s<N>.sstr`; a 2.5 batch's were `s<N>.json`), the archive's byte checksums. With a
second recording per seed (run-batch.sh TWICE=1), each recording carries
`second_recording_identical`, the determinism check: the two recordings' JSON views (`--convert`)
have the same sha256. `second_recording_bytes_identical` says whether the files are byte-identical
too, and `split_ticks` gives each file's ticks split into several turn records (#327), the reason
bytes can differ with the same content. A row without a content digest (a failed `--convert`) is
refused.
"""
import hashlib
import json
import pathlib
import re
import sys


def num(text, label):
    m = re.search(rf"{re.escape(label)}: (\d+)", text)
    return int(m.group(1)) if m else None


def record_format(log):
    m = re.search(r"Record: ([0-9][^,\s]*), complete", log)
    return m.group(1) if m else None


def source(out):
    """The batch's commit from source.json; exits when it's missing, unreadable or dirty."""
    path = out / "source.json"
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        sys.exit(f"{path}: the batch's commit isn't recorded ({e}); rerun with run-batch.sh")
    commit = record.get("commit")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        sys.exit(f"{path}: no commit recorded ({commit!r})")
    if record.get("dirty") is not False:
        sys.exit(f"{path}: the batch ran from a dirty tree: {record.get('status')}")
    if record.get("built") is not True:
        sys.exit(f"{path}: the runner wasn't built by run-batch.sh from this tree (built {record.get('built')!r})")
    if record.get("commitAtEnd") != commit:
        sys.exit(f"{path}: the commit changed while the batch ran ({commit} -> {record.get('commitAtEnd')!r})")
    if record.get("dirtyAtEnd") is not False:
        sys.exit(f"{path}: the tree was dirty after the last seed: {record.get('statusAtEnd')}")
    return commit


def summarize(out, host, swift, arch):
    """(the batch document, the SHA256SUMS text); exits on a batch the table can't use."""
    out = pathlib.Path(out)
    git_sha = source(out)[:8]
    recs, sums, formats = [], [], set()
    for line in (out / "summary.tsv").read_text(encoding="utf-8").splitlines():
        cols = line.split("\t")
        seed, players, move_every, ticks, rec_exit, ver_exit, sha = cols[:7]
        second = cols[7] if len(cols) > 7 else ""
        content, content2, split, split2 = (cols[8:12] + ["", "", "", ""])[:4]
        log = (out / "logs" / f"s{seed}.verify.log").read_text(encoding="utf-8")
        formats.add(record_format(log))
        name = next((p.name for p in (out / "records").glob(f"s{seed}.*")), f"s{seed}")
        mism = re.search(r"mismatched ticks vs recorded=(\d+)", log)
        rec = {
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
        }
        if not content:
            sys.exit(f"seed {seed}: no content digest (--convert failed; see {out}/views)")
        rec["content_sha256"] = content
        rec["split_ticks"] = [int(split) if split else None]
        if second:
            if not content2:
                sys.exit(f"seed {seed}: no content digest for the second recording (--convert failed; see {out}/views)")
            rec["second_recording_identical"] = content2 == content
            rec["second_recording_bytes_identical"] = second == sha
            rec["split_ticks"].append(int(split2) if split2 else None)
        recs.append(rec)
        sums.append(f"{sha}  {name}")
    if not recs:
        sys.exit(f"{out}/summary.tsv lists no recordings")
    if len(formats) != 1 or None in formats:
        sys.exit(f"record formats in the verify logs: {sorted(map(str, formats))} (one is required)")
    sums.sort(key=lambda l: l.split("  ")[1])  # name sort, as batch-2.4/2.5-SHA256SUMS.txt
    sums_text = "\n".join(sums) + "\n"
    doc = {
        "meta": {
            "record_format": formats.pop(), "git_sha": git_sha, "git_dirty": False,
            "host": host, "swift": swift, "arch": arch,
            "build": "release", "sha256sums_sha256": hashlib.sha256(sums_text.encode()).hexdigest(),
        },
        "recordings": sorted(recs, key=lambda r: r["seed"]),
    }
    return doc, sums_text


def main(argv):
    out, host, swift, arch, json_out, sums_out = argv[:6]
    doc, sums_text = summarize(out, host, swift, arch)
    pathlib.Path(sums_out).write_text(sums_text, encoding="utf-8")
    pathlib.Path(json_out).write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    recs = doc["recordings"]
    print(json.dumps({k: doc["meta"][k] for k in ("record_format", "sha256sums_sha256")}),
          "recordings", len(recs),
          "verified", sum(r["verified_vs_recorded"] and r["verified_run1_vs_run2"] for r in recs),
          "mismatches", sum(r["mismatch_ticks"] for r in recs),
          "ticks", sum(r["ticks"] or 0 for r in recs),
          "hashed", sum(r["ticks_with_state_hash"] or 0 for r in recs),
          "second recordings identical", sum(r.get("second_recording_identical", False) for r in recs),
          "in bytes", sum(r.get("second_recording_bytes_identical", False) for r in recs))


if __name__ == "__main__":
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    main(sys.argv[1:])
