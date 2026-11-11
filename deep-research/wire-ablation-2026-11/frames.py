#!/usr/bin/env python3
"""The sha256 of every frame each captured run sent, for the wire ablation's byte-identity gate
(stdlib only).

  python3 frames.py <capture dir>     prints {run label: {sha256, frames, syncs}} as JSON

EncodingBenchmark's `--capture-views <dir>` writes <dir>/<run label>/room-<i>.ndjson: a header line,
then one line per sync with the frames the room's transport sent since the last one
(`frames`: [{"to": <target>, "data": <base64>}], in send order) and the players' projections. The
hash covers every room's frames in room, sync and send order: before each sync's frames, the sync's
index and its frame count; then each frame as its target and its bytes, both length-prefixed. So
two runs hash alike only if they sent the same bytes to the same targets in the same order and in
the same syncs: a frame sent one sync later changes the hash. The projections and the header
aren't hashed: they aren't what was sent.
"""
import base64, hashlib, json, pathlib, re, struct, sys


def room_index(path):
    m = re.fullmatch(r"room-(\d+)\.ndjson", path.name)
    if not m:
        raise SystemExit(f"{path}: not room-<i>.ndjson")
    return int(m.group(1))


def run_hash(run_dir):
    h, frames, syncs = hashlib.sha256(), 0, 0
    for room in sorted(run_dir.glob("room-*.ndjson"), key=room_index):
        h.update(struct.pack(">I", room_index(room)))
        for line in room.read_text().splitlines():
            if not line.strip():
                continue
            entry = json.loads(line)
            if "frames" not in entry:
                continue  # the header
            # The sync boundary: its index (in send order) and how many frames it carried.
            h.update(struct.pack(">II", syncs, len(entry["frames"])))
            syncs += 1
            for frame in entry["frames"]:
                to, data = frame["to"].encode(), base64.b64decode(frame["data"])
                h.update(struct.pack(">I", len(to)) + to + struct.pack(">I", len(data)) + data)
                frames += 1
    return {"sha256": h.hexdigest(), "frames": frames, "syncs": syncs}


def hashes(capture_dir):
    runs = sorted(p for p in capture_dir.iterdir() if p.is_dir())
    if not runs:
        raise SystemExit(f"{capture_dir}: no captured runs")
    return {run.name: run_hash(run) for run in runs}


def main(argv):
    if len(argv) != 1:
        raise SystemExit(__doc__)
    print(json.dumps(hashes(pathlib.Path(argv[0])), indent=2, sort_keys=True))


if __name__ == "__main__":
    main(sys.argv[1:])
