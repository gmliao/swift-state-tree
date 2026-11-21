#!/usr/bin/env python3
"""Classifies the differential goldens' changes between two commits, by cause (#546 L2 plan §5.1).

Usage: scripts/classify-golden-changes.py <old-commit> [<new-commit>]

Reads every golden at both commits (the new one defaults to the working tree) and compares the
decoded content, ignoring `recordedWith` and the record's bytes (the decoded record is compared
instead). Each changed leaf is classified:

  1 turnKind   a sync output's `turnKind`, `legacyCycle` -> `syncOnly`
  2 positions  a turn position (`afterPass`, `sequence`, `passOrdinal`, ...) moved
  other        anything else: needs its own explanation, or it is a bug

Files only at one side are listed as added or removed. Exits 1 when an `other` change exists.
"""
import json
import subprocess
import sys
from pathlib import Path

GOLDEN = "Tests/SwiftStateTreeNIOTests/Differential/Golden"
POSITION_KEYS = {"afterPass", "sequence", "passOrdinal", "turnIndex", "tickId", "streamIndex"}


def files_at(commit):
    if commit is None:
        return {p.name: p.read_text(encoding="utf-8") for p in Path(GOLDEN).glob("*.json") if p.name != "index.json"}
    names = subprocess.run(
        ["git", "ls-tree", "--name-only", f"{commit}:{GOLDEN}"], check=True, capture_output=True, text=True, encoding="utf-8"
    ).stdout.split()
    out = {}
    for name in names:
        if name == "index.json" or not name.endswith(".json"):
            continue
        out[name] = subprocess.run(
            ["git", "show", f"{commit}:{GOLDEN}/{name}"], check=True, capture_output=True, text=True, encoding="utf-8"
        ).stdout
    return out


def comparable(text):
    doc = json.loads(text)
    doc.pop("recordedWith", None)
    record = doc.get("result", {}).get("record")
    if isinstance(record, dict):
        record.pop("bytes", None)
    return doc


def leaves(a, b, path=""):
    """Yields (path, old, new) for every differing leaf."""
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            yield from leaves(a.get(key), b.get(key), f"{path}.{key}" if path else key)
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            yield from leaves(x, y, f"{path}[{i}]")
    elif a != b:
        yield path, a, b


def classify(path, old, new):
    key = path.rsplit(".", 1)[-1]
    if key == "turnKind" and old == "legacyCycle" and new == "syncOnly":
        return "1 turnKind"
    if key in POSITION_KEYS:
        return "2 positions"
    return "other"


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    old = files_at(sys.argv[1])
    new = files_at(sys.argv[2] if len(sys.argv) == 3 else None)
    counts = {}
    others = []
    for name in sorted(set(old) | set(new)):
        if name not in new:
            print(f"removed  {name}")
            continue
        if name not in old:
            print(f"added    {name}")
            continue
        changes = list(leaves(comparable(old[name]), comparable(new[name])))
        if not changes:
            continue
        causes = {}
        for path, a, b in changes:
            cause = classify(path, a, b)
            causes[cause] = causes.get(cause, 0) + 1
            counts[cause] = counts.get(cause, 0) + 1
            if cause == "other":
                others.append(f"{name}: {path}: {json.dumps(a)[:80]} -> {json.dumps(b)[:80]}")
        summary = ", ".join(f"{cause} x{n}" for cause, n in sorted(causes.items()))
        print(f"changed  {name}: {summary}")
    print("totals: " + (", ".join(f"{cause} x{n}" for cause, n in sorted(counts.items())) or "no changes"))
    for line in others:
        print(f"OTHER    {line}")
    return 1 if others else 0


if __name__ == "__main__":
    sys.exit(main())
