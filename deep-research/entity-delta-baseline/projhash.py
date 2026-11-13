#!/usr/bin/env python3
"""Hashes of every player's projection after every sync of a `--capture-views` directory, so
captures of the same cell from different variants can be compared after the captures are
deleted (stdlib only).

  projhash.py <capture-dir> <out.json>

The output maps each run's cell suffix (`r<rooms>-p<players>-m<cap>[-active]-serial`, the run
label without its format and strategy) to `{"room-<i>.ndjson": [sha256 per sync, ...]}`. A sync's
hash covers every player's projection, keys sorted.
"""
import hashlib, json, pathlib, re, sys


def main(capture, out):
    result = {}
    for run in sorted(p for p in pathlib.Path(capture).iterdir() if p.is_dir()):
        match = re.search(r"-(r\d+-p\d+-m\d+(?:-active)?-serial)$", run.name)
        if not match:
            sys.exit(f"{run}: unexpected run name")
        rooms = {}
        for room in sorted(run.glob("room-*.ndjson")):
            lines = room.read_text(encoding="utf-8").splitlines()[1:]
            rooms[room.name] = [hashlib.sha256(json.dumps(json.loads(l)["projections"], sort_keys=True).encode()).hexdigest()
                                for l in lines if l]
        result[match.group(1)] = rooms
    if not result:
        sys.exit(f"{capture}: no runs")
    pathlib.Path(out).write_text(json.dumps(result, indent=1, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main(*sys.argv[1:])
