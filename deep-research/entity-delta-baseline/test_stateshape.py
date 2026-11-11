#!/usr/bin/env python3
"""Tests for stateshape.py's counting rule on a capture-shaped directory (stdlib only).

Run: python3 deep-research/entity-delta-baseline/test_stateshape.py
"""
import base64, gzip, json, pathlib, struct, sys, tempfile, unittest

TOPIC = pathlib.Path(__file__).resolve().parent
# Real SST captures (EncodingBenchmark --capture-views, hero-defense, one room of 5), kept for
# ws-loadtest's verify-views tests: plain entries, merged entries, and merged entries with path indices.
REAL = TOPIC.parent.parent / "Examples/GameDemo/ws-loadtest/tests/fixtures"
REAL_CAPTURES = ("view-capture-messagepack-pathhash-delta.ndjson.gz",
                 "view-capture-messagepack-pathhash-delta-merged.ndjson.gz",
                 "view-capture-messagepack-pathhash-delta-merged-index.ndjson.gz")
sys.path.insert(0, str(TOPIC))
import stateshape  # noqa: E402


def pack(v):
    """The MessagePack subset the fixture frames use."""
    if v is None:
        return b"\xc0"
    if isinstance(v, bool):
        return b"\xc3" if v else b"\xc2"
    if isinstance(v, int):
        if 0 <= v <= 0x7F:
            return bytes([v])
        if -32 <= v < 0:
            return struct.pack(">b", v)
        return b"\xcd" + struct.pack(">H", v) if 0 <= v <= 0xFFFF else b"\xd2" + struct.pack(">i", v)
    if isinstance(v, str):
        b = v.encode()
        return (bytes([0xA0 | len(b)]) if len(b) < 32 else b"\xd9" + bytes([len(b)])) + b
    if isinstance(v, list):
        return bytes([0x90 | len(v)]) + b"".join(pack(x) for x in v)
    if isinstance(v, dict):
        return bytes([0x80 | len(v)]) + b"".join(pack(k) + pack(x) for k, x in v.items())
    raise TypeError(v)


def frame(to, value):
    return {"to": to, "data": base64.b64encode(pack(value)).decode()}


def field(policy, kind="leaf", **extra):
    return {**extra, "x-stateTree": {"nodeKind": kind, "sync": {"policy": policy}}}


SCHEMA = {
    "defs": {
        "S": {"properties": {
            "players": field("broadcast", "map", additionalProperties={"$ref": "#/defs/P"}),
            "monsters": field("broadcast", "map", additionalProperties={"$ref": "#/defs/M"}),
            "score": field("broadcast"),
            "secret": field("serverOnly"),
            "fog": field("masked"),
            "mine": field("perPlayer", "object", properties={"a": field("perPlayer"), "bag": field("perPlayer", "map", additionalProperties={"type": "integer"})}),
        }},
        "P": {"properties": {"hp": field("broadcast")}},
        "M": {"properties": {"x": field("broadcast")}},
    },
    "lands": {"t": {"stateType": "S"}},
}
SESSIONS = {"s1": "p1", "s2": "p2"}


def capture(directory, syncs, frames, fmt="messagepack-pathhash", environment=None,
            label="messagepack-pathhash-delta-r1-p2-m4-serial"):
    run = directory / label
    run.mkdir(parents=True)
    header = {"landID": "t:benchmark-0", "format": fmt, "stateUpdate": "opcodeMessagePack",
              "stateUpdateFeatures": ["pathIndex", "syncSequence"], "sessions": SESSIONS,
              "schema": SCHEMA, "cell": {"environment": environment or {}}}
    lines = [json.dumps(header)] + [json.dumps({"sync": i, "frames": f, "projections": p})
                                    for i, (p, f) in enumerate(zip(syncs, frames))]
    (run / "room-0.ndjson").write_text("\n".join(lines) + "\n")
    return run


def view(monsters, mine, **extra):
    return {"players": {"p1": {"hp": 1}}, "monsters": monsters, "score": 3, "mine": mine, **extra}


SYNCS = [
    {"p1": view({"1": {"x": 1}}, {"a": 5, "bag": {"k": 1}}), "p2": view({"1": {"x": 1}}, {"a": 6, "bag": {}})},
    {"p1": view({"2": {"x": 2}}, {"a": 5, "bag": {"k": 1}}), "p2": view({"2": {"x": 2}}, {"a": 6, "bag": {"jj": 2}})},
]
# [107, [opcode, syncSeq, [pathIndex, dynamicKey, op, value?]...], events]; per player [opcode, syncSeq, entries...].
FRAMES = [
    [frame("*", [107, [1, 0, [3, [0, "p1"], 0, {"hp": 1}], [5, [1, "1"], 0, {"x": 1}], [7, None, 0, 3]], []]),
     frame("s:s1", [1, 0, [9, None, 0, {"a": 5, "bag": {"k": 1}}]]),  # a key inside a whole value: never on a patch path
     frame("s:s1", [1, 0, [10, [0, "k"], 0, 1]]),
     frame("s:s2", [1, 0])],
    [frame("*", [107, [2, 1, [5, [2, "2"], 0, {"x": 2}], [5, 1, 1]], []]),
     frame("s:s1", [103, 1, 7, []]),  # an event frame: not a state update
     frame("s:s2", [2, 1, [10, [0, "jj"], 0, 2]])],
]


class StateShape(unittest.TestCase):
    def state(self, syncs=SYNCS, frames=FRAMES, **kw):
        with tempfile.TemporaryDirectory() as tmp:
            return stateshape.run_state(capture(pathlib.Path(tmp), syncs, frames, **kw))

    def test_the_rule_counts_the_last_snapshots_and_the_keys_the_frames_define(self):
        s = self.state()
        # Broadcast, at the last sync: players (7+16) p1 (2+16) hp (2+16) 9 = 68; monsters (8+16) 2 (1+16) x (1+16) 9 = 67;
        # score (5+16) 9 = 30. 165 in all.
        self.assertEqual(s["broadcast_snapshot_bytes"], 165)
        # The broadcast frames define p1, 1, 2 -> (2+16) + (1+16) + (1+16).
        self.assertEqual((s["broadcast_key_table_entries"], s["broadcast_key_table_bytes"]), (3, 52))
        # Per player: mine (4+16) a (1+16) 9 bag (3+16), then p1's k (1+16) 9 = 91, p2's jj (2+16) 9 = 92; mean 91.5.
        self.assertEqual(s["per_player_snapshot_bytes"], 91.5)
        # Per-player tables: p1 {k} 17, p2 {jj} 18; mean 17.5.
        self.assertEqual(s["per_player_key_table_bytes"], 17.5)
        self.assertEqual((s["shared_bytes_per_room"], s["own_bytes_per_client"]), (217, 109.0))
        self.assertEqual((s["players_per_room"], s["captured_rooms"], s["syncs"]), (2, 1, 2))

    def test_a_key_only_in_the_projection_or_inside_a_whole_value_isnt_in_the_table(self):
        # p2's bag holds "jj" in the projection, but no frame defines it: the table stays empty.
        frames = [FRAMES[0], FRAMES[1][:2]]
        s = self.state(frames=frames)
        self.assertEqual(s["per_player_key_table_bytes"], (17 + 0) / 2)

    def test_a_first_sync_or_resync_of_a_scope_recreates_its_table(self):
        syncs = SYNCS + [SYNCS[1]]
        for opcode in (1, 3):
            with self.subTest(opcode=opcode):
                frames = FRAMES + [[frame("*", [107, [opcode, 2, [5, [0, "2"], 0, {"x": 2}]], []]),
                                    frame("s:s1", [opcode, 2])]]
                s = self.state(syncs=syncs, frames=frames)
                self.assertEqual((s["broadcast_key_table_entries"], s["broadcast_key_table_bytes"]), (1, 17))
                self.assertEqual(s["per_player_key_table_bytes"], (0 + 18) / 2)

    def test_a_slot_used_before_its_definition_in_its_scope_is_refused(self):
        # Slot 0 is defined in p1's table, not p2's: replayed in the wrong scope, it fails.
        frames = [FRAMES[0], [frame("s:s2", [2, 1, [10, 0, 0, 2]])]]
        with self.assertRaisesRegex(ValueError, "slot 0 used before its definition"):
            self.state(frames=frames)

    def test_no_dynamic_key_tables_without_the_path_hash_format_or_with_compression_off(self):
        for kw in ({"fmt": "json-object"}, {"environment": {"DYNAMIC_KEY_COMPRESSION": "false"}}):
            with self.subTest(kw):
                s = self.state(**kw)
                self.assertEqual((s["broadcast_key_table_bytes"], s["per_player_key_table_bytes"], s["dynamic_key_tables"]), (0, 0, False))
                self.assertEqual(s["broadcast_snapshot_bytes"], 165)

    def test_a_masked_field_is_per_player_and_a_server_only_field_doesnt_count(self):
        syncs = [{p: dict(v, secret=7, fog=1) for p, v in sync.items()} for sync in SYNCS]
        s = self.state(syncs=syncs)
        # fog (3+16) 9 = 28 in each player's snapshot, not in the broadcast one; secret nowhere.
        self.assertEqual((s["broadcast_snapshot_bytes"], s["per_player_snapshot_bytes"]), (165, 91.5 + 28))

    def test_the_cli_writes_one_entry_per_captured_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = pathlib.Path(tmp)
            capture(d / "cap", SYNCS, FRAMES)
            stateshape.main([str(d / "cap"), str(d / "out.json")])
            out = json.loads((d / "out.json").read_text())
        self.assertEqual(list(out), ["messagepack-pathhash-delta-r1-p2-m4-serial"])

    def test_unpack_reads_what_pack_writes(self):
        for value in (None, True, 0, 127, 300, -5, -40000, "a" * 40, [1, [2, "x"]], {"k": [None]}):
            self.assertEqual(stateshape.unpack(pack(value)), (value, len(pack(value))))



def all_keys(value, out):
    if isinstance(value, dict):
        for k, v in value.items():
            out.add(k)
            all_keys(v, out)
    elif isinstance(value, list):
        for v in value:
            all_keys(v, out)
    return out


class RealCaptures(unittest.TestCase):
    """The replay on frames SST's encoder wrote: no slot is used before its scope defines it."""

    def test_real_sst_captures_replay_cleanly_in_their_scopes(self):
        for name in REAL_CAPTURES:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                text = gzip.decompress((REAL / name).read_bytes()).decode("utf-8")
                run = pathlib.Path(tmp) / "messagepack-pathhash-delta-r1-p5-m0-serial"
                run.mkdir()
                (run / "room-0.ndjson").write_text(text)
                s = stateshape.run_state(run)  # raises on a slot used before its definition
                lines = [json.loads(l) for l in text.splitlines() if l.strip()]
                header, syncs = lines[0], [l for l in lines[1:] if "projections" in l]
                tables = stateshape.KeyTables(header["sessions"], "syncSequence" in (header.get("stateUpdateFeatures") or []), True)
                for sync in syncs:
                    for f in sync["frames"]:
                        tables.frame(f["to"], f["data"])
                # Every client got its per-player frames, keyed by the player of its session.
                self.assertEqual(set(tables.per_player), set(header["sessions"].values()))
                self.assertEqual(s["players_per_room"], len(header["sessions"]))
                self.assertGreater(s["broadcast_snapshot_bytes"], 0)
                self.assertGreater(s["broadcast_key_table_entries"], 0)
                # A defined key is a key of the state the clients see.
                seen = set()
                for sync in syncs:
                    for view in sync["projections"].values():
                        all_keys(view, seen)
                defined = set(tables.broadcast.values()).union(*(set(t.values()) for t in tables.per_player.values()))
                self.assertLessEqual(defined, seen)
                self.assertEqual(s["broadcast_key_table_entries"], len(set(tables.broadcast.values())))


if __name__ == "__main__":
    unittest.main()
