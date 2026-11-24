#!/usr/bin/env python3
"""Classifies the differential goldens' changes between two commits, by cause (#546 L2 plan §5.1).

Usage: scripts/classify-golden-changes.py <old-commit> [<new-commit>]
       scripts/classify-golden-changes.py --self-test

Reads every golden at both commits (the new one defaults to the working tree) and compares the
decoded content, ignoring `recordedWith` and the record's bytes (the decoded record is compared
instead). Each changed leaf is classified:

  1 turnKind   a sync output's `turnKind`, `legacyCycle` -> `syncOnly`
  2 positions  a turn position (`afterPass`, `sequence`, `passOrdinal`, ...) moved
  3 recordPayload  the record header's format change of #700 K1a (plan 2026-11-22-keeper-on-turncore
               §3.11): `metadata.version` 3.6 -> 3.7, and `metadata.payloadEncoding` appearing as
               `json` or `messagepack`. Only the record header's own fields, at their exact paths. The
               harness renders a 3.7 payload as its tree (rule `recordPayloadAsTree`), so a payload
               that changed is a leaf under a payload and stays `other`
  other        anything else: needs its own explanation, or it is a bug

Files only at one side are listed as added or removed. Exits 1 when an `other` change exists.
"""
import json
import subprocess
import sys
from pathlib import Path

GOLDEN = "Tests/SwiftStateTreeNIOTests/Differential/Golden"
POSITION_KEYS = {"afterPass", "sequence", "passOrdinal", "turnIndex", "tickId", "streamIndex"}
RECORD_HEADER = "result.record.decoded.metadata"
PAYLOAD_ENCODINGS = {"json", "messagepack"}


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
    if path == f"{RECORD_HEADER}.version" and old == "3.6" and new == "3.7":
        return "3 recordPayload"
    if path == f"{RECORD_HEADER}.payloadEncoding" and old is None and new in PAYLOAD_ENCODINGS:
        return "3 recordPayload"
    key = path.rsplit(".", 1)[-1]
    if key == "turnKind" and old == "legacyCycle" and new == "syncOnly":
        return "1 turnKind"
    if key in POSITION_KEYS:
        return "2 positions"
    return "other"


def compare(old, new, out=print):
    """Compares two {file name: golden text} maps, printing through `out`; returns the exit code."""
    counts = {}
    others = []
    for name in sorted(set(old) | set(new)):
        if name not in new:
            out(f"removed  {name}")
            continue
        if name not in old:
            out(f"added    {name}")
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
        out(f"changed  {name}: {summary}")
    out("totals: " + (", ".join(f"{cause} x{n}" for cause, n in sorted(counts.items())) or "no changes"))
    for line in others:
        out(f"OTHER    {line}")
    return 1 if others else 0


def golden(version, payload_encoding=None, tag="a", event_metadata=None, turn_kind="syncOnly", sequence=0):
    """A fixture golden: one frame with one action, in the shape the harness writes."""
    metadata = {"landID": "fixture", "version": version}
    if payload_encoding is not None:
        metadata["payloadEncoding"] = payload_encoding
    frame = {
        "actions": [{"sequence": sequence, "payload": {"tag": tag}}],
        "lifecycleEvents": [{"kind": "join", "metadata": event_metadata or {}}],
        "syncOutputs": [{"turnKind": turn_kind}],
    }
    doc = {
        "cell": "fixture",
        "recordedWith": {"commit": "x", "toolchain": "y"},
        "result": {"record": {"bytes": "AA==", "complete": True, "decoded": {"metadata": metadata, "frames": [frame]}}},
        "scenario": "fixture",
    }
    return json.dumps(doc)


def self_test():
    """Each case: old and new fixture goldens, the lines expected in the output, and the exit code."""
    cases = [
        ("K1a's header change only", golden("3.6"), golden("3.7", "messagepack"),
         ["changed  f.json: 3 recordPayload x2", "totals: 3 recordPayload x2"], 0),
        ("the JSON encoding too", golden("3.6"), golden("3.7", "json"),
         ["changed  f.json: 3 recordPayload x2"], 0),
        ("a payload value that changed stays other", golden("3.6"), golden("3.7", "json", tag="b"),
         ["changed  f.json: 3 recordPayload x2, other x1",
          "OTHER    f.json: result.record.decoded.frames[0].actions[0].payload.tag"], 1),
        ("another version step is other", golden("3.6"), golden("3.8", "json"),
         ["OTHER    f.json: result.record.decoded.metadata.version"], 1),
        ("an unknown encoding is other", golden("3.6"), golden("3.7", "xml"),
         ["OTHER    f.json: result.record.decoded.metadata.payloadEncoding"], 1),
        ("a version elsewhere is other", golden("3.6", event_metadata={"version": "3.6"}),
         golden("3.6", event_metadata={"version": "3.7"}),
         ["OTHER    f.json: result.record.decoded.frames[0].lifecycleEvents[0].metadata.version"], 1),
        ("an encoding field elsewhere is other", golden("3.6"),
         golden("3.6", event_metadata={"payloadEncoding": "json"}),
         ["OTHER    f.json: result.record.decoded.frames[0].lifecycleEvents[0].metadata.payloadEncoding"], 1),
        ("the earlier classes still apply", golden("3.6", turn_kind="legacyCycle", sequence=1),
         golden("3.6", sequence=2), ["changed  f.json: 1 turnKind x1, 2 positions x1"], 0),
        ("no change", golden("3.6"), golden("3.6"), ["totals: no changes"], 0),
    ]
    failed = 0
    for title, old, new, wants, code in cases:
        lines = []
        got = compare({"f.json": old}, {"f.json": new}, out=lines.append)
        missing = [w for w in wants if not any(line.startswith(w) for line in lines)]
        if got != code or missing:
            failed += 1
            print(f"self-test: {title}: exit {got} (want {code}); missing {missing} in:")
            for line in lines:
                print(f"  {line}")
    if failed:
        return 1
    print(f"classify-golden-changes: self-test passed ({len(cases)} cases)")
    return 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    old = files_at(sys.argv[1])
    new = files_at(sys.argv[2] if len(sys.argv) == 3 else None)
    return compare(old, new)


if __name__ == "__main__":
    sys.exit(main())
