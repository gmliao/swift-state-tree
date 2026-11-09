#!/usr/bin/env python3
"""SST's per-client sync state by a fixed counting rule, from a `--capture-views` directory
(stdlib only).

  python3 stateshape.py <capture dir> <out.json>

What SST keeps for a land's sync, as the Sources hold it, at 75222b87:
- one broadcast snapshot per land (`SyncEngine.lastBroadcastSnapshot`): the broadcast fields;
- one per-player snapshot per player (`SyncEngine.lastPerPlayerSnapshots`): the per-player fields;
- with the path-hash formats and dynamic-key compression on, one dynamic-key table per scope
  (`DynamicKeyScope`: `.broadcast(landID)` and `.perPlayer(landID, playerID)`), key string to
  slot, never freed.

The capture holds, after every sync, each player's projection (`SyncEngine.snapshot(for:mode:
.all)`, the same snapshot tree as JSON) and the land's schema. The broadcast snapshot is a
projection's top-level fields whose policy is broadcast or masked; a player's per-player snapshot
is its fields with a per-player policy (perPlayer, perPlayerSlice, or another non-broadcast,
synced policy); serverOnly fields aren't synced. Each scope's dynamic-key table holds every
distinct key string seen at a map node of that scope's fields, over every sync (a key present at
a sync was sent by then).

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
import json, pathlib, statistics, sys

KEYED_ENTRY = 16      # B2's slot entry: key UTF-8 bytes + 16
STORED_VALUE = 9      # B2's stored value
BROADCAST_POLICIES = {"broadcast", "masked"}
UNSYNCED_POLICIES = {"serverOnly"}


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

    def map_keys(self, node, value, out):
        """Adds every key at a map node under `value` (shaped by schema `node`) to `out`."""
        node = self.resolve(node)
        if not isinstance(value, dict):
            if isinstance(value, list) and isinstance(node.get("items"), dict):
                for item in value:
                    self.map_keys(node["items"], item, out)
            return
        kind = (node.get("x-stateTree") or {}).get("nodeKind")
        if kind == "map" or ("additionalProperties" in node and "properties" not in node):
            child = node.get("additionalProperties") or {}
            for key, item in value.items():
                out.add(key)
                self.map_keys(child, item, out)
            return
        props = node.get("properties") or {}
        for key, item in value.items():
            if key in props:
                self.map_keys(props[key], item, out)


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
    broadcast_keys, player_keys = set(), {p: set() for p in players}
    if keeps_tables:
        for sync in syncs:
            view = sync["projections"][players[0]]
            for n, node in broadcast:
                if n in view:
                    schema.map_keys(node, view[n], broadcast_keys)
            for p in players:
                for n, node in per_player:
                    if n in sync["projections"][p]:
                        schema.map_keys(node, sync["projections"][p][n], player_keys[p])
    table = lambda keys: sum(len(k.encode()) + KEYED_ENTRY for k in keys)
    own = [value_bytes({n: last[p][n] for n, _ in per_player if n in last[p]}) for p in players]
    own_tables = [table(player_keys[p]) for p in players]
    return {
        "players": len(players),
        "broadcast_snapshot_bytes": broadcast_snapshot,
        "broadcast_key_table_bytes": table(broadcast_keys),
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
