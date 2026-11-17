#!/usr/bin/env python3
"""Count the fields each sync round sends, from the sizes runs' stream dumps (stdlib only).

  python3 -I stream_fields.py <raw dir>

<raw dir> is run.sh's raw directory: for every sizes run results/<RUN_ID>/<process>.json, its
streams <RUN_ID>/<process>/streams/room-<r>-s-<r>-<i>.bin (every frame one session received, each
a 4-byte big-endian length and the frame, `--stream-dir`) and its records
<RUN_ID>/<process>/records/*.sstr (for the outputs per room). Writes stream-fields.json; regenerate.py
gates and renders from it alone.

What a frame holds (the wire format at the measured commit):
- messagepack: a state update is `[opcode, seq, entry, …]` (StateUpdateOpcode: 0 noChange,
  1 firstSync, 2 diff, 3 resync), sent alone or inside `[107, update, events]` with the events
  merged (EncodingPipeline). An entry is a plain patch `[path, keys, op, value]` (op 1 set, 3 add;
  2 remove has no value) or a merged entry `[parent, keys, op, mask, v1, v2, …]` (op 4 set, 5 add),
  one value per set bit of the mask, in bit order (FieldMergePlan, OpcodeMessagePackStateUpdateEncoder).
- json: a state update is `{"type", "seq", "patches": [{"path", "op", "value"}, …]}`; events and
  the join response are separate frames with a `kind`.

Units, per frame:
- a patch is one entry as sent; a field is one value set or removed: 1 for a plain entry, the
  mask's bit count for a merged one. A set of a whole object is one field.
- entry bytes are the entries' encoded bytes; the overhead is the rest of the frame (wrapper,
  opcode, seq, array headers, json keys and commas) after the entries and, in a merged frame, the
  events element. WebSocket framing and compression are outside the dump.

A full view's entries set whole objects, so its fields are counted by value instead
(`view_fields`): a map whose values are all objects counts its objects' members, another object
its members, anything else 1; a merged entry its mask's bits. These are properties of entities, not
the fields a diff sets, so a size per full-view field is a different population.

A round is one seq of one room (the seq is the room's sync output, the same for every session).
Each session's first state frame is its full view (firstSync); the later ones are diffs, including
key scope resets (a diff typed firstSync). A round's recipients are the sessions with a diff frame
at that seq. An entry that every recipient's frame carries, identical, is counted as broadcast;
the rest as per-player.
"""
import collections
import hashlib
import json
import pathlib
import re
import struct
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC.parent))
import syncmarks  # noqa: E402

STREAM_NAME = re.compile(r"^(room-\d+)-s-\d+-\d+\.bin$")
MERGED_OPS = (4, 5)
PLAIN_OPS = {1: 4, 2: 3, 3: 4}  # op: entry length
JSON_DECODER = json.JSONDecoder()


def frames(data):
    out, i = [], 0
    while i < len(data):
        if i + 4 > len(data):
            raise ValueError(f"cut length at {i}")
        (n,) = struct.unpack_from(">I", data, i)
        if i + 4 + n > len(data):
            raise ValueError(f"cut frame at {i}")
        out.append(data[i + 4:i + 4 + n])
        i += 4 + n
    return out


def array_items(data, i):
    """[(start, end)] of the items of the MessagePack array at `i`, and the array's end."""
    b = data[i]
    if 0x90 <= b <= 0x9F:
        n, j = b & 0x0F, i + 1
    elif b == 0xDC:
        n, j = struct.unpack_from(">H", data, i + 1)[0], i + 3
    elif b == 0xDD:
        n, j = struct.unpack_from(">I", data, i + 1)[0], i + 5
    else:
        raise ValueError(f"no array at {i}")
    spans = []
    for _ in range(n):
        _, end = syncmarks.unpack(data, j)
        spans.append((j, end))
        j = end
    return spans, j


def canonical(value):
    return json.dumps(value, sort_keys=True, default=lambda b: b.hex())


def entry_fields(entry):
    """Fields of one messagepack entry; ValueError unless its layout is one of the two."""
    if not isinstance(entry, list) or len(entry) < 3 or not isinstance(entry[2], int):
        raise ValueError(f"not an entry: {canonical(entry)[:80]}")
    op = entry[2]
    if op in MERGED_OPS:
        bits = bin(entry[3]).count("1") if len(entry) > 3 and isinstance(entry[3], int) else -1
        if bits < 1 or len(entry) != 4 + bits:
            raise ValueError(f"merged entry with {len(entry) - 4} values for mask {entry[3] if len(entry) > 3 else None}")
        return bits
    if PLAIN_OPS.get(op) != len(entry):
        raise ValueError(f"plain entry op {op} with {len(entry)} elements")
    return 1


def view_fields(value):
    """Fields of a value a full view sets (see the module docstring)."""
    if isinstance(value, dict):
        if value and all(isinstance(v, dict) for v in value.values()):
            return sum(len(v) for v in value.values())
        return len(value)
    return 1


def full_view_fields(canonical_entry, encoding):
    entry = json.loads(canonical_entry)
    if encoding == "json":
        return view_fields(entry["value"]) if "value" in entry else 1
    if entry[2] in MERGED_OPS:
        return bin(entry[3]).count("1")
    return view_fields(entry[3]) if len(entry) > 3 else 1


def read_msgpack(frame):
    """One frame as {"kind", ...}: a state update's opcode, seq, entries [(canonical, fields, bytes)],
    its events span and its overhead; or another kind."""
    if frame[:1] == b"{":
        return {"kind": json.loads(frame)["kind"]}
    top, end = array_items(frame, 0)
    if end != len(frame):
        raise ValueError("bytes after the frame")
    first, _ = syncmarks.unpack(frame, top[0][0])
    events = 0
    if first == 107:
        if len(top) != 3:
            raise ValueError(f"opcode 107 frame with {len(top)} items")
        update, _ = array_items(frame, top[1][0])
        events = top[2][1] - top[2][0]
    elif first in (0, 1, 2, 3):
        update = top
    else:
        return {"kind": f"opcode-{first}"}
    opcode, _ = syncmarks.unpack(frame, update[0][0])
    seq, _ = syncmarks.unpack(frame, update[1][0])
    if opcode not in (0, 1, 2, 3) or not isinstance(seq, int):
        raise ValueError(f"state update opcode {opcode}, seq {seq}")
    entries = []
    for start, stop in update[2:]:
        value, _ = syncmarks.unpack(frame, start)
        entries.append((canonical(value), entry_fields(value), stop - start))
    used = events + sum(e[2] for e in entries)
    return {"kind": "state", "opcode": opcode, "seq": seq, "entries": entries, "events": events,
            "overhead": len(frame) - used}


JSON_TYPES = {"noChange": 0, "firstSync": 1, "diff": 2, "resync": 3}


def read_json(frame):
    text = frame.decode("utf-8")
    value = json.loads(text)
    if "patches" not in value:
        return {"kind": value["kind"]}
    key = text.find('"patches":')
    i = key + len('"patches":')
    while text[i].isspace():
        i += 1
    if text[i] != "[":
        raise ValueError("no patches array")
    i += 1
    entries = []
    while True:
        while text[i].isspace() or text[i] == ",":
            i += 1
        if text[i] == "]":
            break
        patch, end = JSON_DECODER.raw_decode(text, i)
        entries.append((canonical(patch), 1, len(text[i:end].encode("utf-8"))))
        i = end
    if [json.loads(e[0]) for e in entries] != value["patches"]:
        raise ValueError("the patches read don't match the frame's")
    if value.get("type") not in JSON_TYPES or not isinstance(value.get("seq"), int):
        raise ValueError(f"state update type {value.get('type')}, seq {value.get('seq')}")
    return {"kind": "state", "opcode": JSON_TYPES[value["type"]], "seq": value["seq"], "entries": entries,
            "events": 0, "overhead": len(frame) - sum(e[2] for e in entries)}


def record_outputs(records_dir):
    """{room: (landID, record sha256, [((broadcastHash, perPlayerHash), resetsKeyScopes)] per output
    in stream order)} from a run's records; output k is seq k."""
    out = {}
    for path in sorted(records_dir.glob("*.sstr")):
        data = path.read_bytes()
        records = syncmarks.read_log(data)
        land = records[0]["metadata"]["landID"]
        room = land.split(":", 1)[1]
        if room in out:
            raise ValueError(f"two records for {room}")
        outputs = [((e.get("broadcastHash"), e.get("perPlayerHash")), e.get("resetsKeyScopes") is True)
                   for kind, e in syncmarks.stream(records) if kind == "output"]
        out[room] = (land, hashlib.sha256(data).hexdigest(), outputs)
    return out


def measure(process_dir, encoding):
    read = read_msgpack if encoding == "messagepack" else read_json
    rooms = collections.defaultdict(lambda: collections.defaultdict(list))  # room -> seq -> [frame]
    kinds = collections.Counter()
    files = 0
    full = collections.Counter()
    for path in sorted((process_dir / "streams").glob("*.bin")):
        m = STREAM_NAME.match(path.name)
        if not m:
            raise ValueError(f"unexpected stream file {path.name}")
        files += 1
        first = True
        for frame in frames(path.read_bytes()):
            f = read(frame)
            if f["kind"] != "state":
                kinds[f["kind"]] += 1
                continue
            if first:
                first = False
                if f["opcode"] != 1:
                    raise ValueError(f"{path.name}: first state frame has opcode {f['opcode']}")
                kinds["full_view"] += 1
                full["entries"] += len(f["entries"])
                full["fields"] += sum(full_view_fields(e[0], encoding) for e in f["entries"])
                full["entry_bytes"] += sum(e[2] for e in f["entries"])
                full["bytes"] += len(frame) - f["events"]
                rooms[m.group(1)][f["seq"]]
                continue
            kinds[{0: "no_change", 1: "key_scope_reset", 2: "diff", 3: "resync"}[f["opcode"]]] += 1
            rooms[m.group(1)][f["seq"]].append(f)
    outputs = record_outputs(process_dir / "records")
    d = collections.Counter()
    overhead_min, overhead_max = None, None
    hist = {"fields": collections.Counter(), "broadcast_fields": collections.Counter()}
    room_out = {}
    for room, seqs in sorted(rooms.items()):
        if room not in outputs:
            raise ValueError(f"no record for {room}")
        land, sha, recorded = outputs[room]
        hashes = [h for h, _ in recorded]
        n = len(hashes)
        silent = [s for s in range(1, n + 1) if s not in seqs]
        room_out[room] = {
            "land_id": land, "record_sha256": sha, "outputs": n,
            "rounds_with_frames": len(seqs), "rounds_without_frames": len(silent),
            "seqs_beyond_outputs": sum(s > n or s < 1 for s in seqs),
            "silent_hashes": sorted({"/".join(map(str, hashes[s - 1])) for s in silent}),
            # A diff round whose output has a frameless output's hashes is a key scope reset whose
            # updates are all empty (a reset sends every recipient one); any other is unexplained.
            "unexplained_rounds": sum(
                bool(seqs[s]) and hashes[s - 1] in {hashes[x - 1] for x in silent}
                and not (recorded[s - 1][1] and all(not f["entries"] for f in seqs[s]))
                for s in seqs if 1 <= s <= n),
            "max_recipients": max(len(v) for v in seqs.values()),
        }
        for seq, fs in seqs.items():
            if not fs:
                continue
            common = None
            for f in fs:
                c = collections.Counter(e[0] for e in f["entries"])
                common = c if common is None else common & c
            fields_of = {e[0]: e[1] for f in fs for e in f["entries"]}
            broadcast = sum(fields_of[k] * v for k, v in common.items())
            sent = sum(e[1] for f in fs for e in f["entries"])
            d["rounds"] += 1
            d["recipients"] += len(fs)
            d["frames"] += len(fs)
            d["patches"] += sum(len(f["entries"]) for f in fs)
            d["fields"] += sent
            d["broadcast_fields"] += broadcast
            d["per_player_fields"] += sent - broadcast * len(fs)
            d["entry_bytes"] += sum(e[2] for f in fs for e in f["entries"])
            d["events_bytes"] += sum(f["events"] for f in fs)
            d["overhead"] += sum(f["overhead"] for f in fs)
            hist["fields"][sent] += 1
            hist["broadcast_fields"][broadcast] += 1
            for f in fs:
                overhead_min = f["overhead"] if overhead_min is None else min(overhead_min, f["overhead"])
                overhead_max = f["overhead"] if overhead_max is None else max(overhead_max, f["overhead"])
    d["bytes"] = d["entry_bytes"] + d["overhead"]
    return {
        "files": files, "frames": dict(kinds), "rooms": room_out,
        "diff": {**dict(d), "overhead_min": overhead_min, "overhead_max": overhead_max,
                 "hist": {k: {str(x): n for x, n in sorted(v.items())} for k, v in hist.items()}},
        "full_view": dict(full),
    }


def main(argv):
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    raw = pathlib.Path(argv[0])
    processes = {}
    for path in sorted((TOPIC / "results").glob("*/*.json")):
        p = json.loads(path.read_text(encoding="utf-8"))["params"]
        if p["kind"] != "sizes":
            continue
        processes[f"{path.parent.name}/{path.stem}"] = measure(raw / path.parent.name / path.stem, p["encoding"])
    out = TOPIC / "stream-fields.json"
    out.write_text(json.dumps({"processes": processes}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {len(processes)} processes to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
