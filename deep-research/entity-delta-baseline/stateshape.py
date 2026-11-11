#!/usr/bin/env python3
"""SST's per-client sync state by a fixed counting rule, from a `--capture-views` directory
(stdlib only).

  python3 stateshape.py <capture dir> <out.json>

What SST keeps for a land's sync, as the Sources hold it, at 75222b87:
- one broadcast snapshot per land (`SyncEngine.lastBroadcastSnapshot`): the fields whose policy
  is broadcast (`extractBroadcastSnapshot` takes `.broadcast` only);
- one per-player snapshot per player (`SyncEngine.lastPerPlayerSnapshots`): every other synced
  field (`extractPerPlayerSnapshot` takes all but `.broadcast` and `.serverOnly`, so `.masked`,
  `.perPlayer` and `.perPlayerSlice` are per player);
- with the path-hash formats and dynamic-key compression on, one dynamic-key table per scope
  (`DynamicKeyScope`: `.broadcast(landID)` and `.perPlayer(landID, playerID)`), key string to
  slot, never freed; the encoder recreates a scope's table when it encodes a firstSync or resync
  in that scope (`table(for:reset:)`).

The capture holds, after every sync, each player's projection (`SyncEngine.snapshot(for:mode:
.all)`, the same snapshot tree as JSON), every frame the transport sent with its target, and the
land's schema. The snapshots are the last sync's projection split by policy. The dynamic-key
tables are replayed from the frames, as the encoder fills them: a table gains the keys the frames
of its scope define (`[slot, "key"]` at an entry's dynamic-key position; the encoder reserves a
slot only for a key on an encoded patch path) and is emptied by a firstSync or resync frame of its
scope. The broadcast scope's frames are the opcode 107 frames (the broadcast update merged with
events, encoded once per land and sent to every recipient); the per-player scope's are the plain
state-update frames, `[opcode, syncSeq?, entry...]`, each sent to one session of its player.
(If packing the merged frame failed, `encodeMergedBroadcastFrame` would send the broadcast update
as a plain frame, which this replay would read as per-player: its slot references would fail the
self-check, its definitions would not. Packing an already built array doesn't fail in practice.)

The counting rule mirrors the entity-delta baseline's (B2's) rule in the plan
(`Notes/plans/2026-11-07-entity-delta-baseline.md`, Metrics), constant for constant:
- every keyed entry (a struct field or a map entry: in SST's snapshot both are entries of a
  `[String: SnapshotValue]` dictionary) counts B2's keyed-entry constant, its key's UTF-8 bytes
  plus 16 (B2's slot entry);
- every leaf value (null, bool, number, string; an array element that isn't an object) counts
  B2's stored-value constant, 9 bytes;
- every dynamic-key table entry counts the keyed-entry constant, its key's UTF-8 bytes plus 16
  (B2's slot entry: a key and its slot).
B2's third term, its per-client field table (a path's UTF-8 bytes plus 8 per entry), has no SST
counterpart: SST keeps no per-client field table (paths and their hashes are the schema's, one
for every connection). Not counted: the schema's path-index table (shared, not per connection),
the transport and adapter's per-session bookkeeping (outbound writers, sync-lag ack state,
tickets), the recorder, and the encoders' scratch buffers.

Output, per captured run (label): the room count captured, players per room, and per room (the
median over the captured rooms) the broadcast snapshot's and the broadcast table's bytes
(shared, counted once per room), and per client the per-player snapshot's and table's bytes (the
mean over the room's players).
"""
import base64, json, pathlib, statistics, struct, sys

KEYED_ENTRY = 16      # B2's slot entry: key UTF-8 bytes + 16
STORED_VALUE = 9      # B2's stored value
BROADCAST_POLICIES = {"broadcast"}
UNSYNCED_POLICIES = {"serverOnly"}
STATE_WITH_EVENTS = 107          # MessageKindOpcode.stateUpdateWithEvents: the broadcast scope's frame
STATE_OPCODES = {0, 1, 2, 3}     # StateUpdateOpcode: noChange, firstSync, diff, resync
RESETS = {1, 3}                  # firstSync and resync recreate the scope's table


def unpack(data, i=0):
    """One MessagePack value at `i`: (value, end). Bin and ext values come back as bytes."""
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
        return _items(data, i, b & 0x0F)
    if 0x80 <= b <= 0x8F:
        return _entries(data, i, b & 0x0F)
    if b == 0xC0:
        return None, i
    if b in (0xC2, 0xC3):
        return b == 0xC3, i
    fixed = {0xCA: ">f", 0xCB: ">d", 0xCC: ">B", 0xCD: ">H", 0xCE: ">I", 0xCF: ">Q",
             0xD0: ">b", 0xD1: ">h", 0xD2: ">i", 0xD3: ">q"}
    if b in fixed:
        return struct.unpack_from(fixed[b], data, i)[0], i + struct.calcsize(fixed[b])
    if 0xD4 <= b <= 0xD8:  # fixext 1, 2, 4, 8, 16: a type byte, then the data
        n = 1 << (b - 0xD4)
        return data[i + 1:i + 1 + n], i + 1 + n
    sized = {0xC4: ">B", 0xC5: ">H", 0xC6: ">I", 0xC7: ">B", 0xC8: ">H", 0xC9: ">I",
             0xD9: ">B", 0xDA: ">H", 0xDB: ">I", 0xDC: ">H", 0xDD: ">I", 0xDE: ">H", 0xDF: ">I"}
    if b in sized:
        (n,) = struct.unpack_from(sized[b], data, i)
        i += struct.calcsize(sized[b])
        if b <= 0xC6:
            return data[i:i + n], i + n
        if b <= 0xC9:  # ext 8, 16, 32: a type byte, then the data
            return data[i + 1:i + 1 + n], i + 1 + n
        if b <= 0xDB:
            return data[i:i + n].decode("utf-8"), i + n
        return (_items if b <= 0xDD else _entries)(data, i, n)
    raise ValueError(f"unsupported MessagePack type 0x{b:02x}")


def _items(data, i, n):
    items = []
    for _ in range(n):
        item, i = unpack(data, i)
        items.append(item)
    return items, i


def _entries(data, i, n):
    entries = {}
    for _ in range(n):
        key, i = unpack(data, i)
        entries[key], i = unpack(data, i)
    return entries, i


def is_slot(value):
    return isinstance(value, int) and not isinstance(value, bool)


def dynamic_keys(raw):
    """One entry's dynamic-key position, as (slot, key) definitions and (slot, None) references:
    nil, a slot, `[slot, "key"]`, a key string (compression off), or an array of those."""
    if is_slot(raw):
        return [(raw, None)]
    if isinstance(raw, list):
        if len(raw) == 2 and is_slot(raw[0]) and isinstance(raw[1], str):
            return [(raw[0], raw[1])]
        return [k for item in raw for k in dynamic_keys(item)]
    return []


class KeyTables:
    """The encoder's dynamic-key tables, replayed from a room's frames in send order."""

    def __init__(self, sessions, sync_sequence, messagepack):
        self.sessions, self.sync_sequence, self.messagepack = sessions, sync_sequence, messagepack
        self.broadcast, self.per_player = {}, {}

    def decode(self, data):
        raw = base64.b64decode(data)
        if self.messagepack:
            value, end = unpack(raw)
            if end != len(raw):
                raise ValueError(f"{len(raw) - end} trailing bytes after a frame")
            return value
        return json.loads(raw)

    def apply(self, payload, table):
        if not isinstance(payload, list) or not payload or payload[0] not in STATE_OPCODES:
            raise ValueError(f"not a state update: {str(payload)[:80]}")
        if payload[0] in RESETS:
            table.clear()
        for entry in payload[2 if self.sync_sequence else 1:]:
            if not isinstance(entry, list) or len(entry) < 2:
                raise ValueError(f"not a patch entry: {str(entry)[:80]}")
            for slot, key in dynamic_keys(entry[1]):
                if key is not None:
                    table[slot] = key
                elif slot not in table:
                    # The frames are replayed in the scope they were encoded in, or this fails.
                    raise ValueError(f"slot {slot} used before its definition in its scope")

    def frame(self, target, data):
        frame = self.decode(data)
        if not isinstance(frame, list) or not frame or isinstance(frame[0], bool) or not isinstance(frame[0], int):
            return
        if frame[0] == STATE_WITH_EVENTS:
            self.apply(frame[1], self.broadcast)
        elif frame[0] in STATE_OPCODES:
            if target.startswith("s:") and target[2:] in self.sessions:
                player = self.sessions[target[2:]]
            elif target.startswith("p:"):
                player = target[2:]
            else:
                raise ValueError(f"a per-player state frame to {target!r}")
            self.apply(frame, self.per_player.setdefault(player, {}))


def value_bytes(value):
    """The counting rule over one snapshot (sub)tree."""
    if isinstance(value, dict):
        return sum(len(k.encode()) + KEYED_ENTRY + value_bytes(v) for k, v in value.items())
    if isinstance(value, list):
        return sum(value_bytes(v) if isinstance(v, (dict, list)) else STORED_VALUE for v in value)
    return STORED_VALUE


class Schema:
    def __init__(self, schema, land_type):
        self.defs = schema["defs"]
        self.root = self.resolve({"$ref": f"#/defs/{schema['lands'][land_type]['stateType']}"})

    def resolve(self, node):
        while isinstance(node, dict) and "$ref" in node:
            node = self.defs[node["$ref"].rsplit("/", 1)[1]]
        return node

    def top_fields(self):
        """(name, policy, node) for every top-level field of the state."""
        for name, node in (self.root.get("properties") or {}).items():
            policy = ((node.get("x-stateTree") or {}).get("sync") or {}).get("policy", "broadcast")
            yield name, policy, node


def room_state(path):
    lines = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    header, syncs = lines[0], [l for l in lines[1:] if "projections" in l]
    if not syncs:
        raise SystemExit(f"{path}: no syncs captured")
    schema = Schema(header["schema"], header["landID"].split(":", 1)[0])
    keeps_tables = "pathhash" in str(header.get("format", "")).lower() and \
        str((header.get("cell") or {}).get("environment", {}).get("DYNAMIC_KEY_COMPRESSION", "true")).lower() != "false"
    fields = list(schema.top_fields())
    broadcast = [(n, node) for n, policy, node in fields if policy in BROADCAST_POLICIES]
    per_player = [(n, node) for n, policy, node in fields if policy not in BROADCAST_POLICIES | UNSYNCED_POLICIES]
    last = syncs[-1]["projections"]
    players = sorted(last)
    first = last[players[0]]
    broadcast_snapshot = value_bytes({n: first[n] for n, _ in broadcast if n in first})
    tables = KeyTables(header.get("sessions") or {}, "syncSequence" in (header.get("stateUpdateFeatures") or []),
                       "messagepack" in str(header.get("stateUpdate", header.get("format", ""))).lower())
    if keeps_tables:
        for sync in syncs:
            for frame in sync.get("frames") or []:
                tables.frame(frame["to"], frame["data"])
    unknown = set(tables.per_player) - set(players)
    if unknown:
        raise SystemExit(f"{path}: per-player frames for players without a projection: {sorted(unknown)}")
    broadcast_keys = set(tables.broadcast.values())
    table = lambda slots: sum(len(k.encode()) + KEYED_ENTRY for k in set(dict(slots).values()))
    own = [value_bytes({n: last[p][n] for n, _ in per_player if n in last[p]}) for p in players]
    own_tables = [table(tables.per_player.get(p, {})) for p in players]
    return {
        "players": len(players),
        "broadcast_snapshot_bytes": broadcast_snapshot,
        "broadcast_key_table_bytes": table(tables.broadcast),
        "broadcast_key_table_entries": len(broadcast_keys),
        "per_player_snapshot_bytes": statistics.mean(own),
        "per_player_key_table_bytes": statistics.mean(own_tables),
        "dynamic_key_tables": keeps_tables,
        "syncs": len(syncs),
    }


def run_state(run_dir):
    rooms = [room_state(p) for p in sorted(run_dir.glob("room-*.ndjson"))]
    if not rooms:
        raise SystemExit(f"{run_dir}: no rooms captured")
    med = lambda k: statistics.median(r[k] for r in rooms)
    players = {r["players"] for r in rooms}
    if len(players) != 1:
        raise SystemExit(f"{run_dir}: rooms with different player counts {sorted(players)}")
    shared = med("broadcast_snapshot_bytes") + med("broadcast_key_table_bytes")
    own = med("per_player_snapshot_bytes") + med("per_player_key_table_bytes")
    return {
        "captured_rooms": len(rooms),
        "players_per_room": players.pop(),
        "syncs": med("syncs"),
        "dynamic_key_tables": all(r["dynamic_key_tables"] for r in rooms),
        "broadcast_snapshot_bytes": med("broadcast_snapshot_bytes"),
        "broadcast_key_table_bytes": med("broadcast_key_table_bytes"),
        "broadcast_key_table_entries": med("broadcast_key_table_entries"),
        "per_player_snapshot_bytes": med("per_player_snapshot_bytes"),
        "per_player_key_table_bytes": med("per_player_key_table_bytes"),
        "shared_bytes_per_room": shared,
        "own_bytes_per_client": own,
    }


def main(argv):
    if len(argv) != 2:
        raise SystemExit(__doc__)
    capture, out = pathlib.Path(argv[0]), pathlib.Path(argv[1])
    runs = sorted(p for p in capture.iterdir() if p.is_dir())
    if not runs:
        raise SystemExit(f"{capture}: no captured runs")
    out.write_text(json.dumps({run.name: run_state(run) for run in runs}, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])
