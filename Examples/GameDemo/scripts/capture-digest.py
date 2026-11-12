#!/usr/bin/env python3
"""Digest of an EncodingBenchmark capture (`--capture-views <dir>`: `<dir>/<run>/room-<i>.ndjson`).

Usage: capture-digest.py <room-<i>.ndjson>...
Prints, per file, "<digest> <syncs> syncs <sessions> sessions <path>".

Two runs whose every session receives the same frames, in the same order, after every sync,
and whose projections are the same, have the same digest. That holds whatever the commit,
because the header line, which records the commit, is left out.

A capture lists one sync's frames in the order the transport was handed them. Frames to
different sessions interleave in an order that varies from run to run, so a hash of the whole
file isn't deterministic. The digest is taken over what each session receives instead:
- per session (sorted), per sync, the frames that reach it, in capture order;
- a frame reaches a session when its target is that session (`s:<session>`), that session's
  player (`p:<player>`, from the header's `sessions`), everyone (`*`), or everyone except
  another session (`!<other>`);
- each sync's projections.
A broadcast is expanded to every session it reaches, so a change in the order one session sees
a broadcast and its own frames changes the digest.
"""
import hashlib
import json
import sys


def digest(path):
    with open(path) as handle:
        lines = [line for line in handle.read().split("\n") if line.strip()]
    header = json.loads(lines[0])
    players = header["sessions"]  # session ID -> player ID
    sessions = sorted(players)
    h = hashlib.sha256()
    syncs = 0
    for line in lines[1:]:
        entry = json.loads(line)
        syncs += 1
        received = {session: [] for session in sessions}
        for frame in entry["frames"]:
            target = frame["to"]
            for session in sessions:
                if (
                    target == "*"
                    or target == "s:" + session
                    or target == "p:" + players[session]
                    or (target.startswith("!") and target[1:] != session)
                ):
                    received[session].append(frame["data"])
        h.update(json.dumps(
            {"sync": entry["sync"], "received": received, "projections": entry["projections"]},
            sort_keys=True,
        ).encode())
    return h.hexdigest(), syncs, len(sessions)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for path in sys.argv[1:]:
        value, syncs, sessions = digest(path)
        print(f"{value} {syncs} syncs {sessions} sessions {path}")
