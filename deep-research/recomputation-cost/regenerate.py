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
    # The overhead breakdown drops one thing each.
    assert [sorted(t) for t in without_state_hash(record)["tickFrames"]][1] == ["actions", "clientEvents", "lifecycleEvents", "tickId"]
    assert [t["tickId"] for t in without_empty_ticks(record)["tickFrames"]] == [0]
    # Stream files: length-prefixed frames.
    assert read_frames(struct.pack(">I", 2) + b"ab" + struct.pack(">I", 1) + b"c") == [b"ab", b"c"]
    # The decoder reads back every vector, and a 3.0 record rebuilds its JSON view.
    for value, hex_bytes in SELF_TEST_VECTORS:
        decoded, end = unpack(bytes.fromhex(hex_bytes))
        assert end == len(hex_bytes) // 2 and decoded == value, f"unpack({hex_bytes}) = {decoded!r}"
    log = SSTR_MAGIC + bytes([3, 0])
    for rec in [
        {"kind": "header", "format": "x", "metadata": {"rngSeed": 1}},
        {"kind": "turn", "tickId": 1, "actions": [{"a": 1}], "sequenceBeforeInputs": 4},
        {"kind": "turn", "tickId": 0, "lifecycleEvents": [{"kind": "join"}], "stateHash": "h0"},
        {"kind": "turn", "tickId": 1, "syncMarkers": [{"streamIndex": 0}], "stateHash": "h1"},
        {"kind": "footer", "complete": True},
    ]:
        body = msgpack(rec)
        log += struct.pack(">I", len(body)) + body
    empty = {f: [] for f in FRAME_LIST_FIELDS}
    assert read_record_log(log) == {"recordMetadata": {"rngSeed": 1}, "tickFrames": [
        {"tickId": 0, **empty, "lifecycleEvents": [{"kind": "join"}], "stateHash": "h0"},
        {"tickId": 1, **empty, "actions": [{"a": 1}], "sequenceBeforeInputs": 4, "syncMarkers": [{"streamIndex": 0}],
         "stateHash": "h1"},
    ]}
    try:
        read_record_log(log[:-3])
        raise AssertionError("a cut record must be rejected")
    except (ValueError, struct.error, IndexError):
        pass
    print(f"self-test passed ({len(SELF_TEST_VECTORS)} msgpack vectors)")


# --- 3.0 records (SSTR) ------------------------------------------------------------------
#
# A 3.0 record is `SSTR`, a major and a minor version byte, then length-prefixed records (4-byte
# big-endian length, one canonical MessagePack map): one header (`metadata`), `turn`s (what one
# keeper turn recorded for one tick; a tick can have several, a late one included) and a footer
# (`complete`). `read_record_log` rebuilds the 2.x JSON view the runtime gives the same file
# (`ReevaluationRecordFile.jsonView`): the metadata, and one frame per tick, the tick's turns
# merged in file order (lists appended, scalars replaced by a later turn's), sorted by tick.

SSTR_MAGIC = b"SSTR"
FRAME_LIST_FIELDS = ("actions", "clientEvents", "lifecycleEvents", "serverEvents")
FRAME_SYNC_FIELDS = ("syncOutputs", "syncMarkers")
FRAME_SCALAR_FIELDS = ("stateHash", "sequenceBeforeInputs", "sequenceBeforeTickHandler", "initialize")


def unpack(data: bytes, i: int = 0):
    """One MessagePack value at `i` (the JSON subset the encoder above writes): (value, end)."""
    b = data[i]
    i += 1
    if b <= 0x7F:
        return b, i
    if b >= 0xE0:
        return b - 0x100, i
    if 0xA0 <= b <= 0xBF:
        n = b & 0x1F
        return data[i:i + n].decode("utf-8"), i + n
    if 0x90 <= b <= 0x9F:
        return _unpack_array(data, i, b & 0x0F)
    if 0x80 <= b <= 0x8F:
        return _unpack_map(data, i, b & 0x0F)
    if b == 0xC0:
        return None, i
    if b in (0xC2, 0xC3):
        return b == 0xC3, i
    if b == 0xCB:
        return struct.unpack_from(">d", data, i)[0], i + 8
    sized = {0xCC: ">B", 0xCD: ">H", 0xCE: ">I", 0xCF: ">Q", 0xD0: ">b", 0xD1: ">h", 0xD2: ">i", 0xD3: ">q"}
    if b in sized:
        fmt = sized[b]
        return struct.unpack_from(fmt, data, i)[0], i + struct.calcsize(fmt)
    lengths = {0xD9: ">B", 0xDA: ">H", 0xDB: ">I", 0xDC: ">H", 0xDD: ">I", 0xDE: ">H", 0xDF: ">I"}
    if b in lengths:
        fmt = lengths[b]
        (n,) = struct.unpack_from(fmt, data, i)
        i += struct.calcsize(fmt)
        if b <= 0xDB:
            return data[i:i + n].decode("utf-8"), i + n
        return (_unpack_array if b <= 0xDD else _unpack_map)(data, i, n)
    raise ValueError(f"unsupported MessagePack type 0x{b:02x}")


def _unpack_array(data: bytes, i: int, n: int):
    items = []
    for _ in range(n):
        item, i = unpack(data, i)
        items.append(item)
    return items, i


def _unpack_map(data: bytes, i: int, n: int):
    entries = {}
    for _ in range(n):
        key, i = unpack(data, i)
        entries[key], i = unpack(data, i)
    return entries, i


def read_record_log(data: bytes) -> dict:
    """The 2.x JSON view of a 3.0 record: {recordMetadata, tickFrames}. A record without a complete
    footer is rejected: the runs measured here are saved when their room closes."""
    if data[:4] != SSTR_MAGIC:
        raise ValueError("not a 3.0 record (no SSTR magic)")
    i, metadata, footer, frames = 6, None, None, {}
    while i < len(data):
        (n,) = struct.unpack_from(">I", data, i)
        record, end = unpack(data, i + 4)
        if end != i + 4 + n:
            raise ValueError("record length does not match its contents")
        i = end
        kind = record.get("kind")
        if kind == "header":
            metadata = record["metadata"]
        elif kind == "turn":
            frame = frames.setdefault(record["tickId"], {
                "tickId": record["tickId"], **{f: [] for f in FRAME_LIST_FIELDS + FRAME_SYNC_FIELDS},
            })
            for field in FRAME_LIST_FIELDS + FRAME_SYNC_FIELDS:
                frame[field] += record.get(field) or []
            for field in FRAME_SCALAR_FIELDS:
                if record.get(field) is not None:
                    frame[field] = record[field]
        elif kind == "footer":
            footer = record
    if metadata is None:
        raise ValueError("record has no header")
    if not (footer and footer.get("complete")):
        raise ValueError("record is incomplete (no complete footer)")
    view = []
    for tick in sorted(frames):
        frame = frames[tick]
        for field in FRAME_SYNC_FIELDS:
            if not frame[field]:
                del frame[field]  # the JSON view omits an empty sync list
        view.append(frame)
    return {"recordMetadata": metadata, "tickFrames": view}


def load_record(path: pathlib.Path) -> dict:
    data = path.read_bytes()
    return read_record_log(data) if data[:4] == SSTR_MAGIC else json.loads(data)


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


def without_state_hash(record: dict) -> dict:
    """B_asStored with only stateHash dropped: what the per-tick hash weighs."""
    ticks = [{k: v for k, v in frame.items() if k != "stateHash"} for frame in record["tickFrames"]]
    return {**record, "tickFrames": ticks}


def without_empty_ticks(record: dict) -> dict:
    """B_asStored with only the ticks that have no input dropped: what empty ticks weigh."""
    ticks = [frame for frame in record["tickFrames"] if any(frame.get(field) for field in INPUT_FIELDS)]
    return {**record, "tickFrames": ticks}


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
    meta = loadtest["metadata"]["loadTestConfig"]
    records = sorted(p for p in (run_dir / "records").glob("*") if p.suffix in (".json", ".sstr"))
    loaded = [load_record(p) for p in records]
    b_stored = [sizes(r) for r in loaded]
    native = [{"bytes": p.stat().st_size, "gz": gz(p.read_bytes())} for p in records]
    b_minimal = [sizes(minimal_record(r)) for r in loaded]
    b_no_hash = [sizes(without_state_hash(r)) for r in loaded]
    b_no_empty = [sizes(without_empty_ticks(r)) for r in loaded]
    ticks = sum(len(r["tickFrames"]) for r in loaded)
    input_ticks = sum(len(without_empty_ticks(r)["tickFrames"]) for r in loaded)
    sessions = []
    for p in sorted((run_dir / "streams").glob("*.bin")):
        frames = read_frames(p.read_bytes())
        blob = b"".join(frames)
        sessions.append({"frames": len(frames), "raw": len(blob), "gz": gz(blob)})
    rooms = max(1, len(records))
    minutes = loadtest["results"]["summary"]["totalSeconds"] / 60
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
        "B_native": {k: sum(s[k] for s in native) / rooms for k in native[0]} if native else None,
        "nativeFormat": "3.0" if records and all(p.suffix == ".sstr" for p in records) else "2.x",
        "B_minimal": {k: sum(s[k] for s in b_minimal) / rooms for k in b_minimal[0]} if b_minimal else None,
        "B_noStateHash": {k: sum(s[k] for s in b_no_hash) / rooms for k in b_no_hash[0]} if b_no_hash else None,
        "B_noEmptyTicks": {k: sum(s[k] for s in b_no_empty) / rooms for k in b_no_empty[0]} if b_no_empty else None,
        "ticksPerRoom": ticks / rooms,
        "inputTicksPerRoom": input_ticks / rooms,
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
        "B_native / gz | B_asStored msgpack / gz | B_asStored json / gz | B_minimal msgpack / gz | "
        "B_minimal json / gz | B_asStored msgpack gz ÷ A gz |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in runs:
        a, s, bs, bm = r["A_total_per_room"], r["A_session"], r["B_asStored"], r["B_minimal"]
        per_min = 1 / r["minutes"] if r["minutes"] else 0
        ratio = (bs["msgpack_gz"] / a["gz"]) if bs and a["gz"] else float("nan")
        bn = r.get("B_native")
        # A 2.x JSON record has no native MessagePack size.
        native = f"{kib(bn['bytes'])} / {kib(bn['gz'])}" if bn and r.get("nativeFormat") == "3.0" else "n/a"
        lines.append(
            f"| {r['run']} | {r['encoding']} | {r['players']} | {r['inputCadenceTicks']} | "
            f"{kib(a['raw'] * per_min)} | {kib(a['gz'] * per_min)} | "
            f"{kib(s['min'])}/{kib(s['median'])}/{kib(s['max'])} | {native} | "
            f"{kib(bs['msgpack'])} / {kib(bs['msgpack_gz'])} | {kib(bs['json'])} / {kib(bs['json_gz'])} | "
            f"{kib(bm['msgpack'])} / {kib(bm['msgpack_gz'])} | {kib(bm['json'])} / {kib(bm['json_gz'])} | "
            f"{ratio:.3f} |"
        )
    lines += ["", "The A gzip column compresses each session's whole stream as one blob; a live "
              "stream is sent frame by frame and can't be compressed that way.", ""]
    lines += [
        "Where B's overhead lands (MessagePack plus gzip, KiB per room, each over A gz). Each middle "
        "column drops one thing from B_asStored; B_minimal drops both, plus serverEvents, "
        "syncOutputs and syncMarkers.",
        "",
        "| run | players | cadence | ticks / with input | B_asStored | no stateHash | no input-free ticks | B_minimal |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in runs:
        a = r["A_total_per_room"]["gz"]
        cell = lambda b: f"{kib(b['msgpack_gz'])} ({b['msgpack_gz'] / a:.3f})" if a else kib(b["msgpack_gz"])
        lines.append(
            f"| {r['run']} | {r['players']} | {r['inputCadenceTicks']} | "
            f"{r['ticksPerRoom']:.0f} / {r['inputTicksPerRoom']:.0f} | {cell(r['B_asStored'])} | "
            f"{cell(r['B_noStateHash'])} | {cell(r['B_noEmptyTicks'])} | {cell(r['B_minimal'])} |"
        )
    lines += ["", RESULTS_END]
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
