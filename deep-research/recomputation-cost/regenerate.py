#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from the runs under results/.

Compares the sync stream a server sends (A) with the re-evaluation record that reproduces it (B).
Every size is computed here, offline, with one compressor for both sides (gzip level
GZIP_LEVEL, mtime 0), so A and B are aligned before they are compared. The record format and
the runtime are not changed.

Pipeline: run.sh writes raw/<RUN_ID>/<process>/ (ServerLoadTest's loadtest.json, records,
streams, profile.jsonl and the replay outputs; archived outside this repository); collect.py
measures each process directory with the functions here and writes results/<RUN_ID>/<process>.json;
this script gates those results and renders the README tables from them alone, so `--check`
needs no raw files.

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

The verify runs' sync-output verdicts come from sync-output.json (sync_output.py, from the raw
verify outputs): one entry per replayed record of the sizes runs and one per recording-on cost run,
no other, each "Sync Output: passed" with nothing unverifiable or skipped.

The sync stream markers come from sync-marks.json (sync_marks.py, deep-research/syncmarks.py, from
the sizes runs' raw records): one entry per record, as many as the run's rooms, each with the run's
players and one first seed per player.

The fields each sync round sends come from stream-fields.json (stream_fields.py, from the sizes runs'
stream dumps and records): every stream file of the run read and decoded; per room, the record's
outputs equal its rounds with frames plus the outputs that sent nothing (all of them one empty
hash pair, and no diff round carrying it but a key scope reset of empty updates); recipients never
above the run's players; each record the one sync-marks.json counted.

Usage: regenerate.py [--check | --markdown | --self-test | --record-check <process dir>]
"""
import argparse
import gzip
import json
import math
import pathlib
import re
import statistics
import struct
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import provenance  # noqa: E402
import syncmarks  # noqa: E402
import syncoutput  # noqa: E402
import wireform  # noqa: E402

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
    # The decoder reads back every vector, and a 3.x record rebuilds its JSON view.
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


# --- 3.x records (SSTR) ------------------------------------------------------------------
#
# A 3.x record is `SSTR`, a major and a minor version byte, then length-prefixed records (4-byte
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
    """The 2.x JSON view of a 3.x record: {recordMetadata, tickFrames}. A record without a complete
    footer is rejected: the runs measured here are saved when their room closes."""
    if data[:4] != SSTR_MAGIC:
        raise ValueError("not a 3.x record (no SSTR magic)")
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


def native_format(records: list) -> str | None:
    """The record format of a process's records, as stored: a 3.x file's version from its
    header (`SSTR`, then the major and minor byte), "2.x" for a JSON record. None without records
    (a recording-off process); records in more than one format are refused."""
    formats = set()
    for p in records:
        if p.suffix == ".sstr":
            with p.open("rb") as f:
                head = f.read(6)
            if len(head) < 6 or head[:4] != SSTR_MAGIC:
                raise ValueError(f"{p}: not a 3.x record (no SSTR header)")
            formats.add(f"{head[4]}.{head[5]}")
        else:
            formats.add("2.x")
    if len(formats) > 1:
        raise ValueError(f"records in several formats: {sorted(formats)}")
    return formats.pop() if formats else None


def measure_run(run_dir: pathlib.Path) -> dict:
    loadtest = json.loads((run_dir / "loadtest.json").read_text(encoding="utf-8"))
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
        "nativeFormat": native_format(records),
        "B_minimal": {k: sum(s[k] for s in b_minimal) / rooms for k in b_minimal[0]} if b_minimal else None,
        "B_noStateHash": {k: sum(s[k] for s in b_no_hash) / rooms for k in b_no_hash[0]} if b_no_hash else None,
        "B_noEmptyTicks": {k: sum(s[k] for s in b_no_empty) / rooms for k in b_no_empty[0]} if b_no_empty else None,
        "ticksPerRoom": ticks / rooms,
        "inputTicksPerRoom": input_ticks / rooms,
        "A_total_per_room": {"raw": sum(raw) / rooms, "gz": sum(s["gz"] for s in sessions) / rooms},
        "A_session": {"min": min(raw), "median": statistics.median(raw), "max": max(raw)} if raw else None,
    }


# --- Per-process figures (collect.py) ------------------------------------------------------

REPLAY_TIMING = re.compile(r"REPLAY_TIMING run=(\d+) ticks=(\d+) wallMs=([0-9.]+)")
VERIFIED = "Verified state hashes"


def percentile(values: list, q: float):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(q * len(ordered)) - 1))]


def verified(text: str) -> bool:
    return VERIFIED in text and "mismatch" not in text.lower()


def replay_figures(run_dir: pathlib.Path) -> dict:
    """Per replayed record (replay-<name>.txt, verify-<name>.txt, open-<name>.json)."""
    out = {}
    for replay in sorted(run_dir.glob("replay-*.txt")):
        name = replay.stem.removeprefix("replay-")
        timing = {int(m[1]): (int(m[2]), float(m[3])) for m in REPLAY_TIMING.finditer(replay.read_text(encoding="utf-8"))}
        entry = {"ticks": timing[1][0] if 1 in timing else None, "wallMs": timing[1][1] if 1 in timing else None,
                 "verified": False, "open": None}
        verify = run_dir / f"verify-{name}.txt"
        if verify.exists():
            vt = verify.read_text(encoding="utf-8")
            entry["verified"] = verified(vt) and 2 in {int(m[1]) for m in REPLAY_TIMING.finditer(vt)}
        opened = run_dir / f"open-{name}.json"
        if opened.exists():
            line = [ln for ln in opened.read_text(encoding="utf-8").splitlines() if ln.startswith("{")][-1]
            o = json.loads(line)
            entry["open"] = {k: o[k] for k in ("medianMs", "p10Ms", "p90Ms", "repeat", "bytes")}
        out[name] = entry
    return out


def cost_figures(run_dir: pathlib.Path, loadtest: dict) -> dict:
    summary = loadtest["results"]["summary"]
    config = loadtest["metadata"]["loadTestConfig"]
    steady = summary.get("steadySeconds") or 0
    pacing = summary.get("pacing", {})
    cpu = summary.get("process", {}).get("steadyCPUPercentMean")
    rooms, tick_ms = config.get("rooms"), config.get("tickIntervalMs")
    # Actions completed in the steady seconds only: the total also holds ramp-up and ramp-down
    # sends, the latter to sessions closing that second.
    steady_actions = [s["actionsCompletedThisSecond"] for s in loadtest["results"].get("seconds", [])
                      if s.get("phase") == "steady"]
    out = {
        "actionsPerSecond": sum(steady_actions) / len(steady_actions) if steady_actions else None,
        "cpuPercentMean": cpu,
        # One core is 100 %: core-ms per second is cpu × 10, over rooms × ticks per second.
        "coreMsPerRoomTick": cpu * 10 / (rooms * 1000 / tick_ms) if cpu is not None and rooms and tick_ms else None,
        "lateSeconds": pacing.get("lateSeconds"),
        "skippedByCap": pacing.get("skippedByCap"),
    }
    profile = run_dir / "profile.jsonl"
    if profile.exists():
        lines = [json.loads(ln) for ln in profile.read_text(encoding="utf-8").splitlines() if ln.strip()]
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


def record_check(run_dir: pathlib.Path) -> dict:
    """A recording-on process recorded everything: every room's record saved and complete, nothing
    left in the spool, each record spanning the steady phase, the records' actions adding up to the
    actions completed, and the first record verified (verify.txt)."""
    loadtest = json.loads((run_dir / "loadtest.json").read_text(encoding="utf-8"))
    summary, config = loadtest["results"]["summary"], loadtest["metadata"]["loadTestConfig"]
    steady_ticks = config["steadySeconds"] * 1000 // config["tickIntervalMs"]
    records = sorted((run_dir / "records").glob("*.sstr"))
    spool = run_dir / "records" / "spool"
    incomplete, ticks, actions = 0, [], 0
    for path in records:
        try:
            record = read_record_log(path.read_bytes())
        except ValueError:
            incomplete += 1
            continue
        ticks.append(len(record["tickFrames"]))
        # ServerLoadTest's inputs are client events (MoveTo); count actions too.
        actions += sum(len(f.get("actions") or []) + len(f.get("clientEvents") or []) for f in record["tickFrames"])
    verify = run_dir / "verify.txt"
    out = {
        "rooms": config["rooms"], "records": len(records),
        "spoolLeft": len(list(spool.iterdir())) if spool.exists() else 0,
        "incomplete": incomplete, "minTicks": min(ticks) if ticks else 0, "steadyTicks": steady_ticks,
        "recordedActions": actions, "actionsCompleted": summary["totalActionsCompleted"],
        "verified": verify.exists() and verified(verify.read_text(encoding="utf-8")),
    }
    out["pass"] = (out["records"] == out["rooms"] and out["spoolLeft"] == 0 and incomplete == 0
                   and out["minTicks"] >= steady_ticks and actions == out["actionsCompleted"] and out["verified"])
    return out


# --- Gates ------------------------------------------------------------------------------

CELLS = [(p, c) for p in (2, 5, 10) for c in (5, 20)]
PINNED_SWIFT = "6.2.4"
CONSTANTS = {"sizeRooms": 10, "costRooms": 200, "steadySeconds": 30, "rampSeconds": 5, "openRepeat": 200, "costRepeats": 4}
COST_ORDERS = {1: ("on", "off"), 2: ("off", "on"), 3: ("off", "on"), 4: ("on", "off")}  # ABBA
# The wire form each encoding's runs must have: main's defaults since #308. The path index and
# field merge apply to the opcode encodings only, so a JSON server gives no features.
INTENDED_WIRE = {
    # Row addressing off: these runs predate its default (#392).
    "messagepack": wireform.WireForm("messagepack", True, True, False),
    "json": wireform.WireForm("json", False, False, False),
}


def wire_form(run: dict) -> wireform.WireForm:
    """The run's effective wire form (``wireform.resolve``); raises ``wireform.MissingWireForm``."""
    wire = run.get("wire") or {}
    if wire.get("recorded") and wire.get("stateUpdateFeatures") is None:
        raise wireform.MissingWireForm(f"the joins agreed on no stateUpdateFeatures: {wire.get('joinFeatures')}")
    features = wire.get("stateUpdateFeatures") if wire.get("recorded") else None
    return wireform.resolve(run["meta"].get("git_sha"), run["params"]["encoding"], features=features)


def load(results_dir: pathlib.Path) -> list:
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted(results_dir.glob("*/*.json"))]


def check(runs: list) -> None:
    failures = []
    sizes, replays, cost, noise = set(), {}, {}, 0
    for r in runs:
        p, meta = r["params"], r["meta"]
        name = r["name"]
        if meta.get("build_config") != "release":
            failures.append(f"{name}: not a release build")
        if meta.get("git_dirty") is not False:
            failures.append(f"{name}: not from a clean tree (git dirty: {meta.get('git_dirty')})")
        if PINNED_SWIFT not in (meta.get("swift_version") or ""):
            failures.append(f"{name}: Swift {meta.get('swift_version')!r}, not the pinned {PINNED_SWIFT}")
        for key, value in CONSTANTS.items():
            if meta.get(key) != value:
                failures.append(f"{name}: {key} {meta.get(key)!r}, the matrix has {value!r}")
        rooms = CONSTANTS["sizeRooms"] if p["kind"] == "sizes" else CONSTANTS["costRooms"]
        if p["rooms"] != rooms or p["steadySeconds"] != CONSTANTS["steadySeconds"]:
            failures.append(f"{name}: {p['rooms']} rooms, {p['steadySeconds']} s steady; the matrix has {rooms}, {CONSTANTS['steadySeconds']}")
        try:
            form = wire_form(r)
            failures += wireform.check({name: form}, INTENDED_WIRE[p["encoding"]])
        except wireform.MissingWireForm as missing:
            failures.append(f"{name}: wire form missing: {missing}")
        cell = (p["players"], p["cadence"])
        if p["kind"] == "sizes":
            sizes.add((p["encoding"], cell, p["repeat"]))
            if p["encoding"] == "messagepack" and p["repeat"] == 1:
                replays[cell] = r["replay"]
            continue
        c = r["cost"]
        if c.get("lateSeconds") != 0 or c.get("skippedByCap") != 0:
            failures.append(f"{name}: saturated (late seconds {c.get('lateSeconds')}, skipped {c.get('skippedByCap')})")
        if not c.get("profileWindows"):
            failures.append(f"{name}: no profiling windows")
        if p["kind"] == "noise":
            noise += 1
            continue
        if p["side"] == "on" and not (r.get("recordCheck") or {}).get("pass"):
            failures.append(f"{name}: the record check failed: {r.get('recordCheck')}")
        # The process's start time orders the sides within a repeat.
        cost.setdefault(cell, {}).setdefault(p["repeat"], {})[p["side"]] = p["startedAt"]
    for cell in CELLS:
        label = f"p{cell[0]}-c{cell[1]}"
        for enc in ("messagepack", "json"):
            if (enc, cell, 1) not in sizes:
                failures.append(f"{label}: no {enc} sizes run")
        entries = replays.get(cell, {})
        if len(entries) < 2 or not all(e["verified"] and e["open"] for e in entries.values()):
            failures.append(f"{label}: replay needs 2 verified records with open timings, has {entries}")
        reps = cost.get(cell, {})
        for rep, order in COST_ORDERS.items():
            got = reps.get(rep, {})
            if set(got) != {"on", "off"}:
                failures.append(f"{label} rep{rep}: cost sides {sorted(got)}, expected on and off")
            elif tuple(sorted(got, key=got.get)) != order:
                failures.append(f"{label} rep{rep}: ran {'-'.join(sorted(got, key=got.get))}, the ABBA order has {'-'.join(order)}")
    if ("messagepack", (10, 5), 2) not in sizes:
        failures.append("p10-c5: no second sizes repeat")
    if noise != 2:
        failures.append(f"{noise} noise runs, expected 2")
    try:
        provenance.line(provenance.from_results(runs), node=False)
    except provenance.Refused as e:
        failures.append(str(e))
    if failures:
        sys.exit("results not usable:\n  " + "\n  ".join(failures))


# --- Tables ----------------------------------------------------------------------------


def kib(n) -> str:
    return f"{n / 1024:.1f}"


def num(x, fmt=".2f") -> str:
    return format(x, fmt) if x is not None else "n/a"


def size_tables(runs: list) -> list:
    lines = [
        "Per room, KiB; A is per room-minute of stream; B covers the same run length. gzip level "
        f"{GZIP_LEVEL} on both sides. {CONSTANTS['sizeRooms']} rooms per run.",
        "",
        "| enc | players | cadence | repeat | A raw/min | A gz/min | A session min/med/max | "
        "B_native / gz | B_asStored msgpack / gz | B_asStored json / gz | B_minimal msgpack / gz | "
        "B_minimal json / gz | B_asStored msgpack gz ÷ A gz |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in runs:
        s, p = r["sizes"], r["params"]
        a, sess, bs, bm, bn = s["A_total_per_room"], s["A_session"], s["B_asStored"], s["B_minimal"], s["B_native"]
        per_min = 1 / s["minutes"] if s["minutes"] else 0
        ratio = bs["msgpack_gz"] / a["gz"] if a["gz"] else float("nan")
        lines.append(
            f"| {p['encoding']} | {p['players']} | {p['cadence']} | {p['repeat']} | "
            f"{kib(a['raw'] * per_min)} | {kib(a['gz'] * per_min)} | "
            f"{kib(sess['min'])}/{kib(sess['median'])}/{kib(sess['max'])} | {kib(bn['bytes'])} / {kib(bn['gz'])} | "
            f"{kib(bs['msgpack'])} / {kib(bs['msgpack_gz'])} | {kib(bs['json'])} / {kib(bs['json_gz'])} | "
            f"{kib(bm['msgpack'])} / {kib(bm['msgpack_gz'])} | {kib(bm['json'])} / {kib(bm['json_gz'])} | {ratio:.3f} |"
        )
    lines += ["", "The A gzip column compresses each session's whole stream as one blob; a live "
              "stream is sent frame by frame and can't be compressed that way.", ""]
    lines += [
        "Where B's overhead lands (MessagePack plus gzip, KiB per room, each over A gz). Each middle "
        "column drops one thing from B_asStored; B_minimal drops both, plus serverEvents, "
        "syncOutputs and syncMarkers.",
        "",
        "| enc | players | cadence | repeat | ticks / with input | B_asStored | no stateHash | no input-free ticks | B_minimal |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for r in runs:
        s, p = r["sizes"], r["params"]
        a = s["A_total_per_room"]["gz"]
        cell = lambda b: f"{kib(b['msgpack_gz'])} ({b['msgpack_gz'] / a:.3f})" if a else kib(b["msgpack_gz"])
        lines.append(
            f"| {p['encoding']} | {p['players']} | {p['cadence']} | {p['repeat']} | "
            f"{s['ticksPerRoom']:.0f} / {s['inputTicksPerRoom']:.0f} | {cell(s['B_asStored'])} | "
            f"{cell(s['B_noStateHash'])} | {cell(s['B_noEmptyTicks'])} | {cell(s['B_minimal'])} |"
        )
    return lines + [""]


def replay_table(runs: list) -> list:
    lines = [
        "Replay, per replayed record (the first two of each messagepack sizes run): run 1's wall time, "
        f"and the open (decode) median of {CONSTANTS['openRepeat']} opens. `--verify` passed on every one.",
        "",
        "| players | cadence | record | ticks | replay ms | µs / tick | × realtime | open median ms |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in runs:
        p = r["params"]
        for name, e in sorted(r["replay"].items()):
            ticks, wall = e["ticks"], e["wallMs"]
            per_tick = wall * 1000 / ticks if ticks and wall is not None else None
            realtime = ticks * r["tickIntervalMs"] / wall if ticks and wall else None
            lines.append(f"| {p['players']} | {p['cadence']} | {name} | {ticks} | {num(wall, '.1f')} | "
                         f"{num(per_tick, '.1f')} | {num(realtime, '.0f')} | {num(e['open']['medianMs'], '.3f')} |")
    return lines + [""]


COST_FIELDS = [
    ("tick lag p99 ms", "lagP99Ms", ".2f"), ("encode p99 ms", "encodeP99MsMedian", ".2f"),
    ("send p99 ms", "sendP99MsMedian", ".2f"), ("extract mean ms", "sync_extractMeanMs", ".3f"),
    ("broadcast mean ms", "sync_broadcastMeanMs", ".3f"), ("per-player mean ms", "sync_perplayerMeanMs", ".3f"),
]


def mean(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def cost_tables(runs: list) -> list:
    by_cell = {}
    for r in runs:
        if r["params"]["kind"] == "cost":
            p = r["params"]
            by_cell.setdefault((p["players"], p["cadence"]), {}).setdefault(p["repeat"], {})[p["side"]] = r["cost"]
    lines = [
        f"Recording cost, {CONSTANTS['costRooms']} rooms, recording on against off, {CONSTANTS['costRepeats']} repeats "
        "in ABBA order (on-off, off-on, off-on, on-off). ServerLoadTest runs the simulated clients in the "
        "same process, so CPU is the server's and the clients' together: the on − off difference is the "
        "recording's cost, and the on ÷ off ratio understates it (its denominator includes the clients). "
        "CPU % is of one core; core-ms per room-tick is CPU over rooms × ticks. The paired ratio is each "
        "repeat's on ÷ off, its median and [min–max] over the repeats.",
        "",
        "| players | cadence | actions/s on / off | CPU % on / off | on − off, CPU points | on − off, core-ms / room-tick | "
        "CPU on ÷ off, median [min–max] |",
        "|---|---|---|---|---|---|---|",
    ]
    for cell in CELLS:
        reps = by_cell.get(cell, {})
        on = [reps[k]["on"] for k in sorted(reps) if "on" in reps[k]]
        off = [reps[k]["off"] for k in sorted(reps) if "off" in reps[k]]
        if not on or not off:
            continue
        ratios = [reps[k]["on"]["cpuPercentMean"] / reps[k]["off"]["cpuPercentMean"] for k in sorted(reps)
                  if {"on", "off"} <= set(reps[k]) and reps[k]["off"]["cpuPercentMean"]]
        cpu_on, cpu_off = mean(c["cpuPercentMean"] for c in on), mean(c["cpuPercentMean"] for c in off)
        core_on, core_off = mean(c["coreMsPerRoomTick"] for c in on), mean(c["coreMsPerRoomTick"] for c in off)
        lines.append(
            f"| {cell[0]} | {cell[1]} | {num(mean(c['actionsPerSecond'] for c in on), '.1f')} / "
            f"{num(mean(c['actionsPerSecond'] for c in off), '.1f')} | {num(cpu_on, '.1f')} / {num(cpu_off, '.1f')} | "
            f"{num(cpu_on - cpu_off, '+.1f')} | {num(core_on - core_off, '+.4f')} | "
            f"{statistics.median(ratios):.3f} [{min(ratios):.3f}–{max(ratios):.3f}] |"
        )
    lines += ["", "The sync and send figures, mean over the repeats, on / off (tick lag: the ticker's lag p99 "
              "over the profiling windows; encode and send: the median of the windows' p99; the sync "
              "phases: means per full sync plan).", "",
              "| players | cadence | " + " | ".join(label for label, _, _ in COST_FIELDS) + " |",
              "|---|---|" + "---|" * len(COST_FIELDS)]
    for cell in CELLS:
        reps = by_cell.get(cell, {})
        on = [reps[k]["on"] for k in sorted(reps) if "on" in reps[k]]
        off = [reps[k]["off"] for k in sorted(reps) if "off" in reps[k]]
        if not on or not off:
            continue
        cells = [f"{num(mean(c.get(f) for c in on), fmt)} / {num(mean(c.get(f) for c in off), fmt)}" for _, f, fmt in COST_FIELDS]
        lines.append(f"| {cell[0]} | {cell[1]} | " + " | ".join(cells) + " |")
    noise = sorted((r for r in runs if r["params"]["kind"] == "noise"), key=lambda r: r["params"]["side"])
    if len(noise) == 2:
        a, b = (r["cost"]["cpuPercentMean"] for r in noise)
        lines += ["", f"Noise floor: two recording-off processes at 10 players, cadence 5: CPU {a:.1f} % and "
                  f"{b:.1f} %, ratio {b / a:.3f}, difference {b - a:+.1f} points."]
    return lines + [""]


SYNC_OUTPUT = HERE / "sync-output.json"


def sync_outputs(runs: list, path: pathlib.Path = SYNC_OUTPUT) -> dict:
    """{"sizes": [...], "cost": [...]} verdicts from sync-output.json, after its gate; exits naming
    every failure. Expected: verify-<record>.txt per replayed record of a sizes run, verify.txt per
    recording-on cost run."""
    outputs = json.loads(path.read_text(encoding="utf-8"))["outputs"]
    expected = {}
    for r in runs:
        p = r["params"]
        if p["kind"] == "sizes":
            for record in r.get("replay") or {}:
                expected[f"{r['name']}/verify-{record}.txt"] = "sizes"
        elif p["kind"] == "cost" and p["side"] == "on":
            expected[f"{r['name']}/verify.txt"] = "cost"
    failures = []
    if set(outputs) != set(expected):
        failures.append(f"sync-output.json lists {sorted(set(outputs) ^ set(expected))} unlike the runs' verify outputs")
    groups = {"sizes": [], "cost": []}
    for name, kind in expected.items():
        if name in outputs:
            groups[kind].append(outputs[name])
    for kind, entries in groups.items():
        failures += syncoutput.failures(syncoutput.total(entries), f"{kind} verify runs")
    if failures:
        sys.exit("sync output not usable:\n  " + "\n  ".join(failures))
    return groups


SYNC_MARKS = HERE / "sync-marks.json"


def sync_marks(runs: list, path: pathlib.Path = SYNC_MARKS) -> list:
    """The sizes runs' record entries from sync-marks.json, after its gate; exits naming every failure."""
    records = json.loads(path.read_text(encoding="utf-8"))["records"]
    sizes = {r["name"]: r["params"] for r in runs if r["params"]["kind"] == "sizes"}
    failures, seen = [], {}
    for key, e in records.items():
        run = key.rsplit("/", 1)[0]
        if run not in sizes:
            failures.append(f"sync-marks.json: {key} is not a sizes run's record")
            continue
        seen[run] = seen.get(run, 0) + 1
        p = sizes[run]
        if e["format"] != "3.1":
            failures.append(f"{key}: record format {e['format']}")
        if e["players"] != p["players"] or e["seeds_first"] != p["players"]:
            failures.append(f"{key}: {e['players']} players with {e['seeds_first']} first seeds; the run has {p['players']} per room")
        later = e["seeds_later_rejoin"] + e["seeds_later_after_clear"] + e["seeds_later_other"]
        if later != e["seeds_later"] or e["seeds_first"] + e["seeds_later"] != e["markers"]["seed"]:
            failures.append(f"{key}: seed counts don't add up")
        if set(e["partial"]) != set(syncmarks.PARTIAL):
            failures.append(f"{key}: partial counts {sorted(e['partial'])}")
    for run, p in sizes.items():
        if seen.get(run, 0) != p["rooms"]:
            failures.append(f"{run}: {seen.get(run, 0)} records in sync-marks.json, {p['rooms']} rooms")
    if failures:
        sys.exit("sync marks not usable:\n  " + "\n  ".join(failures))
    return list(records.values())


def sync_marks_lines(entries: list) -> list:
    s = lambda k: sum(e[k] for e in entries)
    m = lambda k: sum(e["markers"][k] for e in entries)
    partial = sum(sum(e["partial"].values()) for e in entries)
    return [f"Sync stream markers in the {len(entries)} records the sizes runs kept (the cost runs' records aren't kept; "
            "`sync-marks.json`, from each record file). A full view sent to a player is a `seed` marker: its first view (firstSync), "
            "a rejoin, or, after a `clear` for that player, a resync in place. An output that resets the dynamic key scopes "
            "types every recipient's update `.firstSync`; it carries a diff, not a full view. Partial outputs are those the "
            "format marks as not committed, not sent, not verifiable or dropped in encoding or extraction, and seeds whose view "
            "isn't verifiable. The format writes nothing for a sync phase that planned nothing (skipped or deferred in the live "
            "run), so those aren't in any record.", "",
            "| records | players | first seeds | later seeds | rejoin | after a clear | other | clears | outputs | key scope resets | partial outputs and seeds |",
            "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
            f"| {len(entries)} | {s('players'):,} | {s('seeds_first'):,} | {s('seeds_later'):,} | {s('seeds_later_rejoin'):,} | "
            f"{s('seeds_later_after_clear'):,} | {s('seeds_later_other'):,} | {m('clear'):,} | {s('outputs'):,} | "
            f"{s('key_scope_resets'):,} | {partial:,} |", ""]


STREAM_FIELDS = HERE / "stream-fields.json"
FRAME_KINDS = {"joinResponse", "event", "full_view", "diff", "key_scope_reset", "no_change", "resync"}
DIFF_KINDS = ("diff", "key_scope_reset", "no_change", "resync")


def stream_fields(runs: list, path: pathlib.Path = STREAM_FIELDS, marks: pathlib.Path = SYNC_MARKS) -> dict:
    """{process: entry} from stream-fields.json for the sizes runs, after its gate; exits naming every failure."""
    processes = json.loads(path.read_text(encoding="utf-8"))["processes"]
    marked = {}
    for key, e in json.loads(marks.read_text(encoding="utf-8"))["records"].items():
        marked.setdefault(key.rsplit("/", 1)[0], set()).add(e["sha256"])
    sizes = {r["name"]: r["params"] for r in runs if r["params"]["kind"] == "sizes"}
    failures, silent = [], set()
    if set(processes) != set(sizes):
        failures.append(f"stream-fields.json lists {sorted(set(processes) ^ set(sizes))} unlike the sizes runs")
    for name, e in processes.items():
        p = sizes.get(name)
        if p is None:
            continue
        sessions = p["players"] * p["rooms"]
        frames, d = e["frames"], e["diff"]
        if e["files"] != sessions or frames.get("full_view") != sessions:
            failures.append(f"{name}: {e['files']} stream files, {frames.get('full_view')} full views; the run has {sessions} sessions")
        if set(frames) - FRAME_KINDS:
            failures.append(f"{name}: frames of unknown kinds {sorted(set(frames) - FRAME_KINDS)}")
        if sum(frames.get(k, 0) for k in DIFF_KINDS) != d["frames"] or d["frames"] != d["recipients"]:
            failures.append(f"{name}: diff frames don't add up")
        if d["bytes"] != d["entry_bytes"] + d["overhead"]:
            failures.append(f"{name}: bytes aren't entries plus overhead")
        if not d["frames"] or not d["overhead_min"] * d["frames"] <= d["overhead"] <= d["overhead_max"] * d["frames"]:
            failures.append(f"{name}: the mean overhead per frame isn't within its min and max")
        if d["fields"] != sum(int(k) * v for k, v in d["hist"]["fields"].items()) \
                or d["broadcast_fields"] != sum(int(k) * v for k, v in d["hist"]["broadcast_fields"].items()) \
                or sum(d["hist"]["fields"].values()) != d["rounds"] or sum(d["hist"]["broadcast_fields"].values()) != d["rounds"]:
            failures.append(f"{name}: per-round histograms don't match the totals")
        if len(e["rooms"]) != p["rooms"]:
            failures.append(f"{name}: {len(e['rooms'])} rooms, the run has {p['rooms']}")
        if {r["record_sha256"] for r in e["rooms"].values()} != marked.get(name, set()):
            failures.append(f"{name}: its records aren't the ones sync-marks.json counted")
        for room, r in e["rooms"].items():
            if r["outputs"] != r["rounds_with_frames"] + r["rounds_without_frames"] or r["seqs_beyond_outputs"]:
                failures.append(f"{name} {room}: {r['outputs']} outputs, {r['rounds_with_frames']} rounds with frames, "
                                f"{r['rounds_without_frames']} without, {r['seqs_beyond_outputs']} beyond")
            if r["unexplained_rounds"]:
                failures.append(f"{name} {room}: {r['unexplained_rounds']} rounds carry a frameless output's hashes")
            if r["max_recipients"] > p["players"]:
                failures.append(f"{name} {room}: {r['max_recipients']} recipients, the run has {p['players']} players")
            silent |= set(r["silent_hashes"])
    if len(silent) > 1:
        failures.append(f"frameless outputs carry {len(silent)} different hash pairs")
    if failures:
        sys.exit("stream fields not usable:\n  " + "\n  ".join(failures))
    return {name: {**e, "params": sizes[name]} for name, e in processes.items()}


def hist_median(hist: dict) -> float:
    values = sorted((int(k), n) for k, n in hist.items())
    total, seen = sum(n for _, n in values), 0
    lo = hi = None
    for v, n in values:
        if lo is None and seen + n > (total - 1) // 2:
            lo = v
        if hi is None and seen + n > total // 2:
            hi = v
        seen += n
    return (lo + hi) / 2


def stream_field_lines(processes: dict) -> list:
    key = lambda name: (processes[name]["params"]["encoding"], processes[name]["params"]["players"],
                        processes[name]["params"]["cadence"], processes[name]["params"]["repeat"])
    names = sorted(processes, key=key)
    pooled = lambda pred, part, k: sum(processes[n][part][k] for n in names if pred(processes[n]["params"]))
    size = lambda enc, pred: pooled(lambda p: p["encoding"] == enc and pred(p), "diff", "entry_bytes") / \
        pooled(lambda p: p["encoding"] == enc and pred(p), "diff", "fields")
    full = {enc: pooled(lambda p: p["encoding"] == enc, "full_view", "entry_bytes") /
            pooled(lambda p: p["encoding"] == enc, "full_view", "fields") for enc in INTENDED_WIRE}
    label = lambda p: f"{p['encoding']} p{p['players']} c{p['cadence']} r{p['repeat']}"
    lines = ["### Sync bytes against the fields sent", "",
             "Each sizes run's stream dump (`--stream-dir`) holds every frame each session received; `stream-fields.json` "
             "(`stream_fields.py`) decodes all of them. A round is one sync output of one room (its seq, the same in every "
             "session's frames). A patch is one entry of a frame as sent; a field is one value it sets or removes: 1 for a "
             "plain entry, the mask's bit count for a merged entry (`[parent, keys, op, mask, v1, …]`, one value per bit). "
             "Each session's first state frame is its full view and isn't counted here; the later ones, key scope resets "
             "included, are. Measured bytes are a frame's bytes without the events merged into it: its entries plus a fixed "
             "overhead (wrapper, opcode, seq, array headers, json keys and commas). The join response and event frames are "
             "left out, and so are WebSocket framing and compression. An entry carried, identical, by every recipient's "
             "frame of a round counts as broadcast, the rest as per-player.", "",
             "| run | rounds | recipients | broadcast fields per round (mean / median) | per-player fields per round | "
             "patches per round | fields per round (mean / median) | measured bytes per round |",
             "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for n in names:
        e, p = processes[n]["diff"], processes[n]["params"]
        r = e["rounds"]
        lines.append(f"| {label(p)} | {r:,} | {e['recipients'] / r:.2f} | {e['broadcast_fields'] / r:.2f} / "
                     f"{hist_median(e['hist']['broadcast_fields']):g} | {e['per_player_fields'] / r:.2f} | {e['patches'] / r:.1f} | "
                     f"{e['fields'] / r:.1f} / {hist_median(e['hist']['fields']):g} | {e['bytes'] / r:,.1f} |")
    rooms = [r for n in names for r in processes[n]["rooms"].values()]
    per_player = sum(processes[n]["diff"]["per_player_fields"] for n in names)
    lines += ["", f"Rounds are the records' sync outputs: {sum(r['outputs'] for r in rooms):,} in {len(rooms)} rooms, of which "
              f"{sum(r['rounds_without_frames'] for r in rooms)} sent no frame (all with the same broadcast and per-player "
              "hashes, those of an empty update). "
              + ("No round in any run sent a per-player field: every entry was in every recipient's frame. This check "
                 "therefore covers the model's broadcast term only; this workload doesn't exercise its per-player term."
                 if per_player == 0 else f"{per_player:,} fields were per-player.")]
    overhead = lambda enc, pred: pooled(lambda p: p["encoding"] == enc and pred(p), "diff", "overhead") / \
        pooled(lambda p: p["encoding"] == enc and pred(p), "diff", "frames")
    lines += ["", "The model: bytes per round ≈ (broadcast fields × recipients + per-player fields) × s, with s a mean size "
              "per field. s is the entries' bytes over their fields, per encoding, from the runs at the other cadence, so "
              "no row is predicted from its own bytes. That model leaves out the fixed overhead each frame carries, and "
              "the measured / predicted ratio's excess over 1 is that overhead. The variant adds it: predicted bytes per "
              "round ≈ fields × s + frames × c, with c the mean overhead per frame, also per encoding from the runs at "
              "the other cadence.", "",
              "| run | s, other cadence (B) | predicted bytes per round | measured bytes per round | measured / predicted | "
              "c, other cadence (B) | predicted with c | measured / predicted with c |",
              "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for n in names:
        e, p = processes[n]["diff"], processes[n]["params"]
        other = lambda q, c=p["cadence"]: q["cadence"] != c
        s, c = size(p["encoding"], other), overhead(p["encoding"], other)
        r = e["rounds"]
        predicted, with_c = s * e["fields"], s * e["fields"] + c * e["frames"]
        lines.append(f"| {label(p)} | {s:.2f} | {predicted / r:,.1f} | {e['bytes'] / r:,.1f} | {e['bytes'] / predicted:.3f} | "
                     f"{c:.2f} | {with_c / r:,.1f} | {e['bytes'] / with_c:.3f} |")
    lines += ["", "A second s comes from the full views: their entries' bytes over their fields, a map of objects counting "
              "its objects' members. Those fields are entity properties set all at once when a session starts, a different "
              "population from the fields a diff sets, and that s doesn't predict the steady-state bytes; it is shown only "
              "for comparison.", "",
              "| run | s, full views (B) | predicted from full views | measured bytes per round |",
              "|---|---:|---:|---:|"]
    for n in names:
        e, p = processes[n]["diff"], processes[n]["params"]
        r = e["rounds"]
        lines.append(f"| {label(p)} | {full[p['encoding']]:.2f} | {full[p['encoding']] * e['fields'] / r:,.1f} | "
                     f"{e['bytes'] / r:,.1f} |")
    for enc in sorted(INTENDED_WIRE):
        mine = [processes[n]["diff"] for n in names if processes[n]["params"]["encoding"] == enc]
        frames, overhead = sum(e["frames"] for e in mine), sum(e["overhead"] for e in mine)
        lines += ["", f"Fixed overhead per frame, {enc}: {overhead / frames:.1f} B on average "
                  f"({min(e['overhead_min'] for e in mine)}–{max(e['overhead_max'] for e in mine)} B), "
                  f"{overhead / sum(e['bytes'] for e in mine) * 100:.1f} % of the measured bytes."]
    lines += ["", "Only this topic's sizes runs kept every frame; the EncodingBenchmark and ws-loadtest data sets record bytes "
              "per sync or per update but no fields per round, so this check covers this topic only.", ""]
    return lines


def sync_output_lines(groups: dict) -> list:
    every = syncoutput.total(groups["sizes"] + groups["cost"])
    lines = [f"Sync output: all {every['records']} verify runs ({len(groups['sizes'])} replayed records of the sizes runs, "
             f"the first record of each of the {len(groups['cost'])} recording-on cost runs) report \"Sync Output: passed\" with 0 unverifiable and 0 skipped "
             "(`sync-output.json`, from each run's verify output). Compared:", "",
             "| verify runs | runs | " + " | ".join(syncoutput.KINDS) + " |", "|---|---|" + "---|" * len(syncoutput.KINDS)]
    for label, entries in (("sizes", groups["sizes"]), ("cost", groups["cost"]), ("all", groups["sizes"] + groups["cost"])):
        s = syncoutput.total(entries)
        lines.append(f"| {label} | {s['records']} | " + " | ".join(f"{s['counts'][k][0]:,}" for k in syncoutput.KINDS) + " |")
    return lines + [""]


def results_markdown(runs: list, sync: dict | None = None, marks: list | None = None, fields: dict | None = None) -> str:
    """The Results section; `sync` (sync_outputs) adds the verify runs' sync-output lines, `marks`
    (sync_marks) the sync stream markers of the kept records, `fields` (stream_fields) the fields per round."""
    lines = [RESULTS_HEADING, ""]
    if not runs:
        return "\n".join(lines + ["No runs yet.", "", RESULTS_END])
    key = lambda r: (r["params"]["encoding"], r["params"]["players"], r["params"]["cadence"], r["params"]["repeat"])
    sizes = sorted((r for r in runs if r["params"]["kind"] == "sizes"), key=key)
    replayed = [r for r in sizes if r["replay"]]
    forms = "; ".join(f"{enc} runs: {form.caption()}" for enc, form in INTENDED_WIRE.items())
    lines += [provenance.line(provenance.from_results(runs), node=False), "", f"Wire form (checked per run): {forms}.", ""]
    lines += size_tables(sizes) + replay_table(replayed) + (sync_output_lines(sync) if sync is not None else []) + (sync_marks_lines(marks) if marks is not None else []) + (stream_field_lines(fields) if fields is not None else []) + cost_tables(runs) + [RESULTS_END]
    return "\n".join(lines)


def render(readme_path: pathlib.Path, runs: list, check_only: bool) -> bool:
    generated = results_markdown(runs, sync_outputs(runs) if runs else None, sync_marks(runs) if runs else None,
                            stream_fields(runs) if runs else None)
    readme = readme_path.read_text(encoding="utf-8")
    start, end = readme.index(RESULTS_HEADING), readme.index(RESULTS_END) + len(RESULTS_END)
    if check_only:
        return readme[start:end] == generated
    readme_path.write_text(readme[:start] + generated + readme[end:], encoding="utf-8")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="Fail if README.md's Results differ from results/.")
    ap.add_argument("--markdown", action="store_true", help="Print the Results section.")
    ap.add_argument("--self-test", action="store_true", help="Run the encoder and reader tests only.")
    ap.add_argument("--record-check", metavar="RUN_DIR", type=pathlib.Path,
                    help="Check a recording-on process's records; write <dir>/record-check.json, exit 1 on failure.")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return
    if args.record_check:
        out = record_check(args.record_check)
        (args.record_check / "record-check.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        if not out["pass"]:
            sys.exit(f"record check failed for {args.record_check}: {out}")
        return
    runs = load(HERE / "results")
    if runs:
        check(runs)
    if args.markdown:
        print(results_markdown(runs, sync_outputs(runs) if runs else None, sync_marks(runs) if runs else None,
                            stream_fields(runs) if runs else None))
        return
    readme = HERE / "README.md"
    if args.check:
        if not render(readme, runs, check_only=True):
            sys.exit("MISMATCH: README.md Results are stale; run regenerate.py")
        print("OK")
        return
    render(readme, runs, check_only=False)
    print(f"wrote Results ({len(runs)} runs)")


if __name__ == "__main__":
    main()
