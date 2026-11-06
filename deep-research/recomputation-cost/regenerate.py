#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from the runs under results/.

Compares the sync stream a server sends (A) with the re-evaluation record that reproduces it (B).
Every size is computed here, offline, with one compressor for both sides (gzip level
GZIP_LEVEL, mtime 0), so A and B are aligned before they are compared. The record format and
the runtime are not changed.

Run layout (one directory per run, written by ServerLoadTest with `--record on`,
`--record-dir` and `--stream-dir`):

    results/<run>/loadtest.json        ServerLoadTest's result file (config + summary)
    results/<run>/records/*.json       one re-evaluation record per room, as stored
    results/<run>/streams/*.bin        one file per session: every frame the session received,
                                       each as a 4-byte big-endian length, then the frame

B is measured in two scopes, each as compact JSON (sorted keys) and as MessagePack (this
file's encoder, sorted keys), raw and gzipped:
- B_asStored: the whole record;
- B_minimal: inputs only. The record metadata (seed included) and, per tick with any input,
  its tickId, its sequence fields, actions, clientEvents and lifecycleEvents (resolver outputs
  are inside those). stateHash, serverEvents, syncOutputs and syncMarkers are dropped, and so
  are ticks without inputs. A size bound, not a replayable format.

A, per room: the frames' bytes summed over the room's sessions (A_total), and per session
(min/median/max), raw; gzipped as one blob per session (all its frames concatenated), which is
fair against a whole-file gzip of B but is not how a live stream can be compressed: a live
stream is sent frame by frame.

Usage: regenerate.py [--check] [--self-test]
"""
import argparse
import gzip
import json
import math
import pathlib
import statistics
import struct
import sys

HERE = pathlib.Path(__file__).parent
GZIP_LEVEL = 9
RESULTS_HEADING = "## Results"
RESULTS_END = "<!-- results end -->"

# --- MessagePack (JSON subset), sorted map keys -------------------------------------------


def msgpack(value) -> bytes:
    """MessagePack for the JSON subset: nil, bool, int, float (always float64), str, list, dict.

    Map keys are sorted, and every value takes its smallest format, so the size is a function
    of the JSON value alone.
    """
    out = bytearray()
    _pack(value, out)
    return bytes(out)


def _pack(v, out: bytearray) -> None:
    if v is None:
        out.append(0xC0)
    elif v is True:
        out.append(0xC3)
    elif v is False:
        out.append(0xC2)
    elif isinstance(v, int):
        _pack_int(v, out)
    elif isinstance(v, float):
        if not math.isfinite(v):
            raise ValueError("JSON has no NaN or infinity")
        out.append(0xCB)
        out += struct.pack(">d", v)
    elif isinstance(v, str):
        data = v.encode("utf-8")
        n = len(data)
        if n < 32:
            out.append(0xA0 | n)
        elif n < 1 << 8:
            out += bytes([0xD9, n])
        elif n < 1 << 16:
            out.append(0xDA)
            out += struct.pack(">H", n)
        else:
            out.append(0xDB)
            out += struct.pack(">I", n)
        out += data
    elif isinstance(v, list):
        _pack_len(len(v), 0x90, 0xDC, 0xDD, out)
        for item in v:
            _pack(item, out)
    elif isinstance(v, dict):
        _pack_len(len(v), 0x80, 0xDE, 0xDF, out)
        for key in sorted(v):
            if not isinstance(key, str):
                raise TypeError("JSON map keys are strings")
            _pack(key, out)
            _pack(v[key], out)
    else:
        raise TypeError(f"not a JSON value: {type(v).__name__}")


def _pack_len(n: int, fix: int, op16: int, op32: int, out: bytearray) -> None:
    if n < 16:
        out.append(fix | n)
    elif n < 1 << 16:
        out.append(op16)
        out += struct.pack(">H", n)
    else:
        out.append(op32)
        out += struct.pack(">I", n)


def _pack_int(n: int, out: bytearray) -> None:
    if 0 <= n < 128:
        out.append(n)
    elif -32 <= n < 0:
        out += struct.pack(">b", n)
    elif n >= 0:
        for op, fmt, limit in ((0xCC, ">B", 1 << 8), (0xCD, ">H", 1 << 16), (0xCE, ">I", 1 << 32), (0xCF, ">Q", 1 << 64)):
            if n < limit:
                out.append(op)
                out += struct.pack(fmt, n)
                return
        raise OverflowError(n)
    else:
        for op, fmt, limit in ((0xD0, ">b", 1 << 7), (0xD1, ">h", 1 << 15), (0xD2, ">i", 1 << 31), (0xD3, ">q", 1 << 63)):
            if n >= -limit:
                out.append(op)
                out += struct.pack(fmt, n)
                return
        raise OverflowError(n)


# Known vectors: the MessagePack spec's formats, one per boundary, and one nested map checked
# by hand: {"b": [1, -1], "a": {"x": null}} → keys sorted: a, then b.
SELF_TEST_VECTORS = [
    (None, "c0"), (False, "c2"), (True, "c3"),
    (0, "00"), (127, "7f"), (128, "cc80"), (255, "ccff"), (256, "cd0100"), (65536, "ce00010000"),
    (1 << 32, "cf0000000100000000"),
    (-1, "ff"), (-32, "e0"), (-33, "d0df"), (-128, "d080"), (-129, "d1ff7f"), (-(1 << 15) - 1, "d2ffff7fff"),
    (-(1 << 31) - 1, "d3ffffffff7fffffff"),
    (1.5, "cb3ff8000000000000"),
    ("", "a0"), ("a", "a161"), ("x" * 32, "d920" + "78" * 32), ("é", "a2c3a9"),
    ([], "90"), ([1, 2], "920102"), (list(range(16)), "dc0010" + "".join(f"{i:02x}" for i in range(16))),
    ({}, "80"),
    ({"b": [1, -1], "a": {"x": None}}, "82" "a161" "81" "a178" "c0" "a162" "92" "01" "ff"),
]


def self_test() -> None:
    for value, hex_bytes in SELF_TEST_VECTORS:
        got = msgpack(value).hex()
        assert got == hex_bytes, f"msgpack({value!r}) = {got}, want {hex_bytes}"
    # gzip is deterministic for equal input (mtime 0).
    assert gz(b"abc" * 100) == gz(b"abc" * 100)
    # B_minimal drops the derived fields and empty ticks.
    record = {
        "recordMetadata": {"rngSeed": 1},
        "tickFrames": [
            {"tickId": 0, "actions": [], "clientEvents": [], "lifecycleEvents": [{"kind": "join"}],
             "stateHash": "h0", "serverEvents": [], "syncOutputs": [1], "sequenceBeforeInputs": 0},
            {"tickId": 1, "actions": [], "clientEvents": [], "lifecycleEvents": [], "stateHash": "h1"},
        ],
    }
    assert minimal_record(record) == {
        "recordMetadata": {"rngSeed": 1},
        "tickFrames": [{"tickId": 0, "actions": [], "clientEvents": [], "lifecycleEvents": [{"kind": "join"}],
                        "sequenceBeforeInputs": 0}],
    }
    # Stream files: length-prefixed frames.
    assert read_frames(struct.pack(">I", 2) + b"ab" + struct.pack(">I", 1) + b"c") == [b"ab", b"c"]
    print(f"self-test passed ({len(SELF_TEST_VECTORS)} msgpack vectors)")


# --- Measurement --------------------------------------------------------------------------

INPUT_FIELDS = ("actions", "clientEvents", "lifecycleEvents")
KEPT_TICK_FIELDS = ("tickId", "sequenceBeforeInputs", "sequenceBeforeTickHandler") + INPUT_FIELDS


def gz(data: bytes) -> int:
    return len(gzip.compress(data, compresslevel=GZIP_LEVEL, mtime=0))


def compact_json(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def minimal_record(record: dict) -> dict:
    ticks = []
    for frame in record["tickFrames"]:
        if not any(frame.get(field) for field in INPUT_FIELDS):
            continue
        ticks.append({k: frame[k] for k in KEPT_TICK_FIELDS if k in frame})
    return {"recordMetadata": record["recordMetadata"], "tickFrames": ticks}


def sizes(value) -> dict:
    j = compact_json(value)
    m = msgpack(value)
    return {"json": len(j), "json_gz": gz(j), "msgpack": len(m), "msgpack_gz": gz(m)}


def read_frames(data: bytes) -> list:
    frames, i = [], 0
    while i < len(data):
        (n,) = struct.unpack_from(">I", data, i)
        frames.append(data[i + 4:i + 4 + n])
        i += 4 + n
    if i != len(data):
        raise ValueError("truncated stream file")
    return frames


def measure_run(run_dir: pathlib.Path) -> dict:
    loadtest = json.loads((run_dir / "loadtest.json").read_text())
    meta = loadtest.get("metadata", {}).get("loadTestConfig", loadtest.get("loadTestConfig", {}))
    records = sorted((run_dir / "records").glob("*.json"))
    b_stored = [sizes(json.loads(p.read_text())) for p in records]
    b_minimal = [sizes(minimal_record(json.loads(p.read_text()))) for p in records]
    sessions = []
    for p in sorted((run_dir / "streams").glob("*.bin")):
        frames = read_frames(p.read_bytes())
        blob = b"".join(frames)
        sessions.append({"frames": len(frames), "raw": len(blob), "gz": gz(blob)})
    rooms = max(1, len(records))
    minutes = loadtest["summary"]["totalSeconds"] / 60
    raw = [s["raw"] for s in sessions]
    return {
        "run": run_dir.name,
        "encoding": meta.get("transportEncoding", {}).get("message", "?"),
        "record": meta.get("record", "?"),
        "players": meta.get("playersPerRoom"),
        "inputCadenceTicks": meta.get("inputCadenceTicks"),
        "rooms": len(records),
        "minutes": minutes,
        "B_asStored": {k: sum(s[k] for s in b_stored) / rooms for k in b_stored[0]} if b_stored else None,
        "B_minimal": {k: sum(s[k] for s in b_minimal) / rooms for k in b_minimal[0]} if b_minimal else None,
        "A_total_per_room": {"raw": sum(raw) / rooms, "gz": sum(s["gz"] for s in sessions) / rooms},
        "A_session": {"min": min(raw), "median": statistics.median(raw), "max": max(raw)} if raw else None,
    }


def kib(n) -> str:
    return f"{n / 1024:.1f}"


def results_markdown(runs: list) -> str:
    lines = [RESULTS_HEADING, ""]
    if not runs:
        lines += ["No runs yet.", "", RESULTS_END]
        return "\n".join(lines)
    lines += [
        "Per room, KiB; A is per room-minute of stream; B covers the same run length. gzip level "
        f"{GZIP_LEVEL} on both sides.",
        "",
        "| run | enc | players | cadence | A raw/min | A gz/min | A session min/med/max | "
        "B_asStored msgpack / gz | B_asStored json / gz | B_minimal msgpack / gz | B_minimal json / gz | "
        "B_asStored msgpack gz ÷ A gz |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in runs:
        a, s, bs, bm = r["A_total_per_room"], r["A_session"], r["B_asStored"], r["B_minimal"]
        per_min = 1 / r["minutes"] if r["minutes"] else 0
        ratio = (bs["msgpack_gz"] / a["gz"]) if bs and a["gz"] else float("nan")
        lines.append(
            f"| {r['run']} | {r['encoding']} | {r['players']} | {r['inputCadenceTicks']} | "
            f"{kib(a['raw'] * per_min)} | {kib(a['gz'] * per_min)} | "
            f"{kib(s['min'])}/{kib(s['median'])}/{kib(s['max'])} | "
            f"{kib(bs['msgpack'])} / {kib(bs['msgpack_gz'])} | {kib(bs['json'])} / {kib(bs['json_gz'])} | "
            f"{kib(bm['msgpack'])} / {kib(bm['msgpack_gz'])} | {kib(bm['json'])} / {kib(bm['json_gz'])} | "
            f"{ratio:.3f} |"
        )
    lines += ["", "The A gzip column compresses each session's whole stream as one blob; a live "
              "stream is sent frame by frame and can't be compressed that way.", "", RESULTS_END]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="Fail if README.md's Results differ.")
    ap.add_argument("--self-test", action="store_true", help="Run the encoder and helper tests only.")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return
    runs = [measure_run(d) for d in sorted((HERE / "results").glob("*/")) if (d / "loadtest.json").exists()]
    generated = results_markdown(runs)
    readme = (HERE / "README.md").read_text()
    start, end = readme.index(RESULTS_HEADING), readme.index(RESULTS_END) + len(RESULTS_END)
    current = readme[start:end]
    if args.check:
        if current != generated:
            sys.exit("README.md Results are stale; run regenerate.py")
        print("README.md Results match")
        return
    (HERE / "README.md").write_text(readme[:start] + generated + readme[end:])
    print(f"wrote Results ({len(runs)} runs)")


if __name__ == "__main__":
    main()
