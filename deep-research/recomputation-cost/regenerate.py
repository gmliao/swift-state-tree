#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from the runs under results/.

Compares the sync stream a server sends (A) with the re-evaluation record that reproduces it (B).
Every size is computed here, offline, with one compressor for both sides (gzip level
GZIP_LEVEL, mtime 0), so A and B are aligned before they are compared. The record format and
the runtime are not changed.

Raw run layout (one directory per run, written by ServerLoadTest with `--record on`,
`--record-dir` and `--stream-dir`, plus the replay outputs; archived outside this repository):

    <run>/loadtest.json        ServerLoadTest's result file (config + summary)
    <run>/records/*.sstr       one 3.0 re-evaluation record per room (2.x *.json still read)
    <run>/streams/*.bin        one file per session: every frame the session received,
                               each as a 4-byte big-endian length, then the frame
    <run>/profile.jsonl        TRANSPORT_PROFILE_JSONL_PATH lines (recording cost)
    <run>/replay-<name>.txt, verify-<name>.txt, open1-<name>.txt, open-<name>.json

`--summarize <run>` writes results/<run>/summary.json from it; the README tables are rendered
from those summaries alone, so `--check` needs no raw files.

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

Usage: regenerate.py [--check] [--self-test] [--summarize <raw run dir>]
"""
import argparse
import gzip
import json
import math
import pathlib
import re
import shutil
import statistics
import struct
import sys
import tempfile

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


# --- Per-run summaries -----------------------------------------------------------------
#
# `--summarize <raw run dir>` reads a run's raw files (records, streams) and its public text
# outputs, and writes results/<run>/summary.json. The README tables are rendered from those
# summaries alone, so `--check` runs without the raw files (they are archived elsewhere, listed
# in MANIFEST by sha256).

FLAT_RSS_WINDOW_SECONDS = 300
FLAT_RSS_MAX_GROWTH = 0.02  # pass: growth over the window under 2 % of its mean RSS

REPLAY_TIMING = re.compile(r"REPLAY_TIMING run=(\d+) ticks=(\d+) wallMs=([0-9.]+)")
MAX_RSS = re.compile(r"Maximum resident set size \(kbytes\): (\d+)")


def percentile(values: list, q: float):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(q * len(ordered)) - 1))]


def slope(points: list) -> float:
    """Least-squares slope of (x, y) points."""
    n = len(points)
    mx = sum(x for x, _ in points) / n
    my = sum(y for _, y in points) / n
    den = sum((x - mx) ** 2 for x, _ in points)
    return sum((x - mx) * (y - my) for x, y in points) / den if den else 0.0


def replay_figures(run_dir: pathlib.Path) -> dict:
    """Per replayed record (replay-<name>.txt, verify-<name>.txt, open1-<name>.txt, open-<name>.json)."""
    out = {}
    for replay in sorted(run_dir.glob("replay-*.txt")):
        name = replay.stem.removeprefix("replay-")
        text = replay.read_text()
        timing = {int(m[1]): (int(m[2]), float(m[3])) for m in REPLAY_TIMING.finditer(text)}
        rss = MAX_RSS.search(text)
        entry = {
            "ticks": timing[1][0] if 1 in timing else None,
            "wallMs": timing[1][1] if 1 in timing else None,
            "peakRSSKiB": int(rss[1]) if rss else None,
        }
        verify = run_dir / f"verify-{name}.txt"
        if verify.exists():
            vt = verify.read_text()
            vtiming = {int(m[1]): float(m[3]) for m in REPLAY_TIMING.finditer(vt)}
            entry["verified"] = "Verified state hashes" in vt and "mismatch" not in vt.lower() and 2 in vtiming
            entry["verifyWallMs"] = [vtiming.get(1), vtiming.get(2)]
        open1 = run_dir / f"open1-{name}.txt"
        if open1.exists():
            m = MAX_RSS.search(open1.read_text())
            entry["openPeakRSSKiB"] = int(m[1]) if m else None
        opened = run_dir / f"open-{name}.json"
        if opened.exists():
            line = [ln for ln in opened.read_text().splitlines() if ln.startswith("{")][-1]
            o = json.loads(line)
            entry["open"] = {k: o[k] for k in ("medianMs", "p10Ms", "p90Ms", "repeat", "bytes")}
        out[name] = entry
    return out


def cost_figures(run_dir: pathlib.Path, loadtest: dict) -> dict:
    summary = loadtest["results"]["summary"]
    process = summary.get("process", {})
    steady = summary.get("steadySeconds") or 0
    out = {
        "actionsPerSecond": summary["totalActionsCompleted"] / steady if steady else None,
        "recvMessagesPerSecond": summary.get("avgRecvMessagesPerSecond"),
        "recvBytesPerSecond": summary.get("avgRecvBytesPerSecond"),
        "cpuPercentMean": process.get("steadyCPUPercentMean"),
        "peakRSSBytes": process.get("peakRSSBytes"),
    }
    profile = run_dir / "profile.jsonl"
    if profile.exists():
        lines = [json.loads(ln) for ln in profile.read_text().splitlines() if ln.strip()]
        out["profileWindows"] = len(lines)
        out["lagP99Ms"] = percentile([ln["lag_ms"] for ln in lines if "lag_ms" in ln], 0.99)
        for key in ("encode_ms", "send_ms"):
            p99s = [ln[key]["p99_ms"] for ln in lines if key in ln and "p99_ms" in ln[key]]
            out[key.replace("_ms", "P99MsMedian")] = statistics.median(p99s) if p99s else None
        for key in ("sync_extract_ms", "sync_broadcast_ms", "sync_perplayer_ms"):
            total = sum(ln[key]["sum"] for ln in lines if key in ln)
            plans = sum(ln[key]["plans"] for ln in lines if key in ln)
            out[key.replace("_ms", "MeanMs")] = total / plans if plans else None
    return out


def flat_rss(loadtest: dict):
    """The steady phase's RSS trend over its last FLAT_RSS_WINDOW_SECONDS, for long runs only."""
    steady = [s for s in loadtest["results"]["seconds"] if s.get("phase") == "steady" and s.get("processRSSBytes")]
    if len(steady) < FLAT_RSS_WINDOW_SECONDS:
        return None
    window = steady[-FLAT_RSS_WINDOW_SECONDS:]
    mean = sum(s["processRSSBytes"] for s in window) / len(window)
    per_second = slope([(s["t"], s["processRSSBytes"]) for s in window])
    growth = per_second * FLAT_RSS_WINDOW_SECONDS / mean
    return {"windowSeconds": FLAT_RSS_WINDOW_SECONDS, "meanRSSBytes": mean, "slopeBytesPerSecond": per_second,
            "growth": growth, "pass": growth < FLAT_RSS_MAX_GROWTH,
            "peakRSSBytes": loadtest["results"]["summary"]["process"].get("peakRSSBytes"),
            "endRSSBytes": loadtest["results"]["summary"]["process"].get("endRSSBytes")}


def summarize_run(raw_dir: pathlib.Path) -> dict:
    loadtest = json.loads((raw_dir / "loadtest.json").read_text())
    summary = measure_run(raw_dir)
    summary["replay"] = replay_figures(raw_dir)
    summary["cost"] = cost_figures(raw_dir, loadtest)
    summary["flatRSS"] = flat_rss(loadtest)
    summary["build"] = {"commit": loadtest["metadata"].get("git", {}).get("commit"),
                        "swiftVersion": loadtest["metadata"].get("build", {}).get("swiftVersion")}
    return summary


def write_summary(raw_dir: pathlib.Path, results_dir: pathlib.Path) -> pathlib.Path:
    out = results_dir / raw_dir.name / "summary.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(summarize_run(raw_dir), indent=2, sort_keys=True) + "\n")
    return out


def load_summaries(results_dir: pathlib.Path) -> list:
    return [json.loads(p.read_text()) for p in sorted(results_dir.glob("*/summary.json"))]


# --- Tables ----------------------------------------------------------------------------


def kib(n) -> str:
    return f"{n / 1024:.1f}"


def mib(n) -> str:
    return f"{n / 1024 / 1024:.1f}" if n is not None else "n/a"


def num(x, fmt=".2f") -> str:
    return format(x, fmt) if x is not None else "n/a"


def size_tables(runs: list) -> list:
    lines = [
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
        session = f"{kib(s['min'])}/{kib(s['median'])}/{kib(s['max'])}" if s else "n/a"
        lines.append(
            f"| {r['run']} | {r['encoding']} | {r['players']} | {r['inputCadenceTicks']} | "
            f"{kib(a['raw'] * per_min)} | {kib(a['gz'] * per_min)} | {session} | {native} | "
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
    return lines + [""]


def replay_table(runs: list) -> list:
    rows = [(r, name, e) for r in runs for name, e in sorted(r.get("replay", {}).items())]
    if not rows:
        return []
    lines = [
        "Replay, per replayed record: run 1's wall time, the open (decode) median of 200 opens, and "
        "the peak RSS of the replay and of an open alone (GNU time); the last column is what replay "
        "adds on top of holding the decoded record, per recorded tick.",
        "",
        "| run | record | ticks | replay ms | µs / tick | open median ms | replay peak MiB | open peak MiB | "
        "replay − open, B / tick | verified |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r, name, e in rows:
        ticks, wall = e.get("ticks"), e.get("wallMs")
        per_tick = wall * 1000 / ticks if ticks and wall is not None else None
        rss, orss = e.get("peakRSSKiB"), e.get("openPeakRSSKiB")
        extra = (rss - orss) * 1024 / ticks if rss is not None and orss is not None and ticks else None
        opened = e.get("open", {}).get("medianMs")
        lines.append(
            f"| {r['run']} | {name} | {ticks if ticks is not None else 'n/a'} | {num(wall, '.1f')} | "
            f"{num(per_tick, '.1f')} | {num(opened, '.3f')} | {mib(rss * 1024 if rss else None)} | "
            f"{mib(orss * 1024 if orss else None)} | {num(extra, '.0f')} | "
            f"{'yes' if e.get('verified') else 'no' if 'verified' in e else 'n/a'} |"
        )
    return lines + [""]


COST_FIELDS = [
    ("actions/s", "actionsPerSecond", ".1f"), ("CPU %", "cpuPercentMean", ".1f"),
    ("peak RSS MiB", "peakRSSBytes", None), ("tick lag p99 ms", "lagP99Ms", ".2f"),
    ("encode p99 ms", "encodeP99MsMedian", ".2f"), ("send p99 ms", "sendP99MsMedian", ".2f"),
    ("extract mean ms", "sync_extractMeanMs", ".3f"), ("broadcast mean ms", "sync_broadcastMeanMs", ".3f"),
    ("per-player mean ms", "sync_perplayerMeanMs", ".3f"),
]


def cost_table(runs: list) -> list:
    groups = {}
    for r in runs:
        if r.get("flatRSS"):
            continue  # the long run is reported on its own
        key = (r["encoding"], r["players"], r["inputCadenceTicks"])
        groups.setdefault(key, {}).setdefault(r["record"], []).append(r["cost"])
    pairs = {k: v for k, v in groups.items() if "on" in v and "off" in v}
    if not pairs:
        return []

    def mean(costs, field):
        values = [c.get(field) for c in costs if c.get(field) is not None]
        return sum(values) / len(values) if values else None

    lines = [
        "Recording cost, recording on / off, mean over repeats. Tick lag is the ticker's lag (p99 over "
        "the profiling windows); encode and send are the median of the windows' p99; the sync phases "
        "are means per full sync plan. Tick and sync *duration* p99 aren't sampled; tick lag p99 is.",
        "",
        "| enc | players | cadence | repeats on/off | " + " | ".join(label for label, _, _ in COST_FIELDS) + " |",
        "|---|---|---|---|" + "---|" * len(COST_FIELDS),
    ]
    for (enc, players, cadence), v in sorted(pairs.items(), key=lambda kv: (str(kv[0][0]), kv[0][1] or 0, kv[0][2] or 0)):
        cells = []
        for _, field, fmt in COST_FIELDS:
            on, off = mean(v["on"], field), mean(v["off"], field)
            show = (lambda x: mib(x)) if fmt is None else (lambda x, f=fmt: num(x, f))
            cells.append(f"{show(on)} / {show(off)}")
        lines.append(f"| {enc} | {players} | {cadence} | {len(v['on'])}/{len(v['off'])} | " + " | ".join(cells) + " |")
    return lines + [""]


def flat_rss_table(runs: list) -> list:
    rows = [r for r in runs if r.get("flatRSS")]
    if not rows:
        return []
    lines = [
        f"Flat RSS over a long recording: the steady phase's last {FLAT_RSS_WINDOW_SECONDS} s, least-squares "
        f"slope of the per-second RSS. Pass: growth over the window under {FLAT_RSS_MAX_GROWTH:.0%} of its mean.",
        "",
        "| run | players | cadence | steady s | peak / end RSS MiB | window mean MiB | slope KiB/s | growth | pass |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        f = r["flatRSS"]
        lines.append(
            f"| {r['run']} | {r['players']} | {r['inputCadenceTicks']} | {r['minutes'] * 60:.0f} | "
            f"{mib(f['peakRSSBytes'])} / {mib(f['endRSSBytes'])} | {mib(f['meanRSSBytes'])} | "
            f"{f['slopeBytesPerSecond'] / 1024:.2f} | {f['growth']:.2%} | {'yes' if f['pass'] else 'no'} |"
        )
    return lines + [""]


def results_markdown(runs: list) -> str:
    lines = [RESULTS_HEADING, ""]
    if not runs:
        lines += ["No runs yet.", "", RESULTS_END]
        return "\n".join(lines)
    with_records = [r for r in runs if r.get("B_asStored")]
    if with_records:
        lines += size_tables(with_records)
    lines += replay_table(runs) + cost_table(runs) + flat_rss_table(runs)
    lines += [RESULTS_END]
    return "\n".join(lines)


def render(readme_path: pathlib.Path, results_dir: pathlib.Path, check: bool) -> bool:
    """Writes (or, with check, compares) the README's Results from the run summaries."""
    generated = results_markdown(load_summaries(results_dir))
    readme = readme_path.read_text()
    start, end = readme.index(RESULTS_HEADING), readme.index(RESULTS_END) + len(RESULTS_END)
    if check:
        return readme[start:end] == generated
    readme_path.write_text(readme[:start] + generated + readme[end:])
    return True


def summarize_self_test() -> None:
    """--summarize on a synthetic on/off pair, then the tables render and check from the
    summaries alone, with the raw files gone."""
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        log = SSTR_MAGIC + bytes([3, 0])
        for rec in [{"kind": "header", "metadata": {"rngSeed": 1, "landID": "hero-defense:room-0"}},
                    {"kind": "turn", "tickId": 0, "actions": [{"a": 1}], "stateHash": "h0"},
                    {"kind": "turn", "tickId": 1, "stateHash": "h1"},
                    {"kind": "footer", "complete": True}]:
            body = msgpack(rec)
            log += struct.pack(">I", len(body)) + body

        def loadtest(record: str, seconds: int) -> dict:
            per_second = [{"t": t, "phase": "steady", "processRSSBytes": 100_000_000 + t} for t in range(seconds)]
            return {"metadata": {"loadTestConfig": {"transportEncoding": {"message": "messagepack"}, "record": record,
                                                    "playersPerRoom": 2, "inputCadenceTicks": 5},
                                 "git": {"commit": "abc"}, "build": {"swiftVersion": "6.2.4"}},
                    "results": {"summary": {"totalSeconds": seconds, "steadySeconds": seconds,
                                            "totalActionsCompleted": 10 * seconds,
                                            "process": {"steadyCPUPercentMean": 50.0 if record == "on" else 40.0,
                                                        "peakRSSBytes": 2 ** 27, "endRSSBytes": 2 ** 27}},
                                "seconds": per_second}}

        raw = {}
        for name, record, seconds in [("on-1", "on", 30), ("off-1", "off", 30), ("long-1", "on", 400)]:
            d = root / "raw" / name
            d.mkdir(parents=True)
            (d / "loadtest.json").write_text(json.dumps(loadtest(record, seconds)))
            (d / "profile.jsonl").write_text("\n".join(json.dumps(
                {"lag_ms": float(i), "encode_ms": {"p99_ms": 1.0}, "send_ms": {"p99_ms": 2.0},
                 "sync_extract_ms": {"sum": 3.0, "plans": 3, "mean": 1.0}}) for i in range(100)) + "\n")
            if record == "on":
                (d / "records").mkdir()
                (d / "records" / "r.sstr").write_bytes(log)
                (d / "streams").mkdir()
                (d / "streams" / "s.bin").write_bytes(struct.pack(">I", 2) + b"ab")
                (d / "replay-room-0.txt").write_text("REPLAY_TIMING run=1 ticks=2 wallMs=4.0 x\n"
                                                    "\tMaximum resident set size (kbytes): 2048\n")
                (d / "verify-room-0.txt").write_text("Verified state hashes\nREPLAY_TIMING run=1 ticks=2 wallMs=4.0\n"
                                                    "REPLAY_TIMING run=2 ticks=2 wallMs=3.0\n")
                (d / "open1-room-0.txt").write_text("\tMaximum resident set size (kbytes): 1024\n")
                (d / "open-room-0.json").write_text(json.dumps(
                    {"medianMs": 0.5, "p10Ms": 0.4, "p90Ms": 0.6, "repeat": 200, "bytes": len(log)}) + "\n")
            raw[name] = d
        results = root / "results"
        for d in raw.values():
            write_summary(d, results)
        readme = root / "README.md"
        readme.write_text(f"# t\n\n{RESULTS_HEADING}\n\nNo runs yet.\n\n{RESULTS_END}\n")
        render(readme, results, check=False)
        shutil.rmtree(root / "raw")  # the raw files are gone; the summaries alone must do
        assert render(readme, results, check=True), "--check must pass from the summaries alone"
        text = readme.read_text()
        assert "| on-1 | messagepack | 2 | 5 |" in text, "size table row"
        assert "| on-1 | room-0 | 2 | 4.0 | 2000.0 | 0.500 | 2.0 | 1.0 | 524288 | yes |" in text, "replay row: (2048 - 1024) KiB over 2 ticks"
        assert "| messagepack | 2 | 5 | 1/1 | 10.0 / 10.0 | 50.0 / 40.0 |" in text, "cost row"
        assert "| long-1 | 2 | 5 | 400 |" in text and "| yes |" in text.split("Flat RSS")[1], "flat-RSS row"
        summary = json.loads((results / "on-1" / "summary.json").read_text())
        assert summary["cost"]["lagP99Ms"] == 98.0 and summary["cost"]["sync_extractMeanMs"] == 1.0
        # A stale table fails the check.
        readme.write_text(text.replace("50.0 / 40.0", "51.0 / 40.0"))
        assert not render(readme, results, check=True)
    print("summarize self-test passed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="Fail if README.md's Results differ from results/*/summary.json.")
    ap.add_argument("--self-test", action="store_true", help="Run the encoder, reader and summary tests only.")
    ap.add_argument("--summarize", metavar="RAW_RUN_DIR", type=pathlib.Path,
                    help="Write results/<run>/summary.json from a raw run directory (records, streams, outputs).")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        summarize_self_test()
        return
    if args.summarize:
        print(f"wrote {write_summary(args.summarize, HERE / 'results')}")
        return
    readme = HERE / "README.md"
    if args.check:
        if not render(readme, HERE / "results", check=True):
            sys.exit("README.md Results are stale; run regenerate.py")
        print("README.md Results match")
        return
    render(readme, HERE / "results", check=False)
    print(f"wrote Results ({len(load_summaries(HERE / 'results'))} runs)")


if __name__ == "__main__":
    main()
