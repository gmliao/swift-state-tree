#!/usr/bin/env python3
"""Tests for syncmarks.py, and for the three topics' sync-marks gates on their committed summaries.

Usage: python3 test_syncmarks.py
"""
import copy, importlib.util, json, pathlib, struct, sys, tempfile, unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import syncmarks  # noqa: E402


def pack(v):
    """A MessagePack encoding of `v` (the subset the record uses), for building test records."""
    if v is None:
        return b"\xc0"
    if v is True or v is False:
        return b"\xc3" if v else b"\xc2"
    if isinstance(v, int):
        if 0 <= v <= 0x7F:
            return bytes([v])
        if -32 <= v < 0:
            return struct.pack(">b", v)
        return b"\xd3" + struct.pack(">q", v)
    if isinstance(v, str):
        b = v.encode("utf-8")
        return (bytes([0xA0 | len(b)]) if len(b) < 32 else b"\xd9" + bytes([len(b)])) + b
    if isinstance(v, list):
        return b"\xdc" + struct.pack(">H", len(v)) + b"".join(pack(x) for x in v)
    if isinstance(v, dict):
        return b"\xde" + struct.pack(">H", len(v)) + b"".join(pack(k) + pack(x) for k, x in v.items())
    raise TypeError(type(v))


def log(*records):
    out = b"SSTR\x03\x01"
    for r in records:
        body = pack(r)
        out += struct.pack(">I", len(body)) + body
    return out


def output(i, **extra):
    return {"index": 0, "turnKind": "tick", "streamIndex": i, "sequence": i, "broadcastHash": "00000000000000aa",
            "extractionDrops": {}, "encodeDropScopes": [], **extra}


def marker(i, kind, player, **extra):
    return {"kind": kind, "playerID": player, "streamIndex": i, "sequence": i, "rejoin": False, **extra}


def record(entries, complete=True):
    outputs = [e for e in entries if "turnKind" in e]
    markers = [e for e in entries if "turnKind" not in e]
    return log({"kind": "header", "format": "3.1", "codec": "none"},
               {"kind": "turn", "tickId": 1, "syncOutputs": outputs[:1], "syncMarkers": markers[:2]},
               {"kind": "turn", "tickId": 2, "syncOutputs": outputs[1:], "syncMarkers": markers[2:]},
               {"kind": "footer", "complete": complete, "syncStreamCount": len(entries)})


class Count(unittest.TestCase):
    def test_first_and_later_seeds_and_partial_outputs(self):
        data = record([
            marker(0, "seed", "a"), marker(1, "seed", "b"),
            output(2, resetsKeyScopes=True),
            marker(3, "clear", "a"), marker(4, "seed", "a"),                 # a resync in place
            marker(5, "seed", "b", rejoin=True, viewDrops=["encode"]),        # a rejoin, view not verifiable
            output(6, perPlayerUncommitted=["b"], encodeDropScopes=["b"]),
            {k: v for k, v in output(7).items() if k != "broadcastHash"},     # broadcast not committed
            marker(8, "seed", "a"),                                           # neither
            marker(9, "clear", "b"),
        ])
        c = syncmarks.count(data)
        self.assertEqual((c["format"], c["outputs"], c["players"]), ("3.1", 3, 2))
        self.assertEqual(c["markers"], {"seed": 5, "clear": 2, "initialize": 0})
        self.assertEqual((c["seeds_first"], c["seeds_later"]), (2, 3))
        self.assertEqual((c["seeds_later_rejoin"], c["seeds_later_after_clear"], c["seeds_later_other"]), (1, 1, 1))
        self.assertEqual(c["key_scope_resets"], 1)
        self.assertEqual(c["partial"], {"broadcast_not_committed": 1, "per_player_uncommitted": 1, "per_player_unverified": 0,
                                        "encode_drops": 1, "extraction_drops": 0, "events_not_merged": 0, "seed_view_drops": 1})

    def test_one_seed_per_player_has_no_later_seed(self):
        c = syncmarks.count(record([marker(0, "seed", "a"), output(1), marker(2, "seed", "b"), marker(3, "clear", "a")]))
        self.assertEqual((c["players"], c["seeds_first"], c["seeds_later"]), (2, 2, 0))
        self.assertEqual(sum(c["partial"].values()), 0)

    def test_refuses(self):
        good = record([marker(0, "seed", "a"), output(1)])
        cases = {
            "no preamble": b"XXXX" + good[4:],
            "cut": good[:-3],
            "incomplete": record([marker(0, "seed", "a"), output(1)], complete=False),
            "gap in the stream": record([marker(0, "seed", "a"), output(2)]),
            "footer count": log({"kind": "header", "format": "3.1"}, {"kind": "turn", "syncOutputs": [output(0)]},
                                {"kind": "footer", "complete": True, "syncStreamCount": 2}),
            "no footer": log({"kind": "header", "format": "3.1"}, {"kind": "turn", "syncOutputs": [output(0)]}),
            "unknown marker": record([marker(0, "seek", "a"), output(1)]),
        }
        for name, data in cases.items():
            with self.subTest(name), self.assertRaises(ValueError):
                syncmarks.count(data)

    def test_unpack_widths(self):
        for v in (0, 127, -1, -32, 2**40, -2**40, "x" * 40, [1, [2]], {"k": {"n": None, "t": True, "f": False}}):
            self.assertEqual(syncmarks.unpack(pack(v)), (v, len(pack(v))))
        self.assertEqual(syncmarks.unpack(b"\xcb" + struct.pack(">d", 1.5)), (1.5, 9))
        self.assertEqual(syncmarks.unpack(b"\xc4\x02ab"), (b"ab", 4))
        with self.assertRaises(ValueError):
            syncmarks.unpack(b"\xc7\x01\x01\x00")  # ext


class VerifyLine(unittest.TestCase):
    def test_counts_and_resets(self):
        line = ("Sync Output: passed [compared/unverifiable/skipped: broadcast 1367/0/1, per-player 5363/2/0, "
                "events 1367/0/0, seed 4/1/0, apply 6733/0/0]; 3 key scope resets\n")
        got = syncmarks.verify_line(line)
        self.assertEqual({k: v for k, v in got.items() if k != "scopes"},
                         {"seeds": 5, "unverifiable": 3, "skipped": 1, "key_scope_resets": 3})
        self.assertEqual(got["scopes"]["per-player"], {"compared": 5363, "unverifiable": 2, "skipped": 0})
        self.assertEqual(got["scopes"]["broadcast"], {"compared": 1367, "unverifiable": 0, "skipped": 1})
        plain = line.split("]")[0] + "]"
        self.assertEqual(syncmarks.verify_line(plain)["key_scope_resets"], 0)

    def test_refuses(self):
        for text in ("Sync Output: skipped (no sync stream: record version 3.1)",
                     "Sync Output: passed [compared/unverifiable/skipped: broadcast 1/0/0]",
                     "Sync Output: passed [compared/unverifiable/skipped: seed 1/0/0]\n" * 2,
                     "Sync Output: passed [compared/unverifiable/skipped: seed 1/0/0, seed 1/0/0]"):
            with self.subTest(text[:40]), self.assertRaises(ValueError):
                syncmarks.verify_line(text)


def topic_regenerate(topic):
    spec = importlib.util.spec_from_file_location(f"regenerate_marks_{topic.replace('-', '_')}", HERE / topic / "regenerate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TopicGates(unittest.TestCase):
    """Each topic's gate passes its committed sync-marks.json and refuses one that disagrees with its results."""

    def mutated(self, topic, change):
        data = copy.deepcopy(json.loads((HERE / topic / "sync-marks.json").read_text(encoding="utf-8")))
        change(data)
        path = pathlib.Path(tempfile.mkdtemp()) / "sync-marks.json"
        self.addCleanup(lambda: (path.unlink(), path.parent.rmdir()))
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def refused(self, call, topic, *changes):
        for change in changes:
            with self.subTest(change.__name__), mock.patch("sys.stderr"), self.assertRaises(SystemExit):
                call(self.mutated(topic, change))

    def test_external_input_failure(self):
        rg = topic_regenerate("external-input-failure")
        runs = rg.load(rg.RESULTS)
        outputs = rg.sync_output(runs)
        entries = rg.sync_marks(runs, outputs)
        self.assertEqual((sum(e["rooms"] for e in entries.values()), sum(e["seeds"] for e in entries.values())), (1950, 7800))

        def other_records_json(d):
            d["runs"]["rate10-rep2"]["records_json_sha256"] = "0" * 64

        def fewer_rooms(d):
            d["runs"]["join10-rep1"]["rooms"] -= 1

        def seeds_unbalanced(d):
            d["runs"]["leave10-rep1"]["seeds"] += 1

        def missing(d):
            del d["runs"]["baseline-rep3"]

        self.refused(lambda p: rg.sync_marks(runs, outputs, p), "external-input-failure",
                     other_records_json, fewer_rooms, seeds_unbalanced, missing)

    def test_recomputation_cost(self):
        rg = topic_regenerate("recomputation-cost")
        runs = rg.load(rg.HERE / "results")
        entries = rg.sync_marks(runs)
        self.assertEqual((len(entries), sum(e["players"] for e in entries)), (130, 780))

        def first(d):
            return d["records"][sorted(d["records"])[0]]

        def record_missing(d):
            del d["records"][sorted(d["records"])[0]]

        def player_short(d):
            first(d)["players"] -= 1

        def other_format(d):
            first(d)["format"] = "3.0"

        def later_unsplit(d):
            first(d)["seeds_later"] += 1

        def foreign(d):
            d["records"]["x/cost-p2-c5-r1-on/a.sstr"] = first(d)

        self.refused(lambda p: rg.sync_marks(runs, p), "recomputation-cost",
                     record_missing, player_short, other_format, later_unsplit, foreign)

    def test_visibility(self):
        rg = topic_regenerate("visibility")
        runs = rg.load(rg.RESULTS)
        entries = rg.sync_marks(runs)
        self.assertEqual((len(entries), sum(e["rooms"] for e in entries.values())), (21, 42))

        def fewer_rooms(d):
            d["runs"]["default-all-rep1"]["rooms"] = 1

        def other_players(d):
            d["runs"]["viewers16-radius-rep1"]["players_per_room"] = 4

        def seeds_unbalanced(d):
            d["runs"]["default-radius-rep1"]["seeds"] += 1

        def missing(d):
            del d["runs"]["tps2-broadcast-rep1"]

        def per_player_missing(d):
            del d["runs"]["default-radius-rep1"]["per_player"]

        def per_player_none_compared(d):
            d["runs"]["default-radius-rep1"]["per_player"]["compared"] = 0

        def scope_skips_beyond_total(d):
            d["runs"]["default-radius-rep1"]["broadcast"]["skipped"] = d["runs"]["default-radius-rep1"]["skipped"] + 1

        self.refused(lambda p: rg.sync_marks(runs, p), "visibility", fewer_rooms, other_players, seeds_unbalanced, missing,
                     per_player_missing, per_player_none_compared, scope_skips_beyond_total)
        table = rg.sync_marks_table(runs, entries)
        self.assertIn("| **All** | 42 | 8,484 | 0 | 0 | 48,480 | 0 | 0 |", table)


if __name__ == "__main__":
    unittest.main()
