#!/usr/bin/env python3
"""Tests for stateshape.py's counting rule on a capture-shaped directory (stdlib only).

Run: python3 deep-research/entity-delta-baseline/test_stateshape.py
"""
import json, pathlib, sys, tempfile, unittest

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import stateshape  # noqa: E402


def field(policy, kind="leaf", **extra):
    return {**extra, "x-stateTree": {"nodeKind": kind, "sync": {"policy": policy}}}


SCHEMA = {
    "defs": {
        "S": {"properties": {
            "players": field("broadcast", "map", additionalProperties={"$ref": "#/defs/P"}),
            "monsters": field("broadcast", "map", additionalProperties={"$ref": "#/defs/M"}),
            "score": field("broadcast"),
            "secret": field("serverOnly"),
            "mine": field("perPlayer", "object", properties={"a": field("perPlayer"), "bag": field("perPlayer", "map", additionalProperties={"type": "integer"})}),
        }},
        "P": {"properties": {"hp": field("broadcast")}},
        "M": {"properties": {"x": field("broadcast")}},
    },
    "lands": {"t": {"stateType": "S"}},
}


def capture(directory, syncs, fmt="messagepack-pathhash", environment=None, label="messagepack-pathhash-delta-r1-p2-m4-serial"):
    run = directory / label
    run.mkdir(parents=True)
    header = {"landID": "t:benchmark-0", "format": fmt, "schema": SCHEMA, "cell": {"environment": environment or {}}}
    lines = [json.dumps(header)] + [json.dumps({"sync": i, "frames": [], "projections": p}) for i, p in enumerate(syncs)]
    (run / "room-0.ndjson").write_text("\n".join(lines) + "\n")
    return run


def view(monsters, mine):
    return {"players": {"p1": {"hp": 1}}, "monsters": monsters, "score": 3, "mine": mine}


SYNCS = [
    {"p1": view({"1": {"x": 1}}, {"a": 5, "bag": {"k": 1}}), "p2": view({"1": {"x": 1}}, {"a": 6, "bag": {}})},
    {"p1": view({"2": {"x": 2}}, {"a": 5, "bag": {"k": 1}}), "p2": view({"2": {"x": 2}}, {"a": 6, "bag": {"jj": 2}})},
]


class StateShape(unittest.TestCase):
    def state(self, **kw):
        with tempfile.TemporaryDirectory() as tmp:
            return stateshape.run_state(capture(pathlib.Path(tmp), SYNCS, **kw))

    def test_the_rule_counts_the_last_snapshots_and_every_key_seen(self):
        s = self.state()
        # Broadcast, at the last sync: players (7+16) p1 (2+16) hp (2+16) 9 = 68; monsters (8+16) 2 (1+16) x (1+16) 9 = 67;
        # score (5+16) 9 = 30. 165 in all.
        self.assertEqual(s["broadcast_snapshot_bytes"], 165)
        # Keys at broadcast map nodes over both syncs: p1, 1, 2 -> (2+16) + (1+16) + (1+16).
        self.assertEqual((s["broadcast_key_table_entries"], s["broadcast_key_table_bytes"]), (3, 52))
        # Per player: mine (4+16) a (1+16) 9 bag (3+16), then p1's k (1+16) 9 = 91, p2's jj (2+16) 9 = 92; mean 91.5.
        self.assertEqual(s["per_player_snapshot_bytes"], 91.5)
        # Per-player key tables: p1 {k} 17, p2 {jj} 18 (keys seen over the syncs); mean 17.5.
        self.assertEqual(s["per_player_key_table_bytes"], 17.5)
        self.assertEqual((s["shared_bytes_per_room"], s["own_bytes_per_client"]), (217, 109.0))
        self.assertEqual((s["players_per_room"], s["captured_rooms"], s["syncs"]), (2, 1, 2))

    def test_no_dynamic_key_tables_without_the_path_hash_format_or_with_compression_off(self):
        for kw in ({"fmt": "json-object"}, {"environment": {"DYNAMIC_KEY_COMPRESSION": "false"}}):
            with self.subTest(kw):
                s = self.state(**kw)
                self.assertEqual((s["broadcast_key_table_bytes"], s["per_player_key_table_bytes"], s["dynamic_key_tables"]), (0, 0, False))
                self.assertEqual(s["broadcast_snapshot_bytes"], 165)

    def test_a_server_only_field_doesnt_count_even_if_present(self):
        syncs = [{p: dict(v, secret=7) for p, v in sync.items()} for sync in SYNCS]
        with tempfile.TemporaryDirectory() as tmp:
            s = stateshape.run_state(capture(pathlib.Path(tmp), syncs))
        self.assertEqual((s["broadcast_snapshot_bytes"], s["per_player_snapshot_bytes"]), (165, 91.5))

    def test_the_cli_writes_one_entry_per_captured_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = pathlib.Path(tmp)
            capture(d / "cap", SYNCS)
            stateshape.main([str(d / "cap"), str(d / "out.json")])
            out = json.loads((d / "out.json").read_text())
        self.assertEqual(list(out), ["messagepack-pathhash-delta-r1-p2-m4-serial"])


if __name__ == "__main__":
    unittest.main()
